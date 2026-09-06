import 'package:fundus_core/fundus_core.dart';

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
  const PersonCredit(this.name, this.roleLabel, {this.imagePath});

  final String name;

  /// Was diese Person hier getan hat, in den Worten der Quelle: „Regie",
  /// „Sprecher · Denji", „Urheber".
  final String roleLabel;

  /// Der Pfad zum Bild in der Bibliothek, wo eines geholt wurde.
  final String? imagePath;
}

/// Wer an einem Werk beteiligt ist.
///
/// Steht im Katalog eine Besetzung — vom Abgleich mitgebracht —, dann ist sie
/// die Antwort: sie ist genauer und hat Gesichter. Sonst bleiben die Namen
/// aus den Dateien, denn ein Buch hat keine Besetzung, aber einen Autor.
List<PersonCredit> creditsOf(WorkView work, {FundusLibrary? library}) {
  final stored = library == null
      ? const <({String name, String role, String? imagePath})>[]
      : library.peopleOf(work.id);
  if (stored.isNotEmpty) {
    return [
      for (final person in stored)
        PersonCredit(person.name, person.role, imagePath: person.imagePath),
    ];
  }
  return [
    for (final name in work.summary.authors)
      if (name.trim().isNotEmpty)
        PersonCredit(name.trim(), CreditRole.author.label),
    for (final name in work.summary.narrators)
      if (name.trim().isNotEmpty)
        PersonCredit(name.trim(), CreditRole.narrator.label),
  ];
}

/// Was eine Person gemacht hat, über alle Bibliotheken hinweg.
///
/// Eine Person steht am Werk und nicht am Regal: wer einen Sprecher antippt,
/// meint seine Hörbücher genauso wie das, was er sonst noch gelesen hat.
List<({WorkView work, Set<String> roles})> worksOfPerson(
  String name,
  List<WorkView> works, {
  FundusLibrary? library,
}) {
  final wanted = _normalise(name);
  final found = <({WorkView work, Set<String> roles})>[];
  for (final work in works) {
    final roles = <String>{
      for (final credit in creditsOf(work, library: library))
        if (_normalise(credit.name) == wanted) credit.roleLabel,
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
