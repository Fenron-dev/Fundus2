import 'package:fundus_core/fundus_core.dart';

import 'remote_client.dart';

/// What one round of syncing changed.
final class SyncReport {
  const SyncReport({
    this.pulledProgress = 0,
    this.pushedProgress = 0,
    this.pulledMarks = 0,
    this.pushedMarks = 0,
    this.skipped = 0,
    this.failures = const [],
  });

  final int pulledProgress;
  final int pushedProgress;
  final int pulledMarks;
  final int pushedMarks;

  /// Works the other side does not have. Not a failure: two libraries are
  /// allowed to differ.
  final int skipped;
  final List<String> failures;

  bool get changedAnything =>
      pulledProgress > 0 ||
      pushedProgress > 0 ||
      pulledMarks > 0 ||
      pushedMarks > 0;

  String get summary {
    if (failures.isNotEmpty && !changedAnything) {
      return 'Abgleich fehlgeschlagen: ${failures.first}';
    }
    if (!changedAnything) return 'Nichts zu tun — alles war schon gleich.';
    final parts = <String>[
      if (pulledProgress > 0) '$pulledProgress Stände geholt',
      if (pushedProgress > 0) '$pushedProgress Stände gesendet',
      if (pulledMarks > 0) '$pulledMarks Marken geholt',
      if (pushedMarks > 0) '$pushedMarks Marken gesendet',
    ];
    final tail = failures.isEmpty ? '' : ' · ${failures.length} Fehler';
    return '${parts.join(', ')}$tail';
  }

  SyncReport _add({
    int pulledProgress = 0,
    int pushedProgress = 0,
    int pulledMarks = 0,
    int pushedMarks = 0,
    int skipped = 0,
    String? failure,
  }) => SyncReport(
    pulledProgress: this.pulledProgress + pulledProgress,
    pushedProgress: this.pushedProgress + pushedProgress,
    pulledMarks: this.pulledMarks + pulledMarks,
    pushedMarks: this.pushedMarks + pushedMarks,
    skipped: this.skipped + skipped,
    failures: [...failures, ?failure],
  );
}

/// Bringing two Fundus installations to the same reading state.
///
/// What is synced is what a person carries between devices: where they are in
/// a work, and the marks and notes they left. Not the files, not the
/// catalogue — a work exists on both sides or it does not, and where it does
/// not there is nothing to reconcile.
///
/// The rule is deliberately the simplest one that is defensible: **the newer
/// write wins**, per work. Reading positions are not mergeable — being at
/// minute 12 on one device and minute 40 on another has no middle that means
/// anything — so a rule that picks is better than a dialog nobody reads.
/// Marks are different: they add up rather than replace, so both sides keep
/// everything either side has.
final class FundusSync {
  const FundusSync({
    required this.library,
    required this.client,
    required this.libraryId,
    required this.deviceId,
  });

  final FundusLibrary library;
  final FundusRemoteClient client;

  /// The library on the other side that answers for this vault.
  final String libraryId;
  final String deviceId;

  /// Reconciles every work of the local vault.
  Future<SyncReport> run({Iterable<String>? workIds}) async {
    var report = const SyncReport();
    final ids = workIds ?? library.listWorks().map((work) => work.id).toList();
    for (final workId in ids) {
      try {
        report = await _syncWork(workId, report);
      } on FundusRemoteException catch (error) {
        // One work that cannot be reconciled must not stop the rest; a
        // library where the other side is missing half the works would
        // otherwise never sync at all.
        if (error.statusCode == 404) {
          report = report._add(skipped: 1);
          continue;
        }
        report = report._add(failure: error.message);
        if (!error.isTransient && error.statusCode == 401) break;
      }
    }
    return report;
  }

  Future<SyncReport> _syncWork(String workId, SyncReport report) async {
    var result = await _syncProgress(workId, report);
    return _syncMarks(workId, result);
  }

  Future<SyncReport> _syncProgress(String workId, SyncReport report) async {
    final mine = library.loadProgress(workId);
    final theirs = await client.progress(libraryId, workId);

    if (theirs == null) {
      if (mine == null) return report;
      await _push(workId, mine);
      return report._add(pushedProgress: 1);
    }
    if (mine == null) {
      _pull(workId, theirs);
      return report._add(pulledProgress: 1);
    }

    // The same write coming back is not a change.
    if (_samePlace(mine, theirs)) return report;

    if (theirs.updatedAt.isAfter(mine.updatedAt.toUtc())) {
      _pull(workId, theirs);
      return report._add(pulledProgress: 1);
    }
    if (mine.updatedAt.toUtc().isAfter(theirs.updatedAt)) {
      await _push(workId, mine);
      return report._add(pushedProgress: 1);
    }
    // Written at the same moment on both sides: whoever is further along has
    // most likely actually read it.
    final mineValue = mine.position.numericValue ?? 0;
    final theirsValue = theirs.position.numericValue ?? 0;
    if (theirsValue > mineValue) {
      _pull(workId, theirs);
      return report._add(pulledProgress: 1);
    }
    if (mineValue > theirsValue) {
      await _push(workId, mine);
      return report._add(pushedProgress: 1);
    }
    return report;
  }

  static bool _samePlace(LibraryPlaybackProgress mine, RemoteProgress theirs) =>
      mine.fileId == theirs.fileId &&
      mine.finished == theirs.finished &&
      (mine.position.numericValue ?? 0) ==
          (theirs.position.numericValue ?? 0) &&
      mine.position.elementId == theirs.position.elementId;

  void _pull(String workId, RemoteProgress theirs) {
    if (library.isReadOnly) return;
    library.saveMediaProgress(
      workId: workId,
      fileId: theirs.fileId ?? '',
      position: theirs.position,
      finished: theirs.finished,
      // The write keeps the name of the device it came from, so the history
      // still shows where a jump came from.
      deviceId: theirs.deviceId.isEmpty ? deviceId : theirs.deviceId,
    );
  }

  Future<void> _push(String workId, LibraryPlaybackProgress mine) =>
      client.saveProgress(
        libraryId: libraryId,
        workId: workId,
        fileId: mine.fileId ?? '',
        position: mine.position,
        finished: mine.finished,
        deviceId: deviceId,
      );

  Future<SyncReport> _syncMarks(String workId, SyncReport report) async {
    final mine = library.loadAnnotations(workId);
    final theirs = await client.annotations(libraryId, workId);

    var result = report;

    // Marks add up. A bookmark made on the phone belongs on the desktop too,
    // and neither side deleting is inferred from absence — that would erase a
    // mark made while the other device was switched off.
    final myBookmarks = {
      for (final bookmark in mine.bookmarks) _fingerprintOf(bookmark),
    };
    for (final bookmark in theirs.bookmarks) {
      if (myBookmarks.contains(bookmark.fingerprint)) continue;
      if (library.isReadOnly) break;
      await library.addMediaBookmark(
        workId: workId,
        fileId: bookmark.fileId ?? '',
        position: bookmark.position,
        label: bookmark.label,
        note: bookmark.note,
      );
      result = result._add(pulledMarks: 1);
    }

    final theirBookmarks = {
      for (final bookmark in theirs.bookmarks) bookmark.fingerprint,
    };
    for (final bookmark in mine.bookmarks) {
      if (theirBookmarks.contains(_fingerprintOf(bookmark))) continue;
      await client.saveBookmark(
        libraryId: libraryId,
        workId: workId,
        fileId: bookmark.fileId ?? '',
        position: bookmark.mediaPosition,
        label: bookmark.label,
        note: bookmark.note,
      );
      result = result._add(pushedMarks: 1);
    }

    final myHighlights = {
      for (final highlight in mine.highlights)
        _fingerprintOfHighlight(highlight),
    };
    for (final highlight in theirs.highlights) {
      if (myHighlights.contains(highlight.fingerprint)) continue;
      if (library.isReadOnly) break;
      await library.addTextHighlight(
        workId: workId,
        fileId: highlight.fileId ?? '',
        position: highlight.position,
        quote: highlight.quote ?? '',
        color: highlight.color ?? '#FFF176',
        note: highlight.note,
      );
      result = result._add(pulledMarks: 1);
    }

    final theirHighlights = {
      for (final highlight in theirs.highlights) highlight.fingerprint,
    };
    for (final highlight in mine.highlights) {
      if (theirHighlights.contains(_fingerprintOfHighlight(highlight))) {
        continue;
      }
      await client.saveHighlight(
        libraryId: libraryId,
        workId: workId,
        fileId: highlight.fileId ?? '',
        position: highlight.mediaPosition,
        quote: highlight.quote,
        color: highlight.color,
        note: highlight.note,
      );
      result = result._add(pushedMarks: 1);
    }

    return result;
  }

  /// The same rule the remote side uses, applied to a local mark.
  static String _fingerprintOf(LibraryBookmark bookmark) => RemoteMark(
    id: bookmark.id,
    fileId: bookmark.fileId,
    position: bookmark.mediaPosition,
  ).fingerprint;

  static String _fingerprintOfHighlight(LibraryHighlight highlight) =>
      RemoteMark(
        id: highlight.id,
        fileId: highlight.fileId,
        position: highlight.mediaPosition,
        quote: highlight.quote,
      ).fingerprint;
}
