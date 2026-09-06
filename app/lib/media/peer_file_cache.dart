import 'dart:convert';
import 'dart:io';

import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

/// A remote file, made local so a reader can open it.
///
/// The players stream: mpv asks for the stretch of bytes it needs and plays
/// it. A reader cannot. A comic archive has its index at the end, an EPUB is
/// a zip of many small entries, a PDF seeks all over itself — all three want
/// a file, so a remote one is fetched once and kept.
///
/// Kept, not streamed, and kept deliberately: reopening a volume at chapter
/// forty should not fetch two hundred megabytes again. It is a cache and may
/// be thrown away; what it must never hold is the only copy of anything.
final class PeerFileCache {
  const PeerFileCache({required this.proxy, required this.directory});

  final FundusStreamProxy proxy;
  final Directory directory;

  /// The file on this device, fetching it first if it is not here yet.
  ///
  /// [onProgress] is called with a fraction between 0 and 1 where the other
  /// side said how large the file is, and with null where it did not — a
  /// download of unknown length still has to look like it is moving.
  ///
  /// [onBytes] carries how much has arrived and how much was announced, which
  /// is what a speed and a remaining time are made of. Zero as the total
  /// means the other side did not say.
  Future<String> fileFor(
    LibraryPlaybackTrack track, {
    void Function(double? fraction)? onProgress,
    void Function(int received, int expected)? onBytes,
  }) async {
    if (!track.isRemote) return track.absolutePath;
    await directory.create(recursive: true);
    final target = File(
      p.join(directory.path, '${track.fileId}${p.extension(track.title)}'),
    );

    final client = HttpClient();
    try {
      final request = await client.getUrl(
        proxy.uriFor(track.fileId, extension: p.extension(track.title)),
      );
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw HttpException(
          'Die Datei ließ sich nicht holen (${response.statusCode}).',
        );
      }
      // Size alone is not an identity: a peer can replace a file without
      // changing its length. The proxy forwards ETag/Last-Modified, which we
      // persist beside the cache entry and compare on the next request.
      final expected = response.contentLength;
      final etag = response.headers.value(HttpHeaders.etagHeader);
      final lastModified = response.headers.value(
        HttpHeaders.lastModifiedHeader,
      );
      final marker = File('${target.path}.meta');
      Map<String, dynamic>? stored;
      if (await marker.exists()) {
        try {
          stored =
              jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
        } on Object {
          stored = null;
        }
      }
      final identityMatches = etag != null
          ? stored != null && stored['etag'] == etag
          : lastModified != null &&
                stored != null &&
                stored['last_modified'] == lastModified;
      if (expected > 0 &&
          identityMatches &&
          await target.exists() &&
          await target.length() == expected) {
        await response.drain<void>();
        return target.path;
      }

      // Written beside the real name and moved into place at the end: a
      // download interrupted halfway must not look like a finished file.
      final partial = File('${target.path}.part');
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(expected > 0 ? received / expected : null);
          onBytes?.call(received, expected > 0 ? expected : 0);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      await marker.writeAsString(
        jsonEncode({
          ...?(etag == null ? null : {'etag': etag}),
          ...?(lastModified == null ? null : {'last_modified': lastModified}),
        }),
        flush: true,
      );
      return target.path;
    } finally {
      client.close(force: true);
    }
  }

  /// Throws the cache away. The library keeps its index either way.
  Future<void> clear() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
