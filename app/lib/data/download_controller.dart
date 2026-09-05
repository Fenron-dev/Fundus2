import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
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
    this.fraction,
    this.failure,
  });

  final String workId;
  final String title;
  final DownloadState state;

  /// Files finished, and files in the work.
  final int done;
  final int total;

  /// How far the file being fetched has come, where the other side said how
  /// large it is.
  final double? fraction;
  final String? failure;

  DownloadJob copyWith({
    DownloadState? state,
    int? done,
    double? fraction,
    String? failure,
  }) => DownloadJob(
    workId: workId,
    title: title,
    state: state ?? this.state,
    done: done ?? this.done,
    total: total,
    fraction: fraction,
    failure: failure ?? this.failure,
  );

  /// Roughly how far along the whole work is.
  double get progress {
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

  /// Queues a work and starts working through the queue.
  Future<void> download(WorkView work) async {
    final vault = library.library;
    if (vault == null || _proxyFor(work.id) == null) return;
    if (_jobs.containsKey(work.id)) return;
    final files = vault.contentFiles(work.id);
    if (files.isEmpty) return;

    _jobs[work.id] = DownloadJob(
      workId: work.id,
      title: work.title,
      state: DownloadState.queued,
      total: files.length,
    );
    notifyListeners();
    unawaited(_drain());
  }

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
    library.refresh();
    notifyListeners();
  }

  /// Takes a work out of the queue. What is already fetched stays — half a
  /// download thrown away is a second download later.
  void cancel(String workId) {
    final job = _jobs[workId];
    if (job == null || job.state == DownloadState.running) return;
    _jobs.remove(workId);
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

    for (final file in vault.contentFiles(job.workId)) {
      if (!_jobs.containsKey(job.workId)) return;
      if (file.availability == 'offline_copy' && file.offlinePath != null) {
        done++;
        continue;
      }
      try {
        final path = await cache.fileFor(
          _trackFor(vault.playbackTracks(job.workId), file.fileId),
          onProgress: (fraction) {
            _jobs[job.workId] = _jobs[job.workId]!.copyWith(
              done: done,
              fraction: fraction,
            );
            notifyListeners();
          },
        );
        vault.setOfflineCopy(fileId: file.fileId, path: path);
        done++;
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
    );
    library.refresh();
    notifyListeners();
  }

  static LibraryPlaybackTrack _trackFor(
    List<LibraryPlaybackTrack> tracks,
    String fileId,
  ) => tracks.firstWhere((track) => track.fileId == fileId);
}
