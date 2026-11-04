import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../model/metadata_import_conflict.dart';

/// What a Plex Media Server knows about one item, and the files it plays.
///
/// Read from Plex's own database (`com.plexapp.plugins.library.db`), never
/// from its network API: the database is what a person can hand over without
/// tokens, and it holds the watched state too.
final class PlexItem {
  const PlexItem({
    required this.id,
    required this.type,
    required this.title,
    this.parentId,
    this.originalTitle,
    this.summary,
    this.year,
    this.studio,
    this.index,
    this.genres = const [],
    this.directors = const [],
    this.externalIds = const {},
    this.files = const [],
    this.viewCount = 0,
    this.viewOffset,
    this.lastViewedAt,
  });

  static const movie = 1;
  static const show = 2;
  static const season = 3;
  static const episode = 4;
  static const artist = 8;
  static const album = 9;
  static const track = 10;

  final int id;
  final int type;
  final String title;
  final int? parentId;
  final String? originalTitle;
  final String? summary;
  final int? year;
  final String? studio;

  /// Episode or track number within its parent.
  final int? index;
  final List<String> genres;
  final List<String> directors;
  final Map<String, String> externalIds;

  /// Base name and size of every file this item plays.
  final List<({String filename, int size})> files;
  final int viewCount;
  final Duration? viewOffset;
  final DateTime? lastViewedAt;

  bool get watched => viewCount > 0;
}

/// Reads a Plex database without touching the original.
///
/// The file is copied first, together with its write-ahead log: a running
/// Plex server holds the original open, and a half-written page from it
/// must not be what Fundus reads.
final class PlexLibraryReader {
  const PlexLibraryReader();

  /// More than any real library needs; a bigger file is not a Plex library.
  static const maximumBytes = 8 * 1024 * 1024 * 1024;

  Future<List<PlexItem>> read(File database, {Directory? scratch}) async {
    if (!await database.exists()) {
      throw const FormatException('Die Plex-Datenbank wurde nicht gefunden.');
    }
    final size = await database.length();
    if (size <= 0 || size > maximumBytes) {
      throw const FormatException('Die Datei ist keine Plex-Datenbank.');
    }
    final temporary = await (scratch ?? Directory.systemTemp).createTemp(
      'fundus-plex-',
    );
    try {
      final copy = File(p.join(temporary.path, 'library.db'));
      await database.copy(copy.path);
      for (final suffix in const ['-wal', '-shm']) {
        final companion = File('${database.path}$suffix');
        if (await companion.exists()) {
          await companion.copy('${copy.path}$suffix');
        }
      }
      return _readCopy(copy.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  static List<PlexItem> _readCopy(String path) {
    final Database db;
    try {
      db = sqlite3.open(path);
    } on SqliteException {
      throw const FormatException('Die Datei ist keine Plex-Datenbank.');
    }
    try {
      // Plex sorts with collations of its own; any order will do here.
      db.createCollation(
        name: 'naturalsort',
        function: (a, b) => (a ?? '').compareTo(b ?? ''),
      );
      Set<String> columns(String table) => {
        for (final row in db.select('PRAGMA table_info("$table")'))
          row['name'] as String,
      };
      final items = columns('metadata_items');
      if (!items.containsAll(const {'id', 'metadata_type', 'title'})) {
        throw const FormatException('Die Datei ist keine Plex-Datenbank.');
      }
      String column(String name) => items.contains(name) ? name : 'NULL';

      final genres = <int, List<String>>{};
      final directors = <int, List<String>>{};
      final ids = <int, Map<String, String>>{};
      final tagColumns = columns('tags');
      if (columns(
            'taggings',
          ).containsAll(const {'metadata_item_id', 'tag_id'}) &&
          tagColumns.containsAll(const {'id', 'tag', 'tag_type'})) {
        for (final row in db.select(
          'SELECT tg.metadata_item_id AS item, t.tag AS tag, '
          't.tag_type AS type FROM taggings tg JOIN tags t ON t.id = tg.tag_id',
        )) {
          final item = row['item'] as int?;
          final tag = (row['tag'] as String?)?.trim();
          if (item == null || tag == null || tag.isEmpty) continue;
          final external = _externalId(tag);
          if (external != null) {
            (ids[item] ??= {}).putIfAbsent(external.key, () => external.id);
            continue;
          }
          switch (row['type']) {
            case 1:
              (genres[item] ??= []).add(tag);
            case 4:
              (directors[item] ??= []).add(tag);
          }
        }
      }

      final files = <int, List<({String filename, int size})>>{};
      if (columns('media_parts').containsAll(const {'media_item_id', 'file'}) &&
          columns(
            'media_items',
          ).containsAll(const {'id', 'metadata_item_id'})) {
        final sized = columns('media_parts').contains('size');
        for (final row in db.select(
          'SELECT mi.metadata_item_id AS item, mp.file AS file, '
          '${sized ? 'mp.size' : '0'} AS size '
          'FROM media_parts mp JOIN media_items mi ON mi.id = mp.media_item_id',
        )) {
          final item = row['item'] as int?;
          final file = row['file'] as String?;
          if (item == null || file == null || file.isEmpty) continue;
          // Plex may run on another machine: only the name and the size are
          // comparable, never the path.
          final name = file.split(RegExp(r'[\\/]')).last;
          (files[item] ??= []).add((
            filename: name,
            size: (row['size'] as num?)?.toInt() ?? 0,
          ));
        }
      }

      final settings = <String, ({int count, int? offset, int? viewedAt})>{};
      final settingColumns = columns('metadata_item_settings');
      if (settingColumns.containsAll(const {
        'account_id',
        'guid',
        'view_count',
      })) {
        // The owner is the account with the most history.
        final owner = db.select(
          'SELECT account_id FROM metadata_item_settings '
          'GROUP BY account_id ORDER BY COUNT(*) DESC LIMIT 1',
        );
        if (owner.isNotEmpty) {
          String settingColumn(String name) =>
              settingColumns.contains(name) ? name : 'NULL';
          for (final row in db.select(
            'SELECT guid, view_count, ${settingColumn('view_offset')} '
            'AS view_offset, ${settingColumn('last_viewed_at')} '
            'AS last_viewed_at FROM metadata_item_settings '
            'WHERE account_id = ?',
            [owner.first['account_id']],
          )) {
            final guid = row['guid'] as String?;
            if (guid == null) continue;
            settings[guid] = (
              count: (row['view_count'] as num?)?.toInt() ?? 0,
              offset: (row['view_offset'] as num?)?.toInt(),
              viewedAt: (row['last_viewed_at'] as num?)?.toInt(),
            );
          }
        }
      }

      final rows = db.select(
        'SELECT id, ${column('parent_id')} AS parent_id, metadata_type, '
        '${column('guid')} AS guid, title, '
        '${column('original_title')} AS original_title, '
        '${column('summary')} AS summary, ${column('year')} AS year, '
        '${column('studio')} AS studio, ${items.contains('index') ? '"index"' : 'NULL'} AS item_index, '
        '${column('tags_genre')} AS tags_genre, '
        '${column('tags_director')} AS tags_director '
        'FROM metadata_items WHERE metadata_type IN (1, 2, 3, 4, 8, 9, 10)'
        '${items.contains('deleted_at') ? ' AND deleted_at IS NULL' : ''}',
      );
      return [
        for (final row in rows)
          if (row['id'] case final int id)
            _item(
              row,
              id,
              genres: genres[id],
              directors: directors[id],
              ids: ids[id],
              files: files[id],
              setting: settings[row['guid']],
            ),
      ];
    } on SqliteException {
      throw const FormatException(
        'Die Plex-Datenbank konnte nicht gelesen werden.',
      );
    } finally {
      db.close();
    }
  }

  static PlexItem _item(
    Row row,
    int id, {
    List<String>? genres,
    List<String>? directors,
    Map<String, String>? ids,
    List<({String filename, int size})>? files,
    ({int count, int? offset, int? viewedAt})? setting,
  }) {
    final guidId = _externalId(row['guid'] as String? ?? '');
    final legacyGenres = _pipeList(row['tags_genre']);
    final legacyDirectors = _pipeList(row['tags_director']);
    final year = (row['year'] as num?)?.toInt();
    return PlexItem(
      id: id,
      type: row['metadata_type'] as int,
      title: (row['title'] as String? ?? '').trim(),
      parentId: (row['parent_id'] as num?)?.toInt(),
      originalTitle: _text(row['original_title']),
      summary: _text(row['summary'], maximumLength: 50000),
      year: year != null && year > 1800 && year < 3000 ? year : null,
      studio: _text(row['studio']),
      index: (row['item_index'] as num?)?.toInt(),
      genres: {...?genres, ...legacyGenres}.toList(growable: false),
      directors: {...?directors, ...legacyDirectors}.toList(growable: false),
      externalIds: {
        ...?ids,
        if (guidId != null && !(ids?.containsKey(guidId.key) ?? false))
          guidId.key: guidId.id,
      },
      files: files ?? const [],
      viewCount: setting?.count ?? 0,
      viewOffset: setting?.offset == null || setting!.offset! <= 0
          ? null
          : Duration(milliseconds: setting.offset!),
      lastViewedAt: setting?.viewedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              setting!.viewedAt! * 1000,
              isUtc: true,
            ),
    );
  }

  /// `imdb://tt0111161`, `tmdb://278` and the older agent form
  /// `com.plexapp.agents.imdb://tt0111161?lang=de`.
  static ({String key, String id})? _externalId(String value) {
    final match = RegExp(
      r'^(?:com\.plexapp\.agents\.)?(imdb|tmdb|themoviedb|tvdb|thetvdb)://([^?/]+)',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final key = switch (match.group(1)) {
      'imdb' => 'imdb',
      'tmdb' || 'themoviedb' => 'tmdb',
      _ => 'tvdb',
    };
    return (key: key, id: match.group(2)!);
  }

  static List<String> _pipeList(Object? value) => value is String
      ? [
          for (final part in value.split('|'))
            if (part.trim().isNotEmpty) part.trim(),
        ]
      : const [];

  static String? _text(Object? value, {int maximumLength = 1000}) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length > maximumLength
        ? trimmed.substring(0, maximumLength)
        : trimmed;
  }
}

/// What an import from Plex did.
final class PlexImportReport {
  const PlexImportReport({
    required this.items,
    required this.matchedWorks,
    required this.updatedWorks,
    required this.watchedWorks,
    required this.conflicts,
  });

  /// Entries read from the Plex database.
  final int items;

  /// Works of this vault Plex knew by their files.
  final int matchedWorks;
  final int updatedWorks;
  final int watchedWorks;

  /// Fields that differ from a decision somebody made; for review.
  final List<MetadataImportConflict> conflicts;
}
