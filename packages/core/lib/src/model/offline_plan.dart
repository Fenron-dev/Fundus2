import '../playback/library_playback.dart';

/// Installation-local opt-in, never a command to download in the background.
final class OfflinePolicy {
  const OfflinePolicy({
    this.enabled = false,
    this.nextFiles = 3,
    this.storageBudgetBytes = 1024 * 1024 * 1024,
    this.wifiOnly = true,
    this.chargingOnly = false,
  });

  final bool enabled;
  final int nextFiles;
  final int storageBudgetBytes;
  final bool wifiOnly;
  final bool chargingOnly;

  void validate() {
    if (nextFiles < 1 || nextFiles > 500 || storageBudgetBytes < 1) {
      throw const FormatException(
        'Ungültige Offline-Anzahl oder Speichergrenze.',
      );
    }
  }

  Map<String, Object?> toJson() => {
    'format_version': 1,
    'enabled': enabled,
    'next_files': nextFiles,
    'storage_budget_bytes': storageBudgetBytes,
    'wifi_only': wifiOnly,
    'charging_only': chargingOnly,
  };

  static OfflinePolicy fromJson(Object? value) {
    if (value is! Map ||
        value['format_version'] != 1 ||
        value['enabled'] is! bool ||
        value['next_files'] is! int ||
        value['storage_budget_bytes'] is! int ||
        value['wifi_only'] is! bool ||
        value['charging_only'] is! bool) {
      throw const FormatException('Nicht unterstützte Offline-Regel.');
    }
    final policy = OfflinePolicy(
      enabled: value['enabled'] as bool,
      nextFiles: value['next_files'] as int,
      storageBudgetBytes: value['storage_budget_bytes'] as int,
      wifiOnly: value['wifi_only'] as bool,
      chargingOnly: value['charging_only'] as bool,
    );
    policy.validate();
    return policy;
  }
}

/// Unknown system conditions do not grant permission to transfer bytes.
final class OfflineConditions {
  const OfflineConditions({this.wifi, this.charging, this.foreground = true});

  final bool? wifi;
  final bool? charging;
  final bool foreground;
}

/// Callers resolve shelf rules, visibility and the chosen personal position
/// against the local index first. The input order expresses explicit priority.
final class OfflineTarget {
  const OfflineTarget({
    required this.workId,
    required this.tracks,
    this.startFileId,
    this.startFileFinished = false,
    this.nextFiles,
  });

  final String workId;
  final List<LibraryPlaybackTrack> tracks;
  final String? startFileId;
  final bool startFileFinished;
  final int? nextFiles;
}

enum OfflineDeferral {
  disabled,
  background,
  wifiRequired,
  chargingRequired,
  positionUnavailable,
  sizeUnknown,
  budgetExceeded,
}

final class OfflinePlannedFile {
  const OfflinePlannedFile({required this.workId, required this.track});
  final String workId;
  final LibraryPlaybackTrack track;

  /// A download unit is always a physical file, not an embedded chapter.
  bool get isContainer =>
      track.title.toLowerCase().endsWith('.epub') ||
      track.title.toLowerCase().endsWith('.cbz');
}

/// Pure preview: no timers, network, persistence, file deletion or progress
/// mutations. Budget includes all existing copies and reserved queued bytes,
/// including those currently hidden by protection or library visibility.
final class OfflinePlan {
  OfflinePlan._(
    Iterable<OfflinePlannedFile> files,
    Map<String, OfflineDeferral> deferred,
  ) : files = List.unmodifiable(files),
      deferred = Map.unmodifiable(deferred);

  final List<OfflinePlannedFile> files;
  final Map<String, OfflineDeferral> deferred;
  int get bytesToDownload =>
      files.fold(0, (sum, file) => sum + file.track.sizeBytes);

  static OfflinePlan preview({
    required OfflinePolicy policy,
    required OfflineConditions conditions,
    required List<OfflineTarget> targets,
    required Set<String> alreadyHere,
    required Set<String> alreadyQueued,
    required int storedBytes,
    int reservedBytes = 0,
  }) {
    policy.validate();
    if (storedBytes < 0 || reservedBytes < 0) {
      throw ArgumentError('Speicherverbrauch darf nicht negativ sein.');
    }
    final gate = !policy.enabled
        ? OfflineDeferral.disabled
        : !conditions.foreground
        ? OfflineDeferral.background
        : policy.wifiOnly && conditions.wifi != true
        ? OfflineDeferral.wifiRequired
        : policy.chargingOnly && conditions.charging != true
        ? OfflineDeferral.chargingRequired
        : null;
    final deferred = <String, OfflineDeferral>{};
    final files = <OfflinePlannedFile>[];
    final selected = {...alreadyHere, ...alreadyQueued};
    var available = policy.storageBudgetBytes - storedBytes - reservedBytes;
    for (final target in targets) {
      if (gate != null) {
        deferred[target.workId] = gate;
        continue;
      }
      final count = target.nextFiles ?? policy.nextFiles;
      if (count < 1 || count > 500) {
        throw ArgumentError('Ungültige Anzahl vorausgeladener Dateien.');
      }
      final tracks = target.tracks;
      var start = target.startFileId == null
          ? 0
          : tracks.indexWhere((track) => track.fileId == target.startFileId);
      if (start < 0) {
        deferred[target.workId] = OfflineDeferral.positionUnavailable;
        continue;
      }
      if (target.startFileFinished) start++;
      final distinct = <String>{};
      // Keep order, including already available files in the look-ahead
      // window. Re-running a rule must not keep fetching the next N forever.
      final window = tracks
          .skip(start)
          .where((track) => distinct.add(track.fileId))
          .take(count);
      for (final track in window) {
        if (!track.isRemote || selected.contains(track.fileId)) continue;
        if (track.sizeBytes <= 0) {
          deferred[target.workId] = OfflineDeferral.sizeUnknown;
          break;
        }
        if (track.sizeBytes > available) {
          deferred[target.workId] = OfflineDeferral.budgetExceeded;
          break;
        }
        files.add(OfflinePlannedFile(workId: target.workId, track: track));
        selected.add(track.fileId);
        available -= track.sizeBytes;
      }
    }
    return OfflinePlan._(files, deferred);
  }
}
