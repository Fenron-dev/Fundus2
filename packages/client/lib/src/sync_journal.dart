/// What the sync decided about one work.
enum SyncDecision {
  /// The other side's state was newer and was taken.
  pulled('Von dort übernommen'),

  /// This side's state was newer and was sent.
  pushed('Dorthin gesendet'),

  /// Both sides had moved since they were last the same. One was chosen —
  /// the entry says which, and it can still be turned around.
  conflict('Beide geändert'),

  /// Nothing to do.
  unchanged('Unverändert'),

  /// The work does not exist on the other side.
  skipped('Dort nicht vorhanden'),

  /// Something went wrong for this work alone.
  failed('Fehlgeschlagen');

  const SyncDecision(this.label);

  final String label;
}

/// One line of what happened, so that „der neuere Stand gewinnt" stops being
/// a rule applied in the dark.
///
/// A conflict is not a failure and does not stop anything: a position is not
/// mergeable, so something has to be chosen, and asking in the middle of a
/// sync would mean asking about works nobody is thinking about. It is
/// recorded instead, with both values, and can be turned around afterwards.
final class SyncEntry {
  const SyncEntry({
    required this.workId,
    required this.title,
    required this.decision,
    required this.at,
    this.mine,
    this.theirs,
    this.note,
  });

  factory SyncEntry.fromJson(Map<String, Object?> value) => SyncEntry(
    workId: '${value['work_id'] ?? ''}',
    title: '${value['title'] ?? ''}',
    decision: SyncDecision.values.firstWhere(
      (decision) => decision.name == value['decision'],
      orElse: () => SyncDecision.unchanged,
    ),
    at: DateTime.tryParse('${value['at'] ?? ''}') ?? DateTime.now(),
    mine: value['mine'] as String?,
    theirs: value['theirs'] as String?,
    note: value['note'] as String?,
  );

  final String workId;
  final String title;
  final SyncDecision decision;
  final DateTime at;

  /// Where each side stood, in words. Kept as text rather than as numbers:
  /// this is a record for a person to read, and a chapter and a minute mean
  /// more than a float.
  final String? mine;
  final String? theirs;
  final String? note;

  bool get isConflict => decision == SyncDecision.conflict;

  Map<String, Object?> toJson() => {
    'work_id': workId,
    'title': title,
    'decision': decision.name,
    'at': at.toUtc().toIso8601String(),
    'mine': mine,
    'theirs': theirs,
    'note': note,
  };
}

/// What both sides agreed on last time, per work.
///
/// Without it there is no way to tell „the other side moved" from „both
/// moved": a comparison of two positions says which is further, never which
/// changed. This is the third point that makes a conflict visible.
final class SyncBaseline {
  const SyncBaseline(this.marks);

  factory SyncBaseline.fromJson(Map<String, String> value) =>
      SyncBaseline(Map.unmodifiable(value));

  final Map<String, String> marks;

  String? operator [](String workId) => marks[workId];

  SyncBaseline with_(String workId, String mark) =>
      SyncBaseline({...marks, workId: mark});

  Map<String, String> toJson() => marks;
}
