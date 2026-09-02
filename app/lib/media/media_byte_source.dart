import 'dart:io';

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
