import '../app/fundus_log.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import '../data/media_type.dart';
import '../data/work_view.dart';
import 'comic_archive.dart';
import 'comic_layout.dart';
import 'pdf_source.dart';
import 'peer_file_cache.dart';

/// The file types this reader can open.
///
/// A work carries more than its chapters — covers, a ComicInfo, sometimes a
/// banner. Those are files of the work, not volumes of it, and putting them
/// in the chapter list is how a reader ends up "opening" a cover.
const _readableExtensions = {'.cbz', '.zip', '.pdf'};

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
    this.deviceName = '',
    ComicPageSource Function(String path, String name)? openSource,
  }) : _openSource = openSource ?? _sourceFor;

  /// A comic comes out of an archive, a document out of a PDF — the reader
  /// above them does not care which.
  static ComicPageSource _sourceFor(String path, String name) =>
      p.extension(path).toLowerCase() == '.pdf'
      ? PdfComicPageSource(path, name: name)
      : ArchiveComicPageSource(path, name: name);

  /// How the archive is opened. Injectable so the reader's rules can be
  /// tested without building a real CBZ for every case.
  final ComicPageSource Function(String path, String name) _openSource;
  final String deviceId;
  String deviceName;

  void updateDeviceName(String value) {
    final name = value.trim();
    if (name.isNotEmpty) deviceName = name;
  }

  FundusLibrary? _library;
  WorkView? _work;

  /// The readable files of the work — for a manga one entry per volume.
  List<LibraryPlaybackTrack> _volumes = const [];
  int _volumeIndex = 0;

  ComicPageSource? _source;
  List<ComicPage> _pages = const [];
  int _pageIndex = 0;

  /// Page id → file on disk. Only what has been shown is unpacked.
  final Map<String, String> _files = {};

  /// Pages whose unpacking is under way, so a scroll does not ask twice.
  final Set<String> _pending = {};

  PublicationReaderProfile _profile = const PublicationReaderProfile();
  List<LibraryBookmark> _bookmarks = const [];

  bool _busy = false;
  bool _turnInProgress = false;
  bool _open = false;
  bool _chrome = true;
  String? _failure;

  WorkView? get work => _work;
  List<LibraryPlaybackTrack> get volumes => _volumes;
  int get volumeIndex => _volumeIndex;
  LibraryPlaybackTrack? get currentVolume =>
      _volumeIndex < _volumes.length ? _volumes[_volumeIndex] : null;

  List<ComicPage> get pages => _pages;
  int get pageIndex => _pageIndex;
  int get pageCount => _pages.length;

  PublicationReaderProfile get profile => _profile;
  List<LibraryBookmark> get bookmarks => _bookmarks;

  /// Whether the reader covers the shell.
  bool get isOpen => _open;
  bool get isBusy => _busy;
  String? get failure => _failure;

  /// Whether the surrounding chrome is shown. Reading is the point; the bar
  /// steps out of the way on a tap and comes back the same way.
  bool get showsChrome => _chrome;

  bool get isContinuous => isContinuousLayout(_profile.layout);
  bool get isRightToLeft =>
      _profile.readingDirection == PublicationReadingDirection.rightToLeft;

  /// How pages sit together — one per group, or two on a spread.
  List<List<int>> get pageGroups => comicPageGroups(
    _pages.length,
    layout: _profile.layout,
    firstPageIsCover: _profile.firstPageIsCover,
  );

  int get groupIndex => comicPageGroupIndex(pageGroups, _pageIndex);

  /// The file for a page, or null while it is still unpacking.
  String? fileForPage(int index) =>
      index >= 0 && index < _pages.length ? _files[_pages[index].id] : null;

  String? get currentPageFile => fileForPage(_pageIndex);

  /// How tall a page is relative to its width, once something has measured
  /// it.
  ///
  /// A webtoon page is a strip — sometimes five times as tall as it is wide.
  /// A placeholder of the wrong shape means the strip changes length the
  /// moment the picture arrives, and everything below it moves under the
  /// reader's thumb. So each page's real proportions are kept as they become
  /// known, and a page nobody has seen yet borrows the shape of the ones that
  /// have: within one chapter they are almost always the same.
  final Map<int, double> _aspects = {};
  double? _typicalAspect;

  double? aspectOf(int index) => _aspects[index] ?? _typicalAspect;

  void rememberAspect(int index, double aspect) {
    if (!aspect.isFinite || aspect <= 0) return;
    if (_aspects[index] == aspect) return;
    _aspects[index] = aspect;
    // The first measured page sets the expectation for the rest; later ones
    // only correct it when they are wildly different, so one banner page
    // cannot make every other placeholder wrong.
    final typical = _typicalAspect;
    if (typical == null || (aspect / typical - 1).abs() > 0.5) {
      _typicalAspect = aspect;
    }
  }

  void _forgetAspects() {
    _aspects.clear();
    _typicalAspect = null;
  }

  /// „Band 2 · Seiten 6–7 von 180" — the label the design asks for.
  String get positionLabel {
    if (_pages.isEmpty) return '';
    final page = comicPageLabel(pageGroups, _pageIndex, _pages.length);
    if (_volumes.length <= 1) return page;
    return '${currentVolume?.title ?? 'Band ${_volumeIndex + 1}'} · $page';
  }

  /// What the chapter list says about its own completeness — a gap in the
  /// numbering is worth naming rather than leaving the story to jump.
  ComicChapterSequence get chapterSequence =>
      comicChapterSequence([for (final volume in _volumes) volume.title]);

  /// The page a bookmark points at, if it belongs to the volume open now.
  ///
  /// A list of „Seite 143" tells nobody anything; the page itself does. Only
  /// the volume in hand can be shown — unpacking every other volume to draw
  /// a list of marks would cost more than the list is worth.
  String? previewForBookmark(LibraryBookmark bookmark) {
    if (bookmark.fileId != currentVolume?.fileId) return null;
    final page = (bookmark.mediaPosition.numericValue ?? 1).round() - 1;
    return fileForPage(page);
  }

  /// Asks for the pages the bookmarks of this volume sit on, so the list can
  /// show them. Does nothing for marks in other volumes.
  void requestBookmarkPreviews() {
    for (final bookmark in _bookmarks) {
      if (bookmark.fileId != currentVolume?.fileId) continue;
      requestPage((bookmark.mediaPosition.numericValue ?? 1).round() - 1);
    }
  }

  /// The bytes of the page on screen, for saving it out. Null while the page
  /// is still unpacking or if it went missing underneath us.
  Future<Uint8List?> capturePage() async {
    final file = currentPageFile;
    if (file == null) return null;
    try {
      return await File(file).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// A file name for a saved page that says where it came from.
  String captureName() {
    final title = _work?.title ?? 'Fundus';
    final volume = currentVolume?.title ?? '';
    final page = (_pageIndex + 1).toString().padLeft(3, '0');
    final extension = _pageIndex < _pages.length
        ? p.extension(_pages[_pageIndex].name)
        : '.jpg';
    return '${_sanitise(title)}_${_sanitise(volume)}_$page'
        '${extension.isEmpty ? '.jpg' : extension}';
  }

  static String _sanitise(String value) => value
      .replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  /// True for the media types this reader serves.
  ///
  /// A comic counts pages in a volume, a document counts pages in a file —
  /// different units of progress, the same act of turning a page.
  static bool handles(WorkView work) => switch (work.mediaType?.progressKind) {
    ProgressKind.pagePerVolume || ProgressKind.documentPage => true,
    _ => false,
  };

  /// Whether a file of a work is a volume rather than a cover or a sidecar.
  static bool isReadableFile(String path) =>
      _readableExtensions.contains(p.extension(path).toLowerCase());

  /// Opens a work at its stored page.
  /// Where a remote volume is fetched from, by the source it belongs to.
  PeerFileCache? Function(String sourceId)? cacheForSource;

  /// How a comic on another machine is opened page by page. Null for a work
  /// on this disk, and for a machine that is not answering.
  ComicPageSource? Function(LibraryPlaybackTrack volume)? remotePages;

  double? _fetching;

  /// How far a remote volume has been fetched, or null when nothing is being
  /// fetched. A reader that sits blank for a minute has to say why.
  double? get fetchProgress => _fetching;

  /// Opens a volume, wherever it happens to live.
  ///
  /// A comic on another machine is fetched page by page — the server lists
  /// and serves a volume's pages, so the first page arrives in the time one
  /// page takes rather than after the whole archive. A PDF still comes over
  /// whole: pdfium seeks all through a document, and there is no page-wise
  /// answer for it.
  Future<ComicPageSource> _openVolumeSource(LibraryPlaybackTrack volume) async {
    if (volume.isRemote && p.extension(volume.title).toLowerCase() != '.pdf') {
      final pages = remotePages?.call(volume);
      if (pages != null) return pages;
    }
    return _openSource(await _pathFor(volume), volume.title);
  }

  /// Where the bytes are on this device.
  ///
  /// A reader needs a file — an archive's index sits at its end, an EPUB is a
  /// zip of many entries — so a volume from a paired Fundus is fetched once
  /// and kept. [cache] is set while such a library is open and null
  /// otherwise, which is the difference between "fetch it" and "there is
  /// nothing to fetch it from".
  Future<String> _pathFor(LibraryPlaybackTrack volume) async {
    if (!volume.isRemote) return volume.absolutePath;
    final cache = cacheForSource?.call(volume.sourceId);
    if (cache == null) {
      throw StateError(
        'Diese Datei liegt auf „${volume.sourceId.replaceFirst('peer-', '')}" '
        '— zu diesem Gerät besteht gerade keine Verbindung.',
      );
    }
    _fetching = 0;
    notifyListeners();
    try {
      return await cache.fileFor(
        volume,
        onProgress: (fraction) {
          _fetching = fraction;
          notifyListeners();
        },
      );
    } finally {
      _fetching = null;
      notifyListeners();
    }
  }

  Future<void> open(FundusLibrary library, WorkView work) async {
    _failure = null;
    _library = library;
    _work = work;
    _open = true;
    _chrome = true;
    _busy = true;
    // The last volume's pages are not this one's. Left standing they are what
    // the reader shows — and answers page turns from — until the new archive
    // has been opened.
    _pages = const [];
    _pageIndex = 0;
    _volumes = const [];
    _volumeIndex = 0;
    _bookmarks = const [];
    notifyListeners();

    try {
      _volumes = library
          .playbackTracks(work.id)
          // By the file's own name: a mirrored file has no path on this
          // device, but it is still called what it is called.
          .where((track) => isReadableFile(track.title))
          .toList(growable: false);
      if (_volumes.isEmpty) {
        _failure =
            'Zu diesem Werk ist keine lesbare Datei erfasst — erwartet '
            'werden CBZ, ZIP oder PDF.';
        _busy = false;
        notifyListeners();
        return;
      }

      _profile = await library.loadReaderProfile(workId: work.id);
      _bookmarks = library.loadAnnotations(work.id).bookmarks;

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
    _pages = const [];
    // Ein neuer Band hat eigene Maße; die des vorigen wären hier geraten.
    _forgetAspects();
    notifyListeners();
    final span = FundusLog.instance.start('reader.volume', {
      'volume': index < _volumes.length ? _volumes[index].title : '?',
    });
    try {
      await _source?.dispose();
      _files.clear();
      _pending.clear();
      final volume = _volumes[index];
      _source = await _openVolumeSource(volume);
      _pages = await _source!.pages();
      span.done({'pages': _pages.length});
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

  /// Unpacks the pages around [index], so a page turn does not wait for the
  /// archive. How far ahead is the reader's own setting.
  Future<void> _ensurePagesAround(int index) async {
    final source = _source;
    if (source == null) return;
    final reach = _profile.preloadCount;
    final wanted = <ComicPage>[];
    for (var offset = 0; offset <= reach; offset++) {
      for (final candidate in {index + offset, index - offset}) {
        if (candidate < 0 || candidate >= _pages.length) continue;
        final page = _pages[candidate];
        if (_files.containsKey(page.id) || _pending.contains(page.id)) continue;
        wanted.add(page);
      }
    }
    if (wanted.isEmpty) return;
    _pending.addAll(wanted.map((page) => page.id));
    try {
      _files.addAll(await source.materialize(wanted));
    } on Object catch (error) {
      _failure = error.toString();
    } finally {
      _pending.removeAll(wanted.map((page) => page.id));
    }
    notifyListeners();
  }

  /// Asks for a page that scrolled into view. Continuous layouts reach far
  /// beyond the preload window, so they say what they need.
  void requestPage(int index) {
    if (index < 0 || index >= _pages.length) return;
    final page = _pages[index];
    if (_files.containsKey(page.id) || _pending.contains(page.id)) return;
    unawaited(_ensurePagesAround(index));
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

  /// Forward by one unit — a page, or a whole spread in double-page layout.
  Future<void> nextPage() async {
    if (_turnInProgress) return;
    _turnInProgress = true;
    try {
      await _nextPage();
    } finally {
      _turnInProgress = false;
    }
  }

  Future<void> _nextPage() async {
    final groups = pageGroups;
    if (groups.isEmpty) return goToPage(_pageIndex + 1);
    final unit = comicPageGroupIndex(groups, _pageIndex);
    if (unit + 1 >= groups.length) return goToPage(_pages.length);
    return goToPage(groups[unit + 1].first);
  }

  Future<void> previousPage() async {
    if (_turnInProgress) return;
    _turnInProgress = true;
    try {
      await _previousPage();
    } finally {
      _turnInProgress = false;
    }
  }

  Future<void> _previousPage() async {
    final groups = pageGroups;
    if (groups.isEmpty) return goToPage(_pageIndex - 1);
    final unit = comicPageGroupIndex(groups, _pageIndex);
    if (unit == 0) return goToPage(-1);
    return goToPage(groups[unit - 1].first);
  }

  Future<void> openVolume(int index) async {
    if (index < 0 || index >= _volumes.length || index == _volumeIndex) return;
    await _openVolume(index);
    saveProgress();
  }

  /// Changes how the work is read and remembers it in the vault.
  Future<void> updateProfile(PublicationReaderProfile value) async {
    _profile = value;
    notifyListeners();
    final library = _library;
    final work = _work;
    if (library == null || work == null || library.isReadOnly) return;
    try {
      await library.saveReaderProfile(value, workId: work.id);
    } on Object {
      // A setting that could not be written is still in force for this
      // session; it is not worth interrupting reading for.
    }
    await _ensurePagesAround(_pageIndex);
  }

  void toggleChrome() {
    _chrome = !_chrome;
    notifyListeners();
  }

  /// Wie weit hineingezoomt ist, und ob überhaupt.
  ///
  /// Der Leser selbst zoomt nicht — das tut die Ansicht. Er weiß es aber,
  /// weil die Tippflächen es wissen müssen: wer eine vergrößerte Seite mit
  /// dem Finger verschiebt, blättert nicht um.
  double _zoom = 1;
  bool get isZoomed => _zoom > 1.01;

  void reportZoom(double value) {
    final was = isZoomed;
    _zoom = value;
    if (was != isZoomed) notifyListeners();
  }

  /// Ein Doppeltipp, der die Ansicht heran- und wieder wegholt.
  ///
  /// Die Geste kommt von den Tippflächen, die über der Seite liegen; gezoomt
  /// wird eine Ebene tiefer. Der Zähler ist die Nachricht dazwischen — er
  /// steigt, und die Ansicht sieht daran, dass sie gemeint ist.
  int _zoomRequest = 0;
  int get zoomRequest => _zoomRequest;

  void toggleZoom() {
    _zoomRequest++;
    notifyListeners();
  }

  void showChrome() {
    if (_chrome) return;
    _chrome = true;
    notifyListeners();
  }

  /// Marks the page currently shown.
  Future<void> addBookmark({String? note}) async {
    final library = _library;
    final work = _work;
    final volume = currentVolume;
    if (library == null || work == null || volume == null) return;
    if (library.isReadOnly || _pages.isEmpty) return;
    try {
      final annotations = await library.addMediaBookmark(
        workId: work.id,
        fileId: volume.fileId,
        position: _positionOfCurrentPage(),
        label: comicPageLabel(pageGroups, _pageIndex, _pages.length),
        note: note,
      );
      _bookmarks = annotations.bookmarks;
      notifyListeners();
    } on Object catch (error) {
      _failure = error.toString();
      notifyListeners();
    }
  }

  Future<void> deleteBookmark(String bookmarkId) async {
    final library = _library;
    final work = _work;
    if (library == null || work == null || library.isReadOnly) return;
    try {
      final annotations = await library.deleteBookmark(work.id, bookmarkId);
      _bookmarks = annotations.bookmarks;
      notifyListeners();
    } on Object {
      // Nothing was removed; the list still shows the truth.
    }
  }

  /// Jumps to a mark — into another volume if that is where it sits.
  Future<void> goToBookmark(LibraryBookmark bookmark) async {
    final page = (bookmark.mediaPosition.numericValue ?? 1).round() - 1;
    final volume = _volumes.indexWhere(
      (candidate) => candidate.fileId == bookmark.fileId,
    );
    if (volume >= 0 && volume != _volumeIndex) {
      await _openVolume(volume, page: page < 0 ? 0 : page);
      saveProgress();
      return;
    }
    await goToPage(page < 0 ? 0 : page);
  }

  MediaPosition _positionOfCurrentPage() => MediaPosition(
    kind: MediaPositionKind.page,
    numericValue: (_pageIndex + 1).toDouble(),
    total: _pages.length.toDouble(),
    fileId: currentVolume?.fileId,
  );

  /// Writes the page back. A page and a title are two different kinds of
  /// truth; metadata is never touched here.
  void saveProgress({bool finished = false, bool checkpoint = false}) {
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
        position: _positionOfCurrentPage(),
        finished: finished,
        deviceId: deviceId,
        deviceName: deviceName,
        checkpoint: checkpoint,
      );
    } on Object {
      // Losing one autosave is not worth interrupting reading for; the next
      // page turn writes again.
    }
  }

  /// Leaves the reader, keeping the work so the shell can show where it was.
  void close() {
    saveProgress(checkpoint: true);
    _open = false;
    notifyListeners();
  }

  @override
  void dispose() {
    saveProgress(checkpoint: true);
    unawaited(_source?.dispose());
    super.dispose();
  }
}
