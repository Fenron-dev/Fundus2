import 'package:fundus_core/fundus_core.dart';

import 'remote_client.dart';
import 'sync_journal.dart';

/// What one round of syncing changed.
final class SyncReport {
  const SyncReport({
    this.pulledProgress = 0,
    this.pushedProgress = 0,
    this.pulledMarks = 0,
    this.pushedMarks = 0,
    this.skipped = 0,
    this.failures = const [],
    this.entries = const [],
    this.agreedMarks = const {},
  });

  final int pulledProgress;
  final int pushedProgress;
  final int pulledMarks;
  final int pushedMarks;

  /// Works the other side does not have. Not a failure: two libraries are
  /// allowed to differ.
  final int skipped;
  final List<String> failures;

  /// What was decided, work by work. The rule is „the newer write wins"; this
  /// is what makes that visible instead of leaving it to be guessed at.
  final List<SyncEntry> entries;

  /// The decisions worth a second look.
  List<SyncEntry> get conflicts =>
      entries.where((entry) => entry.isConflict).toList(growable: false);

  /// Where both sides ended up, per work — the baseline for the next run.
  final Map<String, String> agreedMarks;

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
    SyncEntry? entry,
  }) => SyncReport(
    pulledProgress: this.pulledProgress + pulledProgress,
    pushedProgress: this.pushedProgress + pushedProgress,
    pulledMarks: this.pulledMarks + pulledMarks,
    pushedMarks: this.pushedMarks + pushedMarks,
    skipped: this.skipped + skipped,
    failures: [...failures, ?failure],
    entries: [...entries, ?entry],
    agreedMarks: agreedMarks,
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
  FundusSync({
    required this.library,
    required this.client,
    required this.libraryId,
    required this.deviceId,
    this.peerName = '',
    this.baseline = const SyncBaseline({}),
  }) : _agreed = Map.of(baseline.marks);

  /// What both sides agreed on last time, per work. Without it a comparison
  /// of two positions cannot tell „the other one moved" from „both moved".
  final SyncBaseline baseline;
  final Map<String, String> _agreed;

  final FundusLibrary library;
  final FundusRemoteClient client;

  /// The library on the other side that answers for this vault.
  final String libraryId;
  final String deviceId;

  /// What the machine on the other side calls itself.
  ///
  /// „mac" is an answer to „welchen Stand willst du?"; a device id is not.
  final String peerName;

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
          report = report._add(
            skipped: 1,
            entry: _entry(workId, SyncDecision.skipped),
          );
          continue;
        }
        report = report._add(
          failure: error.message,
          entry: _entry(workId, SyncDecision.failed, note: error.message),
        );
        if (!error.isTransient && error.statusCode == 401) break;
      }
    }
    // What both sides hold now, for the next run to measure from.
    return SyncReport(
      pulledProgress: report.pulledProgress,
      pushedProgress: report.pushedProgress,
      pulledMarks: report.pulledMarks,
      pushedMarks: report.pushedMarks,
      skipped: report.skipped,
      failures: report.failures,
      entries: report.entries,
      agreedMarks: Map.unmodifiable(_agreed),
    );
  }

  Future<SyncReport> _syncWork(String workId, SyncReport report) async {
    var result = await _syncProgress(workId, report);
    return _syncMarks(workId, result);
  }

  /// Reconciles one work's reading position.
  ///
  /// Three points, not two. Comparing two positions says which is further
  /// along; it never says which one *moved*. The baseline — what both sides
  /// agreed on last time — is what turns „one of these is newer" into „both
  /// of these changed", which is the only case worth calling a conflict.
  ///
  /// A conflict still resolves rather than stopping: a position is not
  /// mergeable, and asking in the middle of a sync would mean asking about
  /// works nobody is thinking about. It is written into the journal with
  /// both values, and can be turned around afterwards.
  Future<SyncReport> _syncProgress(String workId, SyncReport report) async {
    final mine = library.loadProgress(workId);
    final theirs = await client.progress(libraryId, workId);
    final base = baseline[workId];

    if (theirs == null) {
      if (mine == null) return report;
      await _push(workId, mine);
      return report._add(
        pushedProgress: 1,
        entry: _entry(workId, SyncDecision.pushed, mine: mine),
      );
    }
    if (mine == null) {
      _pull(workId, theirs);
      return report._add(
        pulledProgress: 1,
        entry: _entry(workId, SyncDecision.pulled, theirs: theirs),
      );
    }

    // The same write coming back is not a change.
    if (_samePlace(mine, theirs)) {
      _remember(workId, mine);
      return report;
    }

    final mineMark = _markOf(mine);
    final theirsMark = _markOfRemote(theirs);

    // Whoever wrote last, and where that is a draw, whoever is further along
    // — that one has most likely actually read it.
    bool takeTheirs() =>
        theirs.updatedAt.isAfter(mine.updatedAt.toUtc()) ||
        (!mine.updatedAt.toUtc().isAfter(theirs.updatedAt) &&
            (theirs.position.numericValue ?? 0) >
                (mine.position.numericValue ?? 0));

    // No baseline: these two have never been reconciled, so there is no third
    // point and nothing to call a conflict. The old rule, and no drama.
    if (base == null) {
      if (takeTheirs()) {
        _keepAsQuestion(workId, mine);
        _pull(workId, theirs);
        return report._add(
          pulledProgress: 1,
          entry: _entry(
            workId,
            SyncDecision.pulled,
            mine: mine,
            theirs: theirs,
          ),
        );
      }
      _keepAsQuestion(workId, theirs);
      await _push(workId, mine);
      return report._add(
        pushedProgress: 1,
        entry: _entry(workId, SyncDecision.pushed, mine: mine, theirs: theirs),
      );
    }

    final mineMoved = base != mineMark;
    final theirsMoved = base != theirsMark;

    // Only one side moved: nothing to weigh up.
    if (!mineMoved) {
      _pull(workId, theirs);
      return report._add(
        pulledProgress: 1,
        entry: _entry(workId, SyncDecision.pulled, mine: mine, theirs: theirs),
      );
    }
    if (!theirsMoved) {
      await _push(workId, mine);
      return report._add(
        pushedProgress: 1,
        entry: _entry(workId, SyncDecision.pushed, mine: mine, theirs: theirs),
      );
    }

    // Both moved since they last agreed. Something has to be chosen — a
    // position is not mergeable — but it is written down as contested.
    final chooseTheirs = takeTheirs();
    if (chooseTheirs) {
      _keepAsQuestion(workId, mine);
      _pull(workId, theirs);
    } else {
      _keepAsQuestion(workId, theirs);
      await _push(workId, mine);
    }
    return report._add(
      pulledProgress: chooseTheirs ? 1 : 0,
      pushedProgress: chooseTheirs ? 0 : 1,
      entry: _entry(
        workId,
        SyncDecision.conflict,
        mine: mine,
        theirs: theirs,
        note: chooseTheirs
            ? 'Der Stand von dort wurde übernommen.'
            : 'Der Stand von hier wurde gesendet.',
      ),
    );
  }

  /// Keeps the position that lost, as a question for when the work is opened.
  ///
  /// Something has to be chosen during a sync — a position is not mergeable,
  /// and asking about works nobody is thinking about is not asking. But the
  /// side that lost is exactly what someone would want to be asked about, so
  /// it is written down rather than dropped, and the question is put at the
  /// moment it means something: pressing play.
  void _keepAsQuestion(String workId, Object losing) {
    if (library.isReadOnly) return;
    final choice = switch (losing) {
      LibraryPlaybackProgress value => LibraryProgressChoice(
        workId: workId,
        position: value.position,
        fileId: value.fileId,
        finished: value.finished,
        deviceId: value.deviceId,
        deviceName: value.deviceId == deviceId ? 'dieses Gerät' : '',
        updatedAt: value.updatedAt,
        recordedAt: DateTime.now().toUtc(),
      ),
      RemoteProgress value => LibraryProgressChoice(
        workId: workId,
        position: value.position,
        fileId: value.fileId,
        finished: value.finished,
        deviceId: value.deviceId.isEmpty ? libraryId : value.deviceId,
        deviceName: peerName,
        updatedAt: value.updatedAt,
        recordedAt: DateTime.now().toUtc(),
      ),
      _ => null,
    };
    if (choice == null) return;
    try {
      library.recordProgressChoice(choice);
    } on Object {
      // A question that cannot be written down is not worth failing a sync
      // over; the decision itself already stands.
    }
  }

  /// A short, comparable description of where a side stands.
  ///
  /// It has to change whenever the position does and stay identical when it
  /// does not — the whole baseline rests on that.
  static String _markOf(LibraryPlaybackProgress value) =>
      '${value.fileId ?? ''}|'
      '${(value.position.numericValue ?? 0).toStringAsFixed(3)}|'
      '${value.position.elementId ?? ''}|${value.finished}';

  static String _markOfRemote(RemoteProgress value) =>
      '${value.fileId ?? ''}|'
      '${(value.position.numericValue ?? 0).toStringAsFixed(3)}|'
      '${value.position.elementId ?? ''}|${value.finished}';

  void _remember(String workId, LibraryPlaybackProgress value) =>
      _agreed[workId] = _markOf(value);

  /// Where the two sides ended up, for the next run to compare against.
  Map<String, String> get agreed => Map.unmodifiable(_agreed);

  SyncEntry _entry(
    String workId,
    SyncDecision decision, {
    LibraryPlaybackProgress? mine,
    RemoteProgress? theirs,
    String? note,
  }) {
    // Whatever was decided is what both sides hold now, so that is the point
    // the next run measures from.
    final settled = switch (decision) {
      SyncDecision.pulled => theirs == null ? null : _markOfRemote(theirs),
      SyncDecision.pushed => mine == null ? null : _markOf(mine),
      SyncDecision.conflict =>
        note != null && note.contains('von dort')
            ? (theirs == null ? null : _markOfRemote(theirs))
            : (mine == null ? null : _markOf(mine)),
      _ => null,
    };
    if (settled != null) _agreed[workId] = settled;

    return SyncEntry(
      workId: workId,
      title: _titleFor(workId),
      decision: decision,
      at: DateTime.now(),
      mine: mine == null ? null : _describe(mine.position),
      theirs: theirs == null ? null : _describe(theirs.position),
      note: note,
    );
  }

  String _titleFor(String workId) =>
      library
          .listWorks(includeMissing: true)
          .where((work) => work.id == workId)
          .map((work) => work.title)
          .firstOrNull ??
      workId;

  /// A position in words. „Minute 42" is a thing a person can weigh up;
  /// „2520.0" is not.
  static String _describe(MediaPosition position) => switch (position.kind) {
    MediaPositionKind.time => _time(position.numericValue ?? 0),
    MediaPositionKind.page => 'Seite ${(position.numericValue ?? 0).round()}',
    _ =>
      position.label ??
          (position.numericValue == null
              ? 'Anfang'
              : '${(position.numericValue! * 100).round()} %'),
  };

  static String _time(double seconds) {
    final whole = seconds.round();
    final hours = whole ~/ 3600;
    final minutes = (whole % 3600) ~/ 60;
    if (hours > 0) return '$hours h $minutes min';
    return '$minutes min';
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
