import 'dart:io';

import 'package:fundus_client/fundus_client.dart';
import 'package:path/path.dart' as p;

import 'comic_archive.dart';

/// A comic that stays on the other machine.
///
/// Fetching the whole archive first was the obvious way and the wrong one: a
/// volume is a hundred and fifty megabytes, and nobody wants to watch a bar
/// fill before the first page appears. The server already serves a volume
/// page by page, so the reader takes them one at a time — the first page
/// arrives in the time one page takes.
///
/// It is the same [ComicPageSource] the archive on disk implements, which is
/// why the reader above it is unchanged: paging, double pages, direction,
/// bookmarks and the page overview never learn where the pages came from.
final class RemoteComicPageSource implements ComicPageSource {
  RemoteComicPageSource({
    required this.client,
    required this.libraryId,
    required this.fileId,
    required this.cacheDirectory,
    String? name,
  }) : _name = name;

  final FundusRemoteClient client;
  final String libraryId;
  final String fileId;

  /// Where fetched pages are kept. A page read once is usually read again —
  /// paging back a spread is the commonest gesture in a comic.
  final Directory cacheDirectory;

  final String? _name;
  List<ComicPage>? _pages;
  final Map<String, String> _fetched = {};

  @override
  String get name => _name ?? fileId;

  @override
  Future<List<ComicPage>> pages() async {
    final known = _pages;
    if (known != null) return known;
    final decoded = await client.comicPages(libraryId, fileId);
    return _pages = [
      for (final page in decoded)
        ComicPage(id: page.id, name: page.name, size: page.size),
    ];
  }

  @override
  Future<Map<String, String>> materialize(List<ComicPage> pages) async {
    final all = await this.pages();
    final result = <String, String>{};
    await cacheDirectory.create(recursive: true);

    for (final page in pages) {
      final cached = _fetched[page.id];
      if (cached != null && await File(cached).exists()) {
        result[page.id] = cached;
        continue;
      }
      final index = all.indexWhere((entry) => entry.id == page.id);
      if (index < 0) continue;
      final bytes = await client.comicPage(libraryId, fileId, index);
      // Named by index rather than by the entry's own name: an archive may
      // hold `01.jpg` in two folders, and a file system may not.
      final target = File(
        p.join(cacheDirectory.path, '$fileId-$index${p.extension(page.name)}'),
      );
      await target.writeAsBytes(bytes, flush: true);
      _fetched[page.id] = target.path;
      result[page.id] = target.path;
    }
    return result;
  }

  @override
  Future<void> dispose() async {
    _pages = null;
    _fetched.clear();
    // The files stay: reopening a volume where it was left off should not
    // fetch the same spread again. The cache as a whole is thrown away with
    // the peer library.
  }
}
