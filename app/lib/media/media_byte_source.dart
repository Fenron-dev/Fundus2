import 'dart:io';

import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// Where a player gets its bytes.
///
/// This is the generalisation of `ComicPageSource` from the previous client —
/// the one place there that already had an interface with two implementations
/// instead of two parallel trees. Audio, video and documents now go through
/// the same door, which is what allows a single player controller instead of a
/// local one and a remote one.
///
/// Implementations to come: `OfflineCopySource` for downloaded copies and
/// `HttpRangeSource` for streaming from a peer.
abstract interface class MediaByteSource {
  /// Stable identifier of the underlying file.
  String get fileId;

  /// Human-readable title for the player's track list.
  String get title;

  /// Where the bytes are. The player shows it; it never branches on it.
  FundusOrigin get origin;

  Duration? get duration;

  /// What the playback engine opens. Resolving may touch the network for
  /// remote sources, so it is asynchronous even where the local one answers
  /// immediately.
  Future<Uri> resolve();

  /// Whether the bytes can be reached right now.
  Future<bool> isReachable();
}

/// A file on this device — the vault's own media, or an offline copy.
final class LocalFileSource implements MediaByteSource {
  const LocalFileSource({
    required this.fileId,
    required this.title,
    required this.path,
    this.duration,
    this.origin = FundusOrigin.local,
  });

  factory LocalFileSource.fromTrack(
    LibraryPlaybackTrack track, {
    FundusOrigin origin = FundusOrigin.local,
  }) => LocalFileSource(
    fileId: track.fileId,
    title: track.title,
    path: track.absolutePath,
    duration: track.duration,
    origin: origin,
  );

  @override
  final String fileId;

  @override
  final String title;

  final String path;

  @override
  final Duration? duration;

  @override
  final FundusOrigin origin;

  @override
  Future<Uri> resolve() async => Uri.file(path);

  @override
  Future<bool> isReachable() => File(path).exists();
}

/// A file on a Fundus this device is paired with.
///
/// The bytes never come through Dart on the way to the player: the engine
/// opens the loopback address the proxy hands out, and the proxy is what
/// carries the token and the pinned certificate. Seeking therefore works the
/// way it does for a local file — the engine asks for a range and the range
/// comes back — which is the whole reason this is a proxy and not a download.
final class RemoteFileSource implements MediaByteSource {
  const RemoteFileSource({
    required this.fileId,
    required this.title,
    required this.uri,
    this.duration,
    this.origin = FundusOrigin.stream,
  });

  factory RemoteFileSource.fromTrack(
    LibraryPlaybackTrack track, {
    required FundusStreamProxy proxy,
  }) => RemoteFileSource(
    fileId: track.fileId,
    title: track.title,
    uri: proxy.uriFor(track.fileId, extension: _extensionOf(track.title)),
    duration: track.duration,
  );

  @override
  final String fileId;

  @override
  final String title;

  final Uri uri;

  @override
  final Duration? duration;

  @override
  final FundusOrigin origin;

  @override
  Future<Uri> resolve() async => uri;

  @override
  Future<bool> isReachable() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      // Eine Frist für die ganze Frage, nicht nur für das Verbinden: eine
      // Gegenstelle, die die Verbindung annimmt und dann schweigt, hat die
      // App sonst festgehalten, bis jemand sie abgeschossen hat.
      final response = await () async {
        final request = await client.openUrl('HEAD', uri);
        return request.close();
      }().timeout(const Duration(seconds: 6));
      await response.drain<void>();
      return response.statusCode < 400;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// mpv chooses a demuxer by extension before it reads a byte.
  static String _extensionOf(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0) return '';
    final value = filename.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(value) ? value : '';
  }
}

/// Where the bytes of a track are, wherever they happen to live.
///
/// The one place in the app that decides between a file and a peer. Every
/// player and reader asks this and then stops caring.
MediaByteSource sourceForTrack(
  LibraryPlaybackTrack track, {
  required FundusOrigin origin,
  FundusStreamProxy? proxy,
}) => track.isRemote && proxy != null
    ? RemoteFileSource.fromTrack(track, proxy: proxy)
    : LocalFileSource.fromTrack(track, origin: origin);
