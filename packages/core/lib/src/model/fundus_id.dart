import 'dart:math';

/// Generates RFC 4122 version 4 identifiers without a platform dependency.
abstract final class FundusId {
  static final Random _random = Random.secure();

  /// IDs cross the peer protocol and are also used in URL and cache paths.
  /// Keep the accepted alphabet deliberately narrower than a generic string so
  /// a malformed or hostile peer cannot turn an ID into a path component.
  static final RegExp safePattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  static bool isSafe(String value) => safePattern.hasMatch(value);

  static String generate() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
