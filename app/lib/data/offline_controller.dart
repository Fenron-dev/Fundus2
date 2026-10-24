import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import '../app/app_settings.dart';
import '../app/offline_conditions.dart';
import 'download_controller.dart';
import 'library_controller.dart';

/// Resolves opt-in rules through the same visible local catalogue and feeds
/// the existing download queue. Never runs a scan or a background service.
class OfflineController extends ChangeNotifier {
  OfflineController({
    required this.settings,
    required this.library,
    required this.downloads,
    Future<OfflineConditions> Function()? conditions,
    this.scheduleAutomatically = true,
  }) : _conditions = conditions ?? readOfflineConditions {
    settings.addListener(_settingsChanged);
    library.addListener(_changed);
    _settingsChanged();
  }

  final AppSettings settings;
  final LibraryController library;
  final DownloadController downloads;
  final Future<OfflineConditions> Function() _conditions;
  final bool scheduleAutomatically;
  bool _foreground = true;
  bool _disposed = false;
  bool _running = false;
  Timer? _pending;
  Timer? _timer;
  String? failure;
  OfflinePlan? lastPlan;
  final Map<String, DateTime> _attempted = {};
  var _configurationRevision = 0;
  String _configurationSignature = '';

  void _settingsChanged() {
    try {
      final signature =
          '${settings.offlinePolicy.toJson()}:${rules.map((rule) => rule.toJson()).toList()}';
      if (_configurationSignature == signature) return;
      _configurationSignature = signature;
    } on Object {
      _configurationSignature = '';
    }
    _configurationRevision++;
    _changed();
  }

  List<OfflineRule> get rules => library.library == null
      ? const []
      : settings.offlineRules(library.library!.manifest.libraryId);

  Future<void> putRule(OfflineRule rule) async {
    final vault = library.library;
    if (vault == null) return;
    if (rule.scope == OfflineRuleScope.work &&
        library.workById(rule.targetId) == null) {
      return;
    }
    await settings.setOfflineRules(vault.manifest.libraryId, [
      for (final old in rules)
        if (old.key != rule.key) old,
      rule,
    ]);
  }

  Future<void> removeRule(String key) async {
    final vault = library.library;
    if (vault == null) return;
    await settings.setOfflineRules(vault.manifest.libraryId, [
      for (final rule in rules)
        if (rule.key != key) rule,
    ]);
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) {
      _pending?.cancel();
      _timer?.cancel();
      _timer = null;
    } else {
      _changed();
    }
  }

  void _changed() {
    if (_disposed || !_foreground || !scheduleAutomatically) return;
    _pending?.cancel();
    try {
      if (!settings.offlinePolicy.enabled || rules.isEmpty) {
        _timer?.cancel();
        _timer = null;
        return;
      }
    } on Object catch (error) {
      failure = '$error';
      _timer?.cancel();
      _timer = null;
      return;
    }
    _pending = Timer(const Duration(seconds: 1), () => unawaited(run()));
  }

  Future<OfflinePlan> preview({
    OfflinePolicy? policyOverride,
    List<OfflineRule>? rulesOverride,
  }) async {
    final vault = library.library;
    if (vault == null) throw StateError('Keine Bibliothek geöffnet.');
    final policy = policyOverride ?? settings.offlinePolicy;
    final selectedRules = rulesOverride ?? rules;
    final visible = {for (final work in library.works) work.id: work};
    final shelves = {
      for (final shelf in await vault.loadSavedViews()) shelf.id: shelf,
    };
    final counts = <String, int>{};
    // Specific work rules take precedence over overlapping shelf defaults.
    for (final rule in selectedRules.where(
      (rule) => rule.scope == OfflineRuleScope.work,
    )) {
      if (visible.containsKey(rule.targetId)) {
        counts[rule.targetId] = rule.nextFiles;
      }
    }
    for (final rule in selectedRules.where(
      (rule) => rule.scope == OfflineRuleScope.shelf,
    )) {
      final shelf = shelves[rule.targetId];
      if (shelf == null) continue;
      for (final work in LibraryWorkSearch.apply(
        visible.values.map((work) => work.summary).toList(),
        shelf.query,
      )) {
        counts.putIfAbsent(work.id, () => rule.nextFiles);
      }
    }
    final queued = downloads.queuedFileIds;
    final here = <String>{};
    var reserved = 0;
    for (final file in vault.offlineInventory(queued)) {
      final present =
          file.offlinePath != null && await File(file.offlinePath!).exists();
      if (present) here.add(file.fileId);
      if (queued.contains(file.fileId) && !present) {
        if (file.sizeBytes <= 0) {
          throw StateError(
            'Eine laufende Übertragung hat noch keine bekannte Größe. Budgetprüfung bitte später wiederholen.',
          );
        }
        reserved += file.sizeBytes;
      }
    }
    final targets = <OfflineTarget>[];
    for (final entry in counts.entries) {
      final work = visible[entry.key]!;
      if (work.summary.sourceId == FundusDatabase.localSourceId) continue;
      final progress = vault.loadProgress(entry.key);
      targets.add(
        OfflineTarget(
          workId: entry.key,
          tracks: [
            for (final track in vault.playbackTracks(entry.key))
              // The index can still name an offline copy somebody deleted
              // outside Fundus. Preserve the owner without mutating a preview.
              if (!track.isRemote && !here.contains(track.fileId))
                LibraryPlaybackTrack(
                  fileId: track.fileId,
                  relativePath: track.relativePath,
                  absolutePath: '',
                  title: track.title,
                  sourceId: work.summary.sourceId,
                  index: track.index,
                  duration: track.duration,
                  audioMetadata: track.audioMetadata,
                  episode: track.episode,
                  sizeBytes: track.sizeBytes,
                  contentRevision: track.contentRevision,
                )
              else
                track,
          ],
          startFileId: progress?.fileId,
          startFileFinished: progress?.finished ?? false,
          nextFiles: entry.value,
        ),
      );
    }
    var bytes = 0;
    final offline = Directory(
      p.join((await downloads.storageRoot()).path, 'offline'),
    );
    if (await offline.exists()) {
      // Count even hidden/orphaned copies and partial transfers. Do not follow
      // symlinks, and do not walk original media directories.
      await for (final entity in offline.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) bytes += await entity.length();
      }
    }
    final raw = await _conditions();
    if (!identical(library.library, vault)) {
      throw StateError(
        'Die Bibliothek wurde gewechselt. Vorschau erneut öffnen.',
      );
    }
    return OfflinePlan.preview(
      policy: policy,
      conditions: OfflineConditions(
        wifi: raw.wifi,
        charging: raw.charging,
        foreground: _foreground,
      ),
      targets: targets,
      alreadyHere: here,
      alreadyQueued: queued,
      storedBytes: bytes,
      reservedBytes: reserved,
    );
  }

  /// The same gate protects every body chunk. Expensive platform queries are
  /// sampled at most once per second; foreground/protection gates are immediate.
  Future<bool> Function() _guard(FundusLibrary vault, String workId) {
    final revision = _configurationRevision;
    var checked = DateTime.fromMillisecondsSinceEpoch(0);
    var allowed = false;
    return () async {
      if (_disposed ||
          !_foreground ||
          revision != _configurationRevision ||
          !identical(library.library, vault) ||
          library.workById(workId) == null) {
        return false;
      }
      final policy = settings.offlinePolicy;
      if (!policy.enabled || rules.isEmpty) return false;
      if (DateTime.now().difference(checked) >= const Duration(seconds: 1)) {
        checked = DateTime.now();
        final current = await _conditions();
        allowed =
            (!policy.wifiOnly || current.wifi == true) &&
            (!policy.chargingOnly || current.charging == true);
      }
      return allowed;
    };
  }

  Future<void> run({bool force = false}) async {
    if (_running || _disposed || !_foreground) return;
    _running = true;
    try {
      if (!settings.offlinePolicy.enabled || rules.isEmpty) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      if (scheduleAutomatically) {
        _timer ??= Timer.periodic(
          const Duration(minutes: 1),
          (_) => unawaited(run()),
        );
      }
      final vault = library.library;
      final plan = await preview();
      lastPlan = plan;
      failure = null;
      if (vault == null || !identical(library.library, vault)) return;
      final byWork = <String, Set<String>>{};
      for (final file in plan.files) {
        byWork.putIfAbsent(file.workId, () => {}).add(file.track.fileId);
      }
      for (final entry in byWork.entries) {
        final attempted = _attempted[entry.key];
        if (!force &&
            attempted != null &&
            DateTime.now().difference(attempted) < const Duration(minutes: 1)) {
          continue;
        }
        final work = library.workById(entry.key);
        if (work == null) continue;
        _attempted[entry.key] = DateTime.now();
        await downloads.download(
          work,
          only: entry.value,
          mayTransfer: _guard(vault, entry.key),
        );
      }
    } on Object catch (error) {
      failure = '$error';
    } finally {
      _running = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pending?.cancel();
    _timer?.cancel();
    settings.removeListener(_settingsChanged);
    library.removeListener(_changed);
    super.dispose();
  }
}
