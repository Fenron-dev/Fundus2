import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import '../data/media_type.dart';
import '../data/work_view.dart';
import 'peer_file_cache.dart';

const _imageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.heic',
  '.heif',
  '.avif',
  '.tif',
  '.tiff',
};

/// Looking at pictures.
///
/// A gallery is not a player and it is not a reader. There is no position to
/// resume — a photo album has no „where I was" that means anything — so this
/// keeps no progress and writes nothing back. What it does keep is which
/// picture is open, because that is what the arrow keys and the swipe move.
///
/// It reaches its files the same way everything else does: a local path, or a
/// copy fetched from a paired machine. One picture at a time, when it is
/// looked at, rather than a whole album pulled over a wireless connection.
class PhotoController extends ChangeNotifier {
  PhotoController();

  static bool isImageFile(String name) =>
      _imageExtensions.contains(p.extension(name).toLowerCase());

  /// Whether this work belongs here rather than in a player.
  static bool handles(WorkView work) =>
      work.mediaType?.progressKind == ProgressKind.none;

  /// Where remote pictures are fetched from while a paired library is open.
  PeerFileCache? cache;

  WorkView? _work;
  List<LibraryPlaybackTrack> _pictures = const [];
  final Map<String, String> _paths = {};
  final Set<String> _fetching = {};
  int? _index;
  bool _open = false;
  bool _chrome = true;
  String? _failure;

  WorkView? get work => _work;
  List<LibraryPlaybackTrack> get pictures => _pictures;
  bool get isOpen => _open;
  String? get failure => _failure;

  /// Which picture is shown full-screen, or null while the grid is up.
  int? get index => _index;
  bool get showsChrome => _chrome;

  /// The file for a picture, if it is here yet. Null means „being fetched" —
  /// the grid shows a placeholder rather than a gap.
  String? pathFor(LibraryPlaybackTrack picture) => _paths[picture.fileId];

  Future<void> open(FundusLibrary library, WorkView work) async {
    _work = work;
    _open = true;
    _index = null;
    _chrome = true;
    _failure = null;
    _paths.clear();
    _fetching.clear();

    _pictures = library
        .playbackTracks(work.id)
        .where((track) => isImageFile(track.title))
        .toList(growable: false);
    if (_pictures.isEmpty) {
      _failure = 'Zu diesem Werk sind keine Bilder erfasst.';
    }
    notifyListeners();
    // The first screenful, so the grid is not empty while it waits.
    for (final picture in _pictures.take(24)) {
      unawaited(ensure(picture));
    }
  }

  /// Makes sure a picture is on this device, fetching it if it is not.
  Future<void> ensure(LibraryPlaybackTrack picture) async {
    if (_paths.containsKey(picture.fileId)) return;
    if (!picture.isRemote) {
      _paths[picture.fileId] = picture.absolutePath;
      notifyListeners();
      return;
    }
    final cache = this.cache;
    if (cache == null || !_fetching.add(picture.fileId)) return;
    try {
      _paths[picture.fileId] = await cache.fileFor(picture);
    } on Object {
      // One picture that will not come is a gap in a grid, not a failure of
      // the album.
    } finally {
      _fetching.remove(picture.fileId);
      notifyListeners();
    }
  }

  void show(int value) {
    if (value < 0 || value >= _pictures.length) return;
    _index = value;
    _chrome = true;
    notifyListeners();
    unawaited(ensure(_pictures[value]));
    // The neighbours, so a swipe does not wait.
    for (final near in [value - 1, value + 1]) {
      if (near >= 0 && near < _pictures.length) {
        unawaited(ensure(_pictures[near]));
      }
    }
  }

  void next() => show((_index ?? -1) + 1);

  void previous() => show((_index ?? 1) - 1);

  /// Back to the grid.
  void closePicture() {
    _index = null;
    _chrome = true;
    notifyListeners();
  }

  void toggleChrome() {
    _chrome = !_chrome;
    notifyListeners();
  }

  void showChrome() {
    if (_chrome) return;
    _chrome = true;
    notifyListeners();
  }

  void close() {
    _open = false;
    _index = null;
    notifyListeners();
  }
}
