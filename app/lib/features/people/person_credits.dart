import '../../data/work_view.dart';

/// Wofür eine Person in einem Werk steht.
///
/// Fundus kennt heute die Urheber und die Sprecher — das ist, was in den
/// Dateien und in den Abgleichquellen steht. Kommen später Regie, Kamera und
/// Besetzung dazu, kommen sie hier dazu und alles darüber bleibt, wie es ist.
enum CreditRole {
  author('Urheber'),
  narrator('Sprecher');

  const CreditRole(this.label);

  final String label;
}

/// Eine Person und wofür sie in diesem Werk steht.
final class PersonCredit {
  const PersonCredit(this.name, this.role);

  final String name;
  final CreditRole role;
}

/// Wer an einem Werk beteiligt ist.
List<PersonCredit> creditsOf(WorkView work) => [
  for (final name in work.summary.authors)
    if (name.trim().isNotEmpty) PersonCredit(name.trim(), CreditRole.author),
  for (final name in work.summary.narrators)
    if (name.trim().isNotEmpty) PersonCredit(name.trim(), CreditRole.narrator),
];

/// Was eine Person gemacht hat, über alle Bibliotheken hinweg.
///
/// Eine Person steht am Werk und nicht am Regal: wer einen Sprecher antippt,
/// meint seine Hörbücher genauso wie das, was er sonst noch gelesen hat.
List<({WorkView work, Set<CreditRole> roles})> worksOfPerson(
  String name,
  List<WorkView> works,
) {
  final wanted = _normalise(name);
  final found = <({WorkView work, Set<CreditRole> roles})>[];
  for (final work in works) {
    final roles = <CreditRole>{
      for (final credit in creditsOf(work))
        if (_normalise(credit.name) == wanted) credit.role,
    };
    if (roles.isNotEmpty) found.add((work: work, roles: roles));
  }
  found.sort((left, right) => left.work.title.compareTo(right.work.title));
  return List.unmodifiable(found);
}

/// Die Anfangsbuchstaben, für die Kachel: „Marit Sölden" wird zu „MS".
///
/// Personenbilder führt Fundus nicht — es hat keine, und ein erfundenes
/// Gesicht wäre schlimmer als keines. Zwei Buchstaben reichen, um eine Kachel
/// von der nächsten zu unterscheiden, und der Name steht darunter.
String initialsOf(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final single = parts.first;
    return (single.length == 1 ? single : single.substring(0, 2)).toUpperCase();
  }
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}

/// Namen vergleichen sich ohne Rücksicht auf Groß- und Kleinschreibung und
/// auf doppelte Leerzeichen; „karl  may" ist derselbe Mensch wie „Karl May".
String _normalise(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
