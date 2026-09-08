import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path/path.dart' as p;

import '../media/peer_file_cache.dart';
import 'library_controller.dart';
import 'work_view.dart';

/// What a download is doing right now.
enum DownloadState { queued, running, done, failed }

/// One work on its way to this device.
final class DownloadJob {
  const DownloadJob({
    required this.workId,
    required this.title,
    required this.state,
    this.done = 0,
    this.total = 0,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.currentBytes = 0,
    this.fraction,
    this.failure,
    this.bytesPerSecond,
    this.bytesLeft,
  });

  final String workId;
  final String title;
  final DownloadState state;

  /// Files finished, and files in the work.
  final int done;
  final int total;

  /// Byte-weighted progress; falls back to file counts when sizes are absent.
  final int bytesDone;
  final int bytesTotal;
  final int currentBytes;

  /// How far the file being fetched has come, where the other side said how
  /// large it is.
  final double? fraction;
  final String? failure;

  /// How fast the current file is arriving, and how much of it is left.
  /// Null where the other side did not say how large it is.
  final double? bytesPerSecond;
  final int? bytesLeft;

  /// Roughly how long the file being fetched still needs.
  Duration? get remaining {
    final speed = bytesPerSecond;
    final left = bytesLeft;
    if (speed == null || left == null || speed <= 0) return null;
    return Duration(seconds: (left / speed).round());
  }

  DownloadJob copyWith({
    DownloadState? state,
    int? done,
    int? bytesDone,
    int? bytesTotal,
    int? currentBytes,
    double? fraction,
    String? failure,
    double? bytesPerSecond,
    int? bytesLeft,
  }) => DownloadJob(
    workId: workId,
    title: title,
    state: state ?? this.state,
    done: done ?? this.done,
    total: total,
    bytesDone: bytesDone ?? this.bytesDone,
    bytesTotal: bytesTotal ?? this.bytesTotal,
    currentBytes: currentBytes ?? this.currentBytes,
    fraction: fraction,
    failure: failure ?? this.failure,
    bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
    bytesLeft: bytesLeft ?? this.bytesLeft,
  );

  /// Roughly how far along the whole work is.
  double get progress {
    if (bytesTotal > 0) {
      return ((bytesDone + (fraction ?? 0) * currentBytes) / bytesTotal).clamp(
        0,
        1,
      );
    }
    if (total == 0) return 0;
    return ((done + (fraction ?? 0)) / total).clamp(0, 1);
  }
}

/// Taking a work with you.
///
/// Streaming is the normal way to reach a work on another machine, and it
/// stops at the front door: a train, a plane, a cellar. A download is the
/// deliberate answer to that — not a cache that fills itself and fills up the
/// device, but a work someone said they wanted with them.
///
/// What it produces is not a second kind of work. The copy is recorded
/// against the file it is a copy *of*, and from then on every player and
/// reader opens it without knowing anything changed. Deleting it puts the
/// work back on the network. „Offline gesichert" is a state of a work, which
/// is exactly what the design says origin is.
class DownloadController extends ChangeNotifier {
  DownloadController({required this.library, required this.storageRoot});

  final LibraryController library;

  /// Where copies are kept: one folder per peer library, beside the app's own
  /// state rather than in the media folders — nothing else should mistake
  /// them for a library.
  final Future<Directory> Function() storageRoot;

  final Map<String, DownloadJob> _jobs = {};

  /// Where a work's bytes come from, by the source it belongs to.
  FundusStreamProxy? Function(String sourceId)? proxyForSource;
  bool _running = false;

  List<DownloadJob> get jobs => _jobs.values.toList(growable: false);

  DownloadJob? jobFor(String workId) => _jobs[workId];

  /// Whether a work can be taken along at all.
  ///
  /// Only what is somewhere else: a work already on this disk has nothing to
  /// fetch, and a machine that is not answering has nothing to fetch from.
  bool canDownload(WorkView work) =>
      _proxyFor(work.id) != null &&
      !isSecured(work.id) &&
      !_jobs.containsKey(work.id);

  /// The door for a work's files, if the machine holding them is answering.
  FundusStreamProxy? _proxyFor(String workId) {
    final vault = library.library;
    if (vault == null) return null;
    final tracks = vault.playbackTracks(workId);
    if (tracks.isEmpty) return null;
    return proxyForSource?.call(tracks.first.sourceId);
  }

  /// Whether every file of a work is already here.
  bool isSecured(String workId) {
    final vault = library.library;
    if (vault == null) return false;
    final files = vault.contentFiles(workId);
    return files.isNotEmpty &&
        files.every((file) => file.availability == 'offline_copy');
  }

  /// Whether at least one file is already present, even while the complete
  /// work is still being fetched. The downloads screen can therefore explain
  /// a partial download instead of looking empty.
  bool hasOfflineFiles(String workId) {
    final vault = library.library;
    if (vault == null) return false;
    return vault
        .contentFiles(workId)
        .any((file) => file.availability == 'offline_copy');
  }

  int offlineFileCount(String workId) {
    final vault = library.library;
    if (vault == null) return 0;
    return vault
        .contentFiles(workId)
        .where((file) => file.availability == 'offline_copy')
        .length;
  }

  /// Whether this controller is still in use.
  ///
  /// Measuring and fetching both run past the moment somebody closes a
  /// library, and a notification after that is an error rather than a
  /// message. Guarded here instead of at every call site.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// How much room the copies take on this device, by media type.
  ///
  /// Measured rather than remembered: a file can be deleted from outside, and
  /// a number that says 6 GB when the folder is empty is worse than no
  /// number. Measuring means asking the file system for a few hundred sizes,
  /// so it happens when somebody looks at the list, not on every rebuild.
  Map<String, int> get storageByType => Map.unmodifiable(_storage);
  final Map<String, int> _storage = {};

  int get storedBytes =>
      _storage.values.fold(0, (total, value) => total + value);

  /// The measurement that is running, if one is.
  ///
  /// A second caller waits for the first rather than being told „busy" and
  /// left with an empty answer — which is what a plain flag would do, and
  /// what would make the number on screen depend on timing.
  Future<void>? _measuring;

  Future<void> measureStorage() =>
      _measuring ??= _measure().whenComplete(() => _measuring = null);

  Future<void> _measure() async {
    final vault = library.library;
    if (vault == null || _disposed) return;
    try {
      final sizes = <String, int>{};
      for (final work in library.works) {
        if (work.origin != FundusOrigin.offline) continue;
        var bytes = 0;
        for (final file in vault.contentFiles(work.id)) {
          final path = file.offlinePath;
          if (path == null) continue;
          try {
            bytes += await File(path).length();
          } on FileSystemException {
            // A copy somebody deleted from outside simply counts for nothing.
          }
        }
        if (bytes == 0) continue;
        final type = work.mediaType?.label ?? 'Nicht zugeordnet';
        sizes[type] = (sizes[type] ?? 0) + bytes;
      }
      _storage
        ..clear()
        ..addAll(sizes);
      notifyListeners();
    } on Object {
      // Ein Ordner, der sich gerade nicht lesen lässt, ist eine Zahl weniger,
      // kein Fehler.
    }
  }

  /// Queues a work and starts working through the queue.
  ///
  /// [only] names the files to fetch — the chapters somebody picked. Without
  /// it the whole work comes along, which is right for a film and wrong for
  /// a manga with four hundred chapters.
  Future<void> download(WorkView work, {Set<String>? only}) async {
    final vault = library.library;
    if (vault == null || _proxyFor(work.id) == null) return;
    final previous = _jobs[work.id];
    // A failed job is history, not a lock. Keeping it in the map used to make
    // the visible „Erneut“ action a no-op forever after the first timeout.
    if (previous != null && previous.state != DownloadState.failed) return;
    if (previous != null) _jobs.remove(work.id);
    final files = [
      for (final file in vault.contentFiles(work.id))
        if (only == null || only.contains(file.fileId)) file,
    ];
    if (files.isEmpty) return;

    _wanted[work.id] = {for (final file in files) file.fileId};
    _jobs[work.id] = DownloadJob(
      workId: work.id,
      title: work.title,
      state: DownloadState.queued,
      total: files.length,
      bytesTotal: files.fold<int>(0, (sum, file) => sum + file.sizeBytes),
    );
    notifyListeners();
    unawaited(_drain());
  }

  /// Which files each job was told to fetch.
  final Map<String, Set<String>> _wanted = {};

  /// Throws a copy away and gives the work back to the network.
  Future<void> remove(String workId) async {
    final vault = library.library;
    if (vault == null) return;
    for (final file in vault.contentFiles(workId)) {
      final path = file.offlinePath;
      if (path != null) {
        final copy = File(path);
        if (await copy.exists()) await copy.delete();
      }
      vault.clearOfflineCopy(file.fileId);
    }
    _jobs.remove(workId);
    _wanted.remove(workId);
    library.refreshWork(workId);
    notifyListeners();
    unawaited(measureStorage());
  }

  /// Takes a work out of the queue. What is already fetched stays — half a
  /// download thrown away is a second download later.
  void cancel(String workId) {
    final job = _jobs[workId];
    if (job == null || job.state == DownloadState.running) return;
    _jobs.remove(workId);
    _wanted.remove(workId);
    notifyListeners();
  }

  /// One at a time, on purpose.
  ///
  /// Four parallel downloads over one wireless connection are not four times
  /// as fast; they are four things half-finished, and they starve the
  /// streaming that is going on at the same time.
  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = _jobs.values
            .where((job) => job.state == DownloadState.queued)
            .firstOrNull;
        if (next == null) return;
        await _fetch(next);
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _fetch(DownloadJob job) async {
    final vault = library.library;
    final proxy = _proxyFor(job.workId);
    if (vault == null || proxy == null) {
      _jobs[job.workId] = job.copyWith(
        state: DownloadState.failed,
        failure: 'Es besteht keine Verbindung zur Gegenstelle.',
      );
      return;
    }

    _jobs[job.workId] = job.copyWith(state: DownloadState.running);
    notifyListeners();

    final room = Directory(
      p.join((await storageRoot()).path, 'offline', proxy.libraryId),
    );
    final cache = PeerFileCache(proxy: proxy, directory: room);
    var done = 0;
    var bytesDone = 0;

    final wanted = _wanted[job.workId];
    for (final file in vault.contentFiles(job.workId)) {
      if (!_jobs.containsKey(job.workId)) return;
      if (wanted != null && !wanted.contains(file.fileId)) continue;
      if (file.availability == 'offline_copy' && file.offlinePath != null) {
        done++;
        bytesDone += file.sizeBytes;
        continue;
      }
      // Tempo aus dem, was tatsächlich ankommt: ein gleitender Wert, damit
      // eine Sekunde Funkloch nicht als „noch 4 Stunden" durchschlägt.
      final started = Stopwatch()..start();
      var lastReported = Duration.zero;
      try {
        final path = await cache.fileFor(
          _trackFor(vault.playbackTracks(job.workId), file.fileId),
          onProgress: (fraction) {
            _jobs[job.workId] = _jobs[job.workId]!.copyWith(
              done: done,
              bytesDone: bytesDone,
              currentBytes: file.sizeBytes,
              fraction: fraction,
            );
          },
          onBytes: (received, expected) {
            final elapsed = started.elapsed;
            // Viermal je Sekunde reicht für etwas, das ein Mensch liest.
            if (elapsed - lastReported < const Duration(milliseconds: 250)) {
              return;
            }
            lastReported = elapsed;
            final seconds = elapsed.inMilliseconds / 1000;
            final expectedBytes = expected > 0 ? expected : file.sizeBytes;
            _jobs[job.workId] = _jobs[job.workId]!.copyWith(
              bytesDone: bytesDone,
              currentBytes: file.sizeBytes,
              fraction: expectedBytes > 0
                  ? (received / expectedBytes).clamp(0, 1)
                  : null,
              bytesPerSecond: seconds <= 0 ? null : received / seconds,
              bytesLeft: expectedBytes > 0 ? expectedBytes - received : null,
            );
            notifyListeners();
          },
        );
        vault.setOfflineCopy(fileId: file.fileId, path: path);
        done++;
        bytesDone += file.sizeBytes;
        _jobs[job.workId] = _jobs[job.workId]!.copyWith(
          done: done,
          bytesDone: bytesDone,
          fraction: 0,
          currentBytes: 0,
        );
      } on Object catch (error) {
        _jobs[job.workId] = _jobs[job.workId]!.copyWith(
          state: DownloadState.failed,
          done: done,
          failure: 'Abgebrochen bei „${file.filename}": $error',
        );
        notifyListeners();
        return;
      }
    }

    _jobs[job.workId] = _jobs[job.workId]!.copyWith(
      state: DownloadState.done,
      done: done,
      bytesDone: bytesDone,
      currentBytes: 0,
    );
    library.refreshWork(job.workId);
    notifyListeners();
    unawaited(measureStorage());
  }

  static LibraryPlaybackTrack _trackFor(
    List<LibraryPlaybackTrack> tracks,
    String fileId,
  ) => tracks.firstWhere((track) => track.fileId == fileId);
}
