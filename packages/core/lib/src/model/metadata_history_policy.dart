final class MetadataHistoryPolicy {
  const MetadataHistoryPolicy({
    this.retainBatches = 100,
    this.byteBudget = 16 * 1024 * 1024,
    this.imageBudget = 256 * 1024 * 1024,
  });
  final int retainBatches, byteBudget, imageBudget;

  void validate() {
    if (retainBatches < 1 ||
        retainBatches > 1000 ||
        byteBudget < 1024 ||
        byteBudget > 32 * 1024 * 1024 ||
        imageBudget < 1024 * 1024 ||
        imageBudget > 2 * 1024 * 1024 * 1024) {
      throw const FormatException(
        'Ungültige Aufbewahrungsgrenzen für den Metadatenverlauf.',
      );
    }
  }

  Map<String, Object?> toJson() => {
    'format_version': 1,
    'retain_batches': retainBatches,
    'byte_budget': byteBudget,
    'image_budget': imageBudget,
  };
  static MetadataHistoryPolicy fromJson(Object? raw) {
    if (raw is! Map ||
        raw['format_version'] != 1 ||
        raw['retain_batches'] is! int ||
        raw['byte_budget'] is! int ||
        raw['image_budget'] is! int) {
      throw const FormatException('Nicht unterstützte Verlaufsaufbewahrung.');
    }
    return MetadataHistoryPolicy(
      retainBatches: raw['retain_batches'] as int,
      byteBudget: raw['byte_budget'] as int,
      imageBudget: raw['image_budget'] as int,
    )..validate();
  }
}
