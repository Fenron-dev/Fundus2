import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'comic_archive.dart';

/// A PDF, read as what it is: a sequence of pages.
///
/// No second reader for documents. A page is a page, so a PDF joins through
/// the same [ComicPageSource] the comics use and inherits the whole reader —
/// double pages, the overview, bookmarks with previews, fullscreen. Only the
/// unit of progress differs, and the library already knows that: a document
/// records the page it was left on and no percentage.
final class PdfComicPageSource implements ComicPageSource {
  PdfComicPageSource(this.path, {String? name, this.targetWidth = 1600})
    : _name = name;

  /// How wide a page is rendered. A PDF has no pixels of its own, so this is
  /// a choice: wide enough to read and to zoom into a little, not so wide
  /// that a four-hundred-page rulebook fills the disk.
  final int targetWidth;

  final String path;
  final String? _name;

  PdfDocument? _document;
  Directory? _directory;

  @override
  String get name => _name ?? p.basename(path);

  Future<PdfDocument> _open() async {
    final existing = _document;
    if (existing != null) return existing;
    if (!await File(path).exists()) {
      throw const ComicArchiveException('Die Datei ist nicht mehr vorhanden.');
    }
    try {
      // Safe to call more than once; it is what a widget-first app would have
      // done at startup, and this source may be the first thing to touch it.
      pdfrxFlutterInitialize();
      return _document = await PdfDocument.openFile(path);
    } on ComicArchiveException {
      rethrow;
    } on Object catch (error) {
      throw ComicArchiveException('Das PDF lässt sich nicht öffnen: $error');
    }
  }

  @override
  Future<List<ComicPage>> pages() async {
    final document = await _open();
    return [
      for (var index = 0; index < document.pages.length; index++)
        ComicPage(
          id: 'page-${index + 1}',
          name: 'Seite ${index + 1}',
          // The size a comic page carries is a check against the archive
          // changing underneath; a PDF page has no such number, so the page
          // count stands in for it and catches a swapped file.
          size: document.pages.length,
        ),
    ];
  }

  @override
  Future<Map<String, String>> materialize(List<ComicPage> pages) async {
    if (pages.isEmpty) return const {};
    final document = await _open();
    final directory = _directory ??= await Directory(
      p.join(Directory.systemTemp.path, 'fundus-pdf-pages'),
    ).createTemp('pages-');

    final result = <String, String>{};
    for (final page in pages) {
      final number = int.tryParse(page.id.split('-').last);
      if (number == null || number < 1 || number > document.pages.length) {
        throw const ComicArchiveException(
          'Diese Seite gehört nicht zu diesem Dokument.',
        );
      }
      final target = File(p.join(directory.path, '${page.id}.png'));
      if (await target.exists()) {
        result[page.id] = target.path;
        continue;
      }

      final source = document.pages[number - 1];
      final height = (targetWidth * source.height / source.width).round();
      final rendered = await source.render(
        width: targetWidth,
        height: height,
        backgroundColor: 0xFFFFFFFF,
      );
      if (rendered == null) {
        throw const ComicArchiveException(
          'Die Seite konnte nicht gezeichnet werden.',
        );
      }
      try {
        // pdfium hands back raw BGRA; turning that into a file happens off
        // the UI isolate, because a large page is megabytes of pixels.
        final bytes = Uint8List.fromList(rendered.pixels);
        final width = rendered.width;
        final pixelHeight = rendered.height;
        final png = await Isolate.run(
          () => _encodePng(bytes, width, pixelHeight),
        );
        await target.writeAsBytes(png, flush: true);
      } finally {
        rendered.dispose();
      }
      result[page.id] = target.path;
    }
    return result;
  }

  static Uint8List _encodePng(Uint8List bgra, int width, int height) {
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bgra.buffer,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
    return img.encodePng(image);
  }

  @override
  Future<void> dispose() async {
    await _document?.dispose();
    _document = null;
    final directory = _directory;
    _directory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
