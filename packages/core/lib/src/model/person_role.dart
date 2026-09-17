/// Eine Rolle, in der jemand an einem Werk beteiligt ist.
///
/// Die Anbieter sagen dasselbe verschieden: `Actor`, `actress`, `Cast`,
/// `Darsteller`. Die Rolle ist deshalb ein eigener Eintrag mit einem Namen,
/// den man liest, und den Schreibweisen, unter denen sie ankommt. Wer eine
/// Rolle umbenennt, benennt sie an allen Werken um; wer eine Schreibweise
/// ergänzt, führt damit zusammen, was vorher nebeneinander stand.
final class PersonRole {
  const PersonRole({
    required this.id,
    required this.name,
    this.aliases = const [],
    this.position = 0,
  });

  final String id;

  /// Wie die Rolle genannt wird — die Überschrift auf der Werkseite.
  final String name;

  /// Unter welchen Schreibweisen sie ankommt, kleingeschrieben.
  final List<String> aliases;

  /// In welcher Reihenfolge die Rollen stehen.
  final int position;

  /// Ob diese Bezeichnung zu dieser Rolle gehört.
  ///
  /// Verglichen wird als Teilzeichenkette: TMDB schickt `Directing · Director`
  /// und AniList schlicht `Director`. Der eigene Name zählt mit, damit eine
  /// Rolle ohne Aliase trotzdem sich selbst erkennt.
  bool matches(String value) {
    final needle = value.trim().toLowerCase();
    if (needle.isEmpty) return false;
    if (needle == name.toLowerCase()) return true;
    return aliases.any((alias) => needle.contains(alias));
  }

  PersonRole copyWith({String? name, List<String>? aliases, int? position}) =>
      PersonRole(
        id: id,
        name: name ?? this.name,
        aliases: aliases ?? this.aliases,
        position: position ?? this.position,
      );
}

/// Die Überschrift, unter der diese Rollenbezeichnung steht.
///
/// Anbieter hängen an die Rolle oft noch den Namen der Figur — `Darsteller ·
/// Jack`. Die Figur bleibt an der Person, sie macht aber keine eigene Zeile
/// auf; gruppiert wird nach dem Teil davor.
///
/// Was keine Rolle trifft, bleibt stehen wie es ist. Eine unbekannte
/// Bezeichnung anzuzeigen ist ehrlicher, als sie in einen Sammeltopf zu
/// werfen — und sie ist der Hinweis, welchen Alias man ergänzen könnte.
String personRoleLabel(String role, Iterable<PersonRole> known) {
  final head = role.split(' · ').first.trim();
  for (final candidate in known) {
    if (candidate.matches(head)) return candidate.name;
  }
  return head;
}
