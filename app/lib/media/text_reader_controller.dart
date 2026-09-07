import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import '../app/fundus_log.dart';
import '../data/media_type.dart';
import '../data/work_view.dart';
import 'peer_file_cache.dart';

/// The file types this reader can open.
const _readableExtensions = {
  '.epub',
  '.txt',
  '.md',
  '.markdown',
  '.html',
  '.htm',
};

/// One chapter, already turned into paragraphs.
final class TextChapter {
  const TextChapter({
    required this.id,
    required this.title,
    required this.document,
  });

  final String id;
  final String title;
  final ReflowDocument document;
}

/// Where a text comes from.
///
/// The third of the source interfaces, next to `MediaByteSource` for bytes
/// and `ComicPageSource` for pages: a chapter fetched from a peer joins by
/// implementing this rather than by growing a second reader.
abstract interface class TextSource {
  String get name;

  /// The chapters, in reading order. A file without chapters answers with
  /// one, which is the honest shape of a plain text.
  Future<List<TextChapter>> chapters();
}

/// EPUB and the plain text formats, from a file on this device.
final class FileTextSource implements TextSource {
  FileTextSource(
    this.path, {
    String? name,
    this.adapter = const EpubPackageAdapter(),
  }) : _name = name;

  final String path;
  final String? _name;
  final EpubPackageAdapter adapter;

  @override
  String get name => _name ?? p.basename(path);

  /// Unpacks the book and turns it into paragraphs — away from the interface.
  ///
  /// Opening an EPUB reads every entry of a zip and runs every chapter
  /// through the reflow. That is a second or several of straight computation,
  /// and on the interface's own isolate it stops the app dead: nothing
  /// repaints, so the book that was open before stays on the screen looking
  /// like the answer. It belongs on a worker, like the comic archives already
  /// are.
  @override
  Future<List<TextChapter>> chapters() {
    final resolved = name;
    return identical(adapter, const EpubPackageAdapter())
        ? Isolate.run(() => _read(path, resolved))
        : _read(path, resolved, adapter: adapter);
  }

  static Future<List<TextChapter>> _read(
    String path,
    String name, {
    EpubPackageAdapter adapter = const EpubPackageAdapter(),
  }) async {
    final extension = p.extension(path).toLowerCase();
    if (extension == '.epub') {
      final publication = await adapter.openFile(path);
      final chapters = [
        for (final chapter in publication.chapters)
          TextChapter(
            id: chapter.id,
            title: chapter.title.trim().isEmpty
                ? 'Ohne Titel'
                : chapter.title.trim(),
            document: ReflowDocument.parse(
              chapter.html,
              format: ReflowSourceFormat.html,
            ),
          ),
      ];
      // An EPUB whose chapters are all empty is still a book; showing nothing
      // would be worse than showing a short one.
      return chapters
          .where((chapter) => chapter.document.paragraphs.isNotEmpty)
          .toList(growable: false);
    }

    final source = await File(path).readAsString();
    return [
      TextChapter(
        id: 'document',
        title: name,
        document: ReflowDocument.parse(
          source,
          format: switch (extension) {
            '.html' || '.htm' => ReflowSourceFormat.html,
            '.md' || '.markdown' => ReflowSourceFormat.markdown,
            _ => ReflowSourceFormat.plainText,
          },
        ),
      ),
    ];
  }
}

/// The reader for running text — EPUB, and the plain formats beside it.
///
/// Its unit is neither a second nor a page but a place in a chapter, which is
/// what the library shows as "Kapitel 4 · 38 %". The position it writes is the
/// one the work view already knows how to read.
class TextReaderController extends ChangeNotifier {
  TextReaderController({
    this.deviceId = 'device',
    this.deviceName = '',
    TextSource Function(String path, String name)? openSource,
  }) : _openSource =
           openSource ?? ((path, name) => FileTextSource(path, name: name));

  final TextSource Function(String path, String name) _openSource;
  final String deviceId;
  String deviceName;

  void updateDeviceName(String value) {
    final name = value.trim();
    if (name.isNotEmpty) deviceName = name;
  }

  FundusLibrary? _library;
  WorkView? _work;

  /// The readable files of the work — for a series one per volume.
  List<LibraryPlaybackTrack> _volumes = const [];
  int _volumeIndex = 0;

  List<TextChapter> _chapters = const [];
  int _chapterIndex = 0;

  /// Where in the chapter the reader is, as a fraction of its length. The
  /// paragraph is the anchor; the fraction is what survives a font change.
  int _paragraphIndex = 0;
  double _innerOffset = 0;

  /// Counts the deliberate moves — opening a book, a chapter, a bookmark.
  ///
  /// The view has to tell „somebody jumped, go there" from „somebody
  /// scrolled, stay put", and the paragraph number alone cannot say which
  /// happened. Every jump raises this; scrolling never does.
  int _jump = 0;

  ReflowReaderProfile _profile = const ReflowReaderProfile();
  List<LibraryBookmark> _bookmarks = const [];
  List<LibraryHighlight> _highlights = const [];

  bool _busy = false;
  bool _open = false;
  bool _chrome = true;
  String? _failure;

  WorkView? get work => _work;
  List<LibraryPlaybackTrack> get volumes => _volumes;
  int get volumeIndex => _volumeIndex;
  LibraryPlaybackTrack? get currentVolume =>
      _volumeIndex < _volumes.length ? _volumes[_volumeIndex] : null;

  List<TextChapter> get chapters => _chapters;
  int get chapterIndex => _chapterIndex;
  TextChapter? get currentChapter =>
      _chapterIndex < _chapters.length ? _chapters[_chapterIndex] : null;

  List<ReflowParagraph> get paragraphs =>
      currentChapter?.document.paragraphs ?? const [];

  int get paragraphIndex => _paragraphIndex;
  double get innerOffset => _innerOffset;
  int get jumpRevision => _jump;

  ReflowReaderProfile get profile => _profile;
  List<LibraryBookmark> get bookmarks => _bookmarks;
  List<LibraryHighlight> get highlights => _highlights;

  bool get isOpen => _open;
  bool get isBusy => _busy;
  bool get showsChrome => _chrome;
  String? get failure => _failure;

  /// How far through the chapter, 0 to 1.
  double get chapterFraction {
    final document = currentChapter?.document;
    if (document == null || document.paragraphs.isEmpty) return 0;
    final position = document.positionFor(
      paragraphIndex: _paragraphIndex,
      innerOffset: _innerOffset,
    );
    return position.fraction ?? 0;
  }

  /// „Kapitel 4 · 38 %", or the volume in front of it for a series.
  String get positionLabel {
    final chapter = currentChapter;
    if (chapter == null) return '';
    final percent = (chapterFraction * 100).round();
    final head = _volumes.length > 1
        ? '${currentVolume?.title ?? 'Band ${_volumeIndex + 1}'} · '
        : '';
    return '$head${chapter.title} · $percent %';
  }

  /// True for the media types this reader serves.
  static bool handles(WorkView work) =>
      work.mediaType?.progressKind == ProgressKind.chapterFraction;

  /// Whether a file of a work is a text rather than a cover or a sidecar.
  static bool isReadableFile(String path) =>
      _readableExtensions.contains(p.extension(path).toLowerCase());

  /// Where a remote volume is fetched from, by the source it belongs to.
  PeerFileCache? Function(String sourceId)? cacheForSource;

  double? _fetching;

  /// How far a remote volume has been fetched, or null when nothing is being
  /// fetched. A reader that sits blank for a minute has to say why.
  double? get fetchProgress => _fetching;

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
    // Nothing of the last book survives the opening of this one. It used to:
    // the chapters stayed until the new ones had been parsed, so for the
    // seconds that took, the reader showed the previous book — and answered
    // scrolling and page turns as if that were what had been opened.
    _clearBook();
    notifyListeners();

    try {
      _volumes = library
          .playbackTracks(work.id)
          // By the file's own name: a mirrored file has no path on this
          // device, but it is still called what it is called.
          .where((track) => isReadableFile(track.title))
          .toList(growable: false);
      if (_volumes.isEmpty) {
        _failure = 'Zu diesem Werk ist kein lesbarer Text erfasst.';
        _busy = false;
        notifyListeners();
        return;
      }

      _profile = await library.loadTextProfile(workId: work.id);
      final annotations = library.loadAnnotations(work.id);
      _bookmarks = annotations.bookmarks;
      _highlights = annotations.highlights;

      final saved = library.loadProgress(work.id)?.position;
      final savedVolume = saved?.fileId == null
          ? 0
          : _volumes.indexWhere((volume) => volume.fileId == saved!.fileId);
      _volumeIndex = savedVolume < 0 ? 0 : savedVolume;
      await _openVolume(_volumeIndex, at: saved);
    } on Object catch (error) {
      _failure = error.toString();
      _busy = false;
      notifyListeners();
    }
  }

  /// Everything that belongs to one book and nothing else.
  void _clearBook() {
    _chapters = const [];
    _chapterIndex = 0;
    _paragraphIndex = 0;
    _innerOffset = 0;
    _bookmarks = const [];
    _highlights = const [];
    _volumes = const [];
    _volumeIndex = 0;
  }

  Future<void> _openVolume(int index, {MediaPosition? at}) async {
    _busy = true;
    _failure = null;
    _chapters = const [];
    notifyListeners();
    final span = FundusLog.instance.start('text.volume', {
      'volume': _volumes[index].title,
    });
    try {
      final volume = _volumes[index];
      final path = await _pathFor(volume);
      span.step('fetched');
      final source = _openSource(path, volume.title);
      _chapters = await source.chapters();
      span.step('parsed', {'chapters': _chapters.length});
      _volumeIndex = index;
      if (_chapters.isEmpty) {
        _failure = 'In „${volume.title}“ ist kein lesbarer Text enthalten.';
        _busy = false;
        notifyListeners();
        return;
      }
      final savedChapter = at?.chapterId == null
          ? 0
          : _chapters.indexWhere((chapter) => chapter.id == at!.chapterId);
      _chapterIndex = savedChapter < 0 ? 0 : savedChapter;
      final resolved = _chapters[_chapterIndex].document.resolve(
        savedChapter < 0 ? null : at,
      );
      _paragraphIndex = resolved.paragraphIndex;
      _innerOffset = resolved.innerOffset;
      _jump++;
      span.done();
    } on Object catch (error) {
      span.failed(error);
      _failure = error.toString();
      _chapters = const [];
    }
    _busy = false;
    notifyListeners();
  }

  /// Reports where reading has got to.
  ///
  /// This is called once per scrolled frame, and every listener of this
  /// controller — which is the whole interface, through the scope — used to
  /// be woken by it. Sixty rebuilds a second of the reader, the shell and the
  /// navigation is what made scrolling a book stutter.
  ///
  /// The position itself is kept on every call, because the save and the
  /// resume need it exactly. Listeners are only told when what they *show*
  /// changes: the paragraph and the rounded percentage, which move a couple
  /// of times a second rather than sixty.
  void reportPosition(int paragraphIndex, double innerOffset) {
    final clamped = paragraphs.isEmpty
        ? 0
        : paragraphIndex.clamp(0, paragraphs.length - 1);
    if (clamped == _paragraphIndex &&
        (innerOffset - _innerOffset).abs() < .01) {
      return;
    }
    final shown = positionLabel;
    _paragraphIndex = clamped;
    _innerOffset = innerOffset.clamp(0, 1);
    if (positionLabel != shown) notifyListeners();
    _scheduleSave();
  }

  Timer? _saveTimer;

  void _scheduleSave() {
    if (_saveTimer?.isActive ?? false) return;
    final interval =
        _work?.mediaType?.progressKind.saveInterval ??
        const Duration(minutes: 2);
    _saveTimer = Timer(interval, saveProgress);
  }

  Future<void> goToChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    saveProgress();
    _chapterIndex = index;
    _paragraphIndex = 0;
    _innerOffset = 0;
    _jump++;
    notifyListeners();
    saveProgress();
  }

  Future<void> nextChapter() async {
    if (_chapterIndex + 1 < _chapters.length) {
      return goToChapter(_chapterIndex + 1);
    }
    if (_volumeIndex + 1 < _volumes.length) {
      await _openVolume(_volumeIndex + 1);
      saveProgress();
      return;
    }
    saveProgress(finished: true);
  }

  Future<void> previousChapter() async {
    if (_chapterIndex > 0) return goToChapter(_chapterIndex - 1);
    if (_volumeIndex == 0) return;
    await _openVolume(_volumeIndex - 1);
    saveProgress();
  }

  Future<void> openVolume(int index) async {
    if (index < 0 || index >= _volumes.length || index == _volumeIndex) return;
    saveProgress();
    await _openVolume(index);
    saveProgress();
  }

  Future<void> updateProfile(ReflowReaderProfile value) async {
    _profile = value;
    notifyListeners();
    final library = _library;
    final work = _work;
    if (library == null || work == null || library.isReadOnly) return;
    try {
      await library.saveTextProfile(value, workId: work.id);
    } on Object {
      // The setting still holds for this session.
    }
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

  Future<void> addBookmark({String? note}) async {
    final library = _library;
    final work = _work;
    final volume = currentVolume;
    if (library == null || work == null || volume == null) return;
    if (library.isReadOnly || _chapters.isEmpty) return;
    try {
      final annotations = await library.addMediaBookmark(
        workId: work.id,
        fileId: volume.fileId,
        position: _position(),
        label: positionLabel,
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

  Future<void> goToBookmark(LibraryBookmark bookmark) async {
    final volume = _volumes.indexWhere(
      (candidate) => candidate.fileId == bookmark.fileId,
    );
    if (volume >= 0 && volume != _volumeIndex) {
      await _openVolume(volume, at: bookmark.mediaPosition);
      return;
    }
    final chapter = _chapters.indexWhere(
      (candidate) => candidate.id == bookmark.mediaPosition.chapterId,
    );
    if (chapter >= 0) _chapterIndex = chapter;
    final resolved = _chapters.isEmpty
        ? (paragraphIndex: 0, innerOffset: 0.0)
        : _chapters[_chapterIndex].document.resolve(bookmark.mediaPosition);
    _paragraphIndex = resolved.paragraphIndex;
    _innerOffset = resolved.innerOffset;
    _jump++;
    notifyListeners();
    saveProgress();
  }

  /// Marks a stretch of text.
  ///
  /// The anchor is the paragraph and the words themselves, never a pixel:
  /// changing the type size or the measure re-lays the whole chapter, and a
  /// mark that lived on the old layout would land somewhere else.
  Future<void> addHighlight({
    required int paragraphIndex,
    required int start,
    required int end,
    String color = '#FFF176',
    String? note,
  }) async {
    final library = _library;
    final work = _work;
    final chapter = currentChapter;
    final volume = currentVolume;
    if (library == null || work == null || chapter == null) return;
    if (volume == null || library.isReadOnly) return;
    final list = chapter.document.paragraphs;
    if (paragraphIndex < 0 || paragraphIndex >= list.length) return;
    final paragraph = list[paragraphIndex];
    final from = start.clamp(0, paragraph.text.length);
    final to = end.clamp(from, paragraph.text.length);
    if (to <= from) return;

    try {
      final annotations = await library.addTextHighlight(
        workId: work.id,
        fileId: volume.fileId,
        position: chapter.document.positionFor(
          paragraphIndex: paragraphIndex,
          innerOffset: paragraph.text.isEmpty
              ? 0
              : from / paragraph.text.length,
          fileId: volume.fileId,
          chapterId: chapter.id,
        ),
        quote: paragraph.text.substring(from, to),
        color: color,
        note: note,
      );
      _highlights = annotations.highlights;
      notifyListeners();
    } on Object catch (error) {
      _failure = error.toString();
      notifyListeners();
    }
  }

  Future<void> deleteHighlight(String highlightId) async {
    final library = _library;
    final work = _work;
    if (library == null || work == null || library.isReadOnly) return;
    try {
      final annotations = await library.deleteHighlight(work.id, highlightId);
      _highlights = annotations.highlights;
      notifyListeners();
    } on Object {
      // Nothing was removed; the list still shows the truth.
    }
  }

  /// The marks that fall inside one paragraph, as character ranges.
  ///
  /// The stored offset says roughly where the mark sat; the quote says what
  /// it covered. Searching for the quote near that offset finds it again
  /// however the text is set now, and finds nothing if the words are gone.
  List<({LibraryHighlight highlight, int start, int end})>
  highlightsInParagraph(int index) {
    final chapter = currentChapter;
    if (chapter == null) return const [];
    final list = chapter.document.paragraphs;
    if (index < 0 || index >= list.length) return const [];
    final paragraph = list[index];

    final found = <({LibraryHighlight highlight, int start, int end})>[];
    for (final highlight in _highlights) {
      final position = highlight.mediaPosition;
      if (position.chapterId != null && position.chapterId != chapter.id) {
        continue;
      }
      if (position.elementId != null && position.elementId != paragraph.id) {
        continue;
      }
      final start = _locateQuote(
        paragraph.text,
        highlight.quote,
        ((position.scrollOffset ?? 0) * paragraph.text.length).round(),
      );
      if (start < 0) continue;
      found.add((
        highlight: highlight,
        start: start,
        end: start + highlight.quote.length,
      ));
    }
    found.sort((left, right) => left.start.compareTo(right.start));
    return found;
  }

  /// The occurrence of [quote] closest to [near], or -1 when it is gone.
  static int _locateQuote(String text, String quote, int near) {
    if (quote.isEmpty || quote.length > text.length) return -1;
    var best = -1;
    var bestDistance = 1 << 30;
    var from = 0;
    while (true) {
      final index = text.indexOf(quote, from);
      if (index < 0) break;
      final distance = (index - near).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = index;
      }
      from = index + 1;
    }
    return best;
  }

  MediaPosition _position() {
    final chapter = currentChapter;
    if (chapter == null) {
      return MediaPosition(
        kind: MediaPositionKind.epubCfi,
        numericValue: 0,
        fileId: currentVolume?.fileId,
        label: 'Anfang',
      );
    }
    final position = chapter.document.positionFor(
      paragraphIndex: _paragraphIndex,
      innerOffset: _innerOffset,
      fileId: currentVolume?.fileId,
      chapterId: chapter.id,
    );
    // The label is what the library shows in the work list, so it carries the
    // chapter's name rather than a bare percentage.
    return MediaPosition(
      kind: position.kind,
      numericValue: position.numericValue,
      total: position.total,
      fileId: position.fileId,
      chapterId: position.chapterId,
      elementId: position.elementId,
      scrollOffset: position.scrollOffset,
      label: chapter.title,
    );
  }

  void saveProgress({bool finished = false, bool checkpoint = false}) {
    final library = _library;
    final work = _work;
    final volume = currentVolume;
    if (library == null || work == null || volume == null) return;
    if (library.isReadOnly || _chapters.isEmpty) return;
    try {
      library.saveMediaProgress(
        workId: work.id,
        fileId: volume.fileId,
        position: _position(),
        finished: finished,
        deviceId: deviceId,
        deviceName: deviceName,
        checkpoint: checkpoint,
      );
    } on Object {
      // Losing one autosave is not worth interrupting reading for.
    }
  }

  void close() {
    saveProgress(checkpoint: true);
    _saveTimer?.cancel();
    _open = false;
    notifyListeners();
  }

  @override
  void dispose() {
    saveProgress(checkpoint: true);
    _saveTimer?.cancel();
    super.dispose();
  }
}
