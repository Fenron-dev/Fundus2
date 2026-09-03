import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fundus_core/fundus_core.dart';

import '../data/media_type.dart';
import '../data/work_view.dart';
import 'comic_archive.dart';

/// The one reader for paged works.
///
/// It is the sibling of `PlaybackController`, not a copy of it: the rules it
/// holds are its own — a page inside a volume rather than a second inside a
/// file — but the shape is the same. It is handed a [ComicPageSource] and
/// never asks where the pages come from, so a chapter streamed from a peer
/// joins later without a second reader.
class ReaderController extends ChangeNotifier {
  ReaderController({
    this.deviceId = 'device',
    ComicPageSource Function(String path, String name)? openSource,
  }) : _openSource =
           openSource ??
           ((path, name) => ArchiveComicPageSource(path, name: name));

  /// How the archive is opened. Injectable so the reader's rules can be
  /// tested without building a real CBZ for every case.
  final ComicPageSource Function(String path, String name) _openSource;
  final String deviceId;

  /// A page is written back at the turn, not on a timer: turning a page is
  /// the event, and there is nothing between two pages worth saving.
  FundusLibrary? _library;
  WorkView? _work;

  /// The files of the work — for a manga one entry per volume.
  List<LibraryPlaybackTrack> _volumes = const [];
  int _volumeIndex = 0;

  ComicPageSource? _source;
  List<ComicPage> _pages = const [];
  int _pageIndex = 0;

  /// Page id → file on disk. Only what has been shown is unpacked.
  final Map<String, String> _files = {};

  bool _busy = false;
  bool _open = false;
  String? _failure;

  WorkView? get work => _work;
  List<LibraryPlaybackTrack> get volumes => _volumes;
  int get volumeIndex => _volumeIndex;
  LibraryPlaybackTrack? get currentVolume =>
      _volumeIndex < _volumes.length ? _volumes[_volumeIndex] : null;

  List<ComicPage> get pages => _pages;
  int get pageIndex => _pageIndex;
  int get pageCount => _pages.length;

  /// Whether the reader covers the shell.
  bool get isOpen => _open;
  bool get isBusy => _busy;
  String? get failure => _failure;

  /// The file for the page currently shown, or null while it is unpacking.
  String? get currentPageFile =>
      _pageIndex < _pages.length ? _files[_pages[_pageIndex].id] : null;

  /// „Band 2 · Seite 7 von 180" — the label the design asks for.
  String get positionLabel {
    if (_pages.isEmpty) return '';
    final page = 'Seite ${_pageIndex + 1} von ${_pages.length}';
    if (_volumes.length <= 1) return page;
    return '${currentVolume?.title ?? 'Band ${_volumeIndex + 1}'} · $page';
  }

  /// True for the media types this reader serves.
  static bool handles(WorkView work) =>
      work.mediaType?.progressKind == ProgressKind.pagePerVolume;

  /// Opens a work at its stored page.
  Future<void> open(FundusLibrary library, WorkView work) async {
    _failure = null;
    _library = library;
    _work = work;
    _open = true;
    _busy = true;
    notifyListeners();

    try {
      _volumes = library.playbackTracks(work.id);
      if (_volumes.isEmpty) {
        _failure = 'Zu diesem Werk sind keine lesbaren Dateien erfasst.';
        _busy = false;
        notifyListeners();
        return;
      }

      final saved = library.loadProgress(work.id)?.position;
      final savedVolume = saved?.fileId == null
          ? 0
          : _volumes.indexWhere((volume) => volume.fileId == saved!.fileId);
      _volumeIndex = savedVolume < 0 ? 0 : savedVolume;
      // The stored page is one-based, as it is shown; the index is not.
      final savedPage = (saved?.numericValue ?? 1).round() - 1;
      await _openVolume(_volumeIndex, page: savedPage < 0 ? 0 : savedPage);
    } on Object catch (error) {
      _failure = error.toString();
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _openVolume(int index, {int page = 0}) async {
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      await _source?.dispose();
      _files.clear();
      final volume = _volumes[index];
      _source = _openSource(volume.absolutePath, volume.title);
      _pages = await _source!.pages();
      _volumeIndex = index;
      if (_pages.isEmpty) {
        _failure = 'In „${volume.title}“ sind keine Seiten enthalten.';
        _busy = false;
        notifyListeners();
        return;
      }
      _pageIndex = page.clamp(0, _pages.length - 1);
      await _ensurePagesAround(_pageIndex);
    } on Object catch (error) {
      _failure = error.toString();
      _pages = const [];
    }
    _busy = false;
    notifyListeners();
  }

  /// Unpacks the page shown and its neighbour, so a page turn does not wait
  /// for the archive.
  Future<void> _ensurePagesAround(int index) async {
    final source = _source;
    if (source == null) return;
    final wanted = [
      for (final offset in [0, 1, -1])
        if (index + offset >= 0 && index + offset < _pages.length)
          _pages[index + offset],
    ].where((page) => !_files.containsKey(page.id)).toList(growable: false);
    if (wanted.isEmpty) return;
    final files = await source.materialize(wanted);
    _files.addAll(files);
  }

  Future<void> goToPage(int index) async {
    if (_pages.isEmpty) return;
    if (index < 0) {
      // Before the first page: the previous volume, at its end.
      if (_volumeIndex == 0) return;
      await _openVolume(_volumeIndex - 1, page: 1 << 30);
      saveProgress();
      return;
    }
    if (index >= _pages.length) {
      if (_volumeIndex + 1 >= _volumes.length) {
        saveProgress(finished: true);
        return;
      }
      await _openVolume(_volumeIndex + 1);
      saveProgress();
      return;
    }
    _pageIndex = index;
    notifyListeners();
    await _ensurePagesAround(index);
    saveProgress();
    notifyListeners();
  }

  Future<void> nextPage() => goToPage(_pageIndex + 1);
  Future<void> previousPage() => goToPage(_pageIndex - 1);

  Future<void> openVolume(int index) async {
    if (index < 0 || index >= _volumes.length || index == _volumeIndex) return;
    await _openVolume(index);
    saveProgress();
  }

  /// Writes the page back. A page and a title are two different kinds of
  /// truth; metadata is never touched here.
  void saveProgress({bool finished = false}) {
    final library = _library;
    final work = _work;
    final volume = currentVolume;
    if (library == null || work == null || volume == null) return;
    if (library.isReadOnly) return;
    if (_pages.isEmpty) return;
    try {
      library.saveMediaProgress(
        workId: work.id,
        fileId: volume.fileId,
        position: MediaPosition(
          kind: MediaPositionKind.page,
          numericValue: (_pageIndex + 1).toDouble(),
          total: _pages.length.toDouble(),
          fileId: volume.fileId,
        ),
        finished: finished,
        deviceId: deviceId,
      );
    } on Object {
      // Losing one autosave is not worth interrupting reading for; the next
      // page turn writes again.
    }
  }

  /// Leaves the reader, keeping the work so the shell can show where it was.
  void close() {
    saveProgress();
    _open = false;
    notifyListeners();
  }

  @override
  void dispose() {
    saveProgress();
    unawaited(_source?.dispose());
    super.dispose();
  }
}
