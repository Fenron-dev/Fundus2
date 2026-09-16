import 'dart:convert';

/// Was für ein Wert hinter einer Eigenschaft steht.
///
/// Der Typ entscheidet, wie die Oberfläche ihn erfragt und wie sortiert wird —
/// eine Bewertung gehört an Sterne und nach Größe geordnet, ein Datum an einen
/// Kalender und chronologisch. Gespeichert wird alles als JSON; der Typ sagt,
/// wie es zu lesen ist.
enum PropertyValueType {
  text('Text'),
  number('Zahl'),
  date('Datum'),
  rating('Bewertung'),
  link('Link'),
  note('Notiz'),
  list('Liste'),
  tags('Schlagwörter');

  const PropertyValueType(this.label);

  final String label;

  static PropertyValueType? byName(String value) {
    for (final type in PropertyValueType.values) {
      if (type.name == value) return type;
    }
    return null;
  }
}

/// Eine Eigenschaft, die es für eine Medienart gibt.
///
/// Die Definition steht getrennt vom Wert, damit „Erscheinungsland" einmal
/// heißt, wie es heißt, und nicht an jedem Werk neu geschrieben — und damit
/// sich umbenennen lässt, ohne tausend Werke anzufassen.
final class WorkPropertyDefinition {
  const WorkPropertyDefinition({
    required this.id,
    required this.mediaKind,
    required this.name,
    required this.valueType,
    this.options = const [],
    this.protected = false,
    this.position = 0,
  });

  final String id;

  /// Für welche Art von Werk. Leer heißt: für alle.
  final String mediaKind;

  final String name;
  final PropertyValueType valueType;

  /// Die zulässigen Werte, wo es welche gibt — sonst leer.
  final List<String> options;

  /// Ob diese Eigenschaft zum geschützten Bereich gehört.
  ///
  /// Nicht jedes Feld verrät gleich viel. „Seitenzahl" ist harmlos, eine
  /// eigens angelegte Eigenschaft kann es nicht sein; wer sie kennzeichnet,
  /// nimmt sie samt ihren Werten aus Filtern, Suche und Vorschlägen heraus,
  /// solange das Schloss zu ist.
  final bool protected;

  /// In welcher Reihenfolge die Felder stehen.
  final int position;

  WorkPropertyDefinition copyWith({
    String? name,
    PropertyValueType? valueType,
    List<String>? options,
    bool? protected,
    int? position,
  }) => WorkPropertyDefinition(
    id: id,
    mediaKind: mediaKind,
    name: name ?? this.name,
    valueType: valueType ?? this.valueType,
    options: options ?? this.options,
    protected: protected ?? this.protected,
    position: position ?? this.position,
  );
}

/// Was ein Werk zu einer Eigenschaft zu sagen hat.
final class WorkPropertyValue {
  const WorkPropertyValue({
    required this.definitionId,
    required this.value,
    this.source = 'user',
    this.updatedAt,
  });

  final String definitionId;

  /// Der Wert, so wie der Typ ihn meint: eine Zeichenkette, eine Zahl, eine
  /// Liste. `null` gibt es nicht — wer nichts zu sagen hat, hat keine Zeile.
  final Object value;

  /// Woher er kommt — von Hand, aus einem Abgleich, aus einem Sidecar.
  final String source;

  final DateTime? updatedAt;

  String get encoded => jsonEncode(value);

  static Object? decode(String json) {
    try {
      return jsonDecode(json);
    } on FormatException {
      return null;
    }
  }

  /// Ob dieser Wert zu seinem Typ passt.
  ///
  /// Geprüft wird beim Schreiben, nicht beim Lesen: eine Datenbank, in der
  /// eine Bewertung als Zeichenkette steht, macht jede spätere Sortierung zu
  /// einem Sonderfall.
  static bool fits(PropertyValueType type, Object value) => switch (type) {
    PropertyValueType.text ||
    PropertyValueType.note ||
    PropertyValueType.link => value is String,
    PropertyValueType.number => value is num,
    PropertyValueType.rating => value is num && value >= 0 && value <= 5,
    PropertyValueType.date =>
      value is String && DateTime.tryParse(value) != null,
    PropertyValueType.list || PropertyValueType.tags =>
      value is List && value.every((it) => it is String),
  };
}
