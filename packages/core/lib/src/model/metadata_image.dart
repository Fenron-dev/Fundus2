/// An immutable, content-addressed image inside the managed version store.
/// History is data: it cannot name an arbitrary file outside this namespace.
final class MetadataImageVersion {
  const MetadataImageVersion({
    required this.path,
    required this.digest,
    required this.bytes,
  });
  static const directory = '.library/covers/versions';
  static const maxBytes = 32 * 1024 * 1024;
  static final filenamePattern = RegExp(
    r'^([a-f0-9]{64})\.(cover|backdrop)\.(jpg|png|webp|gif|bmp)$',
  );
  final String path, digest;
  final int bytes;
  void validate() {
    final match = filenamePattern.firstMatch(path.split('/').last);
    if (match == null ||
        path != '$directory/${match.group(0)}' ||
        digest != match.group(1) ||
        bytes < 1 ||
        bytes > maxBytes) {
      throw const FormatException('Ungültiger Bildversionsbeleg.');
    }
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'sha256': digest,
    'bytes': bytes,
  };
  static MetadataImageVersion fromJson(Object? raw) {
    if (raw is! Map ||
        raw['path'] is! String ||
        raw['sha256'] is! String ||
        raw['bytes'] is! int) {
      throw const FormatException('Ungültige Bildversion.');
    }
    return MetadataImageVersion(
      path: raw['path'] as String,
      digest: raw['sha256'] as String,
      bytes: raw['bytes'] as int,
    )..validate();
  }

  static MetadataImageVersion? inState(Object? value) {
    if (value is! Map || value['image'] == null) return null;
    return fromJson(value['image']);
  }
}
