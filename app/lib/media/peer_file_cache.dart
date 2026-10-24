import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

final class TransferPaused implements Exception {
  const TransferPaused();
  @override
  String toString() =>
      'Übertragung pausiert; bereits empfangene Daten bleiben erhalten.';
}

/// Shared gateway for readers and downloads. A partial file resumes only
/// under the same strong ETag; only verified complete files are published.
final class PeerFileCache {
  const PeerFileCache({required this.proxy, required this.directory});
  final FundusStreamProxy proxy;
  final Directory directory;
  static final Map<String, Future<String>> _inFlight = {};

  Future<String> fileFor(
    LibraryPlaybackTrack track, {
    void Function(double? fraction)? onProgress,
    void Function(int received, int expected)? onBytes,
    Future<bool> Function()? mayTransfer,
    int? maxBytes,
  }) {
    if (!track.isRemote) return Future.value(track.absolutePath);
    if (!FundusId.isSafe(track.fileId)) {
      return Future.error(
        const FormatException('Unsichere Datei-ID für Offline-Kopie.'),
      );
    }
    final key = p.join(
      directory.absolute.path,
      '${track.fileId}${p.extension(track.title)}',
    );
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final operation = _fetch(track, onProgress, onBytes, mayTransfer, maxBytes);
    final guarded = operation.whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = guarded;
    return guarded;
  }

  static Future<Map<String, dynamic>?> _marker(File file) async {
    try {
      if (await file.length() > 4096) return null;
      final value = jsonDecode(await file.readAsString());
      return value is Map<String, dynamic> ? value : null;
    } on Object {
      return null;
    }
  }

  Future<String> _fetch(
    LibraryPlaybackTrack track,
    void Function(double?)? onProgress,
    void Function(int, int)? onBytes,
    Future<bool> Function()? mayTransfer,
    int? maxBytes,
  ) async {
    await directory.create(recursive: true);
    final target = File(
      p.join(directory.path, '${track.fileId}${p.extension(track.title)}'),
    );
    final marker = File('${target.path}.meta');
    final partial = File('${target.path}.part');
    final partialMarker = File('${partial.path}.meta');
    final stored = await _marker(marker);
    final complete =
        await target.exists() &&
        stored?['length'] is int &&
        await target.length() == stored!['length'] &&
        (stored['length'] as int) > 0;
    var savedPartial = await _marker(partialMarker);
    var offset = await partial.exists() ? await partial.length() : 0;
    final partialEtag = savedPartial?['etag'];
    if (partialEtag is! String ||
        !partialEtag.startsWith('"') ||
        savedPartial?['length'] is! int ||
        offset <= 0 ||
        offset >= (savedPartial!['length'] as int) ||
        savedPartial['revision'] != track.contentRevision) {
      offset = 0;
      savedPartial = null;
    }
    final client = HttpClient()..autoUncompress = false;
    try {
      // At most one restart when a peer changed the resource or ignored Range.
      for (var attempt = 0; attempt < 2; attempt++) {
        if (mayTransfer != null && !await mayTransfer()) {
          throw const TransferPaused();
        }
        final request = await client
            .getUrl(
              proxy.uriFor(track.fileId, extension: p.extension(track.title)),
            )
            .timeout(const Duration(seconds: 20));
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (offset > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
          request.headers.set(
            HttpHeaders.ifRangeHeader,
            savedPartial!['etag'] as String,
          );
        } else if (complete && stored['etag'] is String) {
          request.headers.set(
            HttpHeaders.ifNoneMatchHeader,
            stored['etag'] as String,
          );
        } else if (complete && stored['last_modified'] is String) {
          request.headers.set(
            HttpHeaders.ifModifiedSinceHeader,
            stored['last_modified'] as String,
          );
        }
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if (response.statusCode == HttpStatus.notModified && complete) {
          return target.path;
        }
        if (response.statusCode >= 500 && complete) return target.path;
        if (response.statusCode == 416 && offset > 0) {
          await response.listen((_) {}).cancel();
          offset = 0;
          continue;
        }
        if (response.statusCode >= 400) {
          throw HttpException(
            'Die Datei ließ sich nicht holen (${response.statusCode}).',
          );
        }
        final etag = response.headers.value(HttpHeaders.etagHeader);
        final lastModified = response.headers.value(
          HttpHeaders.lastModifiedHeader,
        );
        var expected = response.contentLength;
        if (response.statusCode == HttpStatus.partialContent) {
          final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
            response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
          );
          final start = range == null ? -1 : int.parse(range[1]!);
          final end = range == null ? -1 : int.parse(range[2]!);
          final total = range == null ? -1 : int.parse(range[3]!);
          if (offset <= 0 ||
              start != offset ||
              end != total - 1 ||
              total != savedPartial?['length'] ||
              etag != savedPartial?['etag'] ||
              (expected >= 0 && expected != total - offset)) {
            await response.listen((_) {}).cancel();
            offset = 0;
            if (attempt == 1) {
              throw const HttpException('Ungültige Teilantwort.');
            }
            continue;
          }
          expected = total;
        } else if (response.statusCode == HttpStatus.ok) {
          offset = 0; // A full response must replace, never append.
        } else {
          throw const HttpException('Unerwartete Antwort für Mediendatei.');
        }
        final identityMatches =
            stored != null &&
            (etag != null
                ? stored['etag'] == etag
                : lastModified != null &&
                      stored['last_modified'] == lastModified);
        if (offset == 0 &&
            complete &&
            expected > 0 &&
            identityMatches &&
            await target.length() == expected) {
          return target.path;
        }
        if (maxBytes != null && expected > maxBytes) {
          throw const HttpException(
            'Datei ist größer als in der Budgetvorschau angekündigt. Bitte Katalog aktualisieren.',
          );
        }
        await partialMarker.writeAsString(
          jsonEncode({
            'length': expected,
            'etag': etag,
            'revision': track.contentRevision,
          }),
          flush: true,
        );
        final sink = partial.openWrite(
          mode: offset > 0 ? FileMode.append : FileMode.write,
        );
        var received = offset;
        try {
          onProgress?.call(expected > 0 ? received / expected : null);
          onBytes?.call(received, expected > 0 ? expected : 0);
          await for (final chunk in response.timeout(
            const Duration(seconds: 30),
          )) {
            if (mayTransfer != null && !await mayTransfer()) {
              throw const TransferPaused();
            }
            if (expected >= 0 && received + chunk.length > expected) {
              throw const HttpException(
                'Die Datei überschreitet die angekündigte Größe.',
              );
            }
            if (maxBytes != null && received + chunk.length > maxBytes) {
              throw const HttpException(
                'Datei überschreitet das reservierte Offline-Budget.',
              );
            }
            sink.add(chunk);
            received += chunk.length;
            onProgress?.call(expected > 0 ? received / expected : null);
            onBytes?.call(received, expected > 0 ? expected : 0);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (expected >= 0 && received != expected) {
          throw const HttpException('Die Datei kam unvollständig an.');
        }
        if (received <= 0) throw const HttpException('Leere Mediendatei.');
        if (await target.exists()) await target.delete();
        await partial.rename(target.path);
        await marker.writeAsString(
          jsonEncode({
            'length': received,
            'revision': track.contentRevision,
            'etag': ?etag,
            'last_modified': ?lastModified,
          }),
          flush: true,
        );
        if (await partialMarker.exists()) await partialMarker.delete();
        return target.path;
      }
      throw const HttpException('Die Datei konnte nicht fortgesetzt werden.');
    } on SocketException {
      if (complete) return target.path;
      rethrow;
    } on TimeoutException {
      if (complete) return target.path;
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> clear() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
