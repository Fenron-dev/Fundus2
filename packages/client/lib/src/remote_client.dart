import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

import 'pairing_code.dart';
import 'pinned_client.dart';

/// What went wrong talking to the other side.
final class FundusRemoteException implements Exception {
  const FundusRemoteException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  /// Whether asking again later could work. A wrong token will not fix
  /// itself; a server that is switched off might.
  bool get isTransient => statusCode == null || statusCode! >= 500;

  @override
  String toString() => message;
}

/// One library on the other side.
final class RemoteLibrary {
  const RemoteLibrary({
    required this.id,
    required this.name,
    this.workCount = 0,
  });

  final String id;
  final String name;
  final int workCount;
}

/// A work as the other side describes it.
final class RemoteWork {
  const RemoteWork({
    required this.id,
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.authors = const [],
    this.series,
    this.fileCount = 0,
    this.hasCover = false,
    this.tags = const [],
  });

  final String id;
  final String kind;
  final String title;
  final String subtitle;
  final List<String> authors;
  final String? series;
  final int fileCount;
  final bool hasCover;
  final List<String> tags;
}

/// Talking to another Fundus.
///
/// Only the calls the client actually makes, and each one named after what it
/// means rather than after its route. Everything goes through one place so
/// the bearer token, the timeouts and the error shape are decided once.
final class FundusRemoteClient {
  FundusRemoteClient({
    required this.baseUri,
    required this.token,
    http.Client? httpClient,
    String? certificateFingerprint,
    this.timeout = const Duration(seconds: 20),
  }) : _http =
           httpClient ??
           (certificateFingerprint == null || certificateFingerprint.isEmpty
               ? http.Client()
               : pinnedHttpClient(certificateFingerprint));

  final Uri baseUri;
  final String token;
  final Duration timeout;
  final http.Client _http;

  /// Claims a pairing code and returns the token that follows from it.
  ///
  /// Unauthenticated by nature — this is the call that earns the credentials.
  static Future<({String token, String serverId, String serverName})> claim({
    required FundusPairingCode code,
    required String pin,
    required String deviceId,
    required String deviceName,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (code.isExpired) {
      throw const FundusRemoteException(
        'Der Kopplungscode ist abgelaufen. Lass dir auf dem anderen Gerät '
        'einen neuen zeigen.',
      );
    }
    // The code names the certificate; from here on nothing else is accepted.
    final client = httpClient ?? pinnedHttpClient(code.certificateFingerprint);
    try {
      final http.Response response;
      try {
        response = await client
            .post(
              code.baseUri.resolve('/v1/pairing/claim'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({
                'nonce': code.nonce,
                'pin': pin.trim(),
                'device_id': deviceId,
                'device_name': deviceName,
              }),
            )
            .timeout(timeout);
      } on Object catch (error) {
        throw _unreachable(error);
      }
      final decoded = _decode(response);
      final issued = decoded['token'];
      if (issued is! String || issued.isEmpty) {
        throw const FundusRemoteException(
          'Die Gegenstelle hat kein Zugangstoken ausgestellt.',
        );
      }
      return (
        token: issued,
        serverId: '${decoded['server_id'] ?? code.serverId}',
        serverName: '${decoded['server_name'] ?? code.serverName ?? ''}',
      );
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// A cheap authenticated request, used as a heartbeat.
  ///
  /// It has to be authenticated: `/health` answers without a token and would
  /// therefore prove nothing and — more to the point — would not tell the
  /// other side that this device is still there. The paired-device list on
  /// the far end is kept alive by requests arriving with the token.
  Future<bool> ping() async {
    try {
      await _get('/v1/capabilities');
      return true;
    } on FundusRemoteException {
      return false;
    }
  }

  Future<List<RemoteLibrary>> libraries() async {
    final decoded = await _get('/v1/libraries');
    final entries = decoded['libraries'];
    if (entries is! List) return const [];
    return [
      for (final entry in entries)
        if (entry is Map)
          RemoteLibrary(
            id: '${entry['id'] ?? ''}',
            name: '${entry['name'] ?? 'Bibliothek'}',
            workCount: entry['work_count'] is num
                ? (entry['work_count'] as num).round()
                : 0,
          ),
    ];
  }

  Future<List<RemoteWork>> works(String libraryId) async {
    final decoded = await _get('/v1/libraries/$libraryId/works');
    final entries = decoded['works'];
    if (entries is! List) return const [];
    return [
      for (final entry in entries)
        if (entry is Map) _workFrom(entry),
    ];
  }

  static RemoteWork _workFrom(Map<Object?, Object?> entry) => RemoteWork(
    id: '${entry['id'] ?? ''}',
    kind: '${entry['kind'] ?? ''}',
    title: '${entry['title'] ?? ''}',
    subtitle: '${entry['subtitle'] ?? ''}',
    authors: [
      if (entry['authors'] is List)
        for (final author in entry['authors'] as List) '$author',
    ],
    series: entry['series'] is String ? entry['series'] as String : null,
    fileCount: entry['file_count'] is num
        ? (entry['file_count'] as num).round()
        : 0,
    hasCover: entry['has_cover'] == true,
    tags: [
      if (entry['tags'] is List)
        for (final tag in entry['tags'] as List) '$tag',
    ],
  );

  /// The other side's reading position for a work, or null if it has none.
  /// Welche Werke drüben überhaupt etwas haben, das sich abgleichen ließe.
  ///
  /// Eine Gegenstelle, die das noch nicht kennt, antwortet mit einem Fehler;
  /// dann bleibt es bei dem, was diese Seite für abgleichenswert hält.
  Future<Set<String>> worksWorthSyncing(String libraryId) async {
    try {
      final decoded = await _get('/v1/libraries/$libraryId/sync-index');
      final works = decoded['works'];
      if (works is! List) return const {};
      return {
        for (final id in works)
          if (id is String) id,
      };
    } on FundusRemoteException {
      return const {};
    }
  }

  /// Welche Werke drüben seit [since] einen neuen Stand haben.
  ///
  /// Die eine Frage vor dem Abgleich: danach wird nur das nachgeholt, was
  /// sich bewegt hat, statt jedes Werk einzeln zu erfragen.
  Future<List<({String workId, DateTime updatedAt})>> progressChangedSince(
    String libraryId, {
    DateTime? since,
  }) async {
    final decoded = await _get(
      '/v1/libraries/$libraryId/progress',
      query: since == null
          ? const {}
          : {'since': since.toUtc().toIso8601String()},
    );
    final changed = decoded['changed'];
    if (changed is! List) return const [];
    return [
      for (final entry in changed)
        if (entry is Map && entry['work_id'] is String)
          (
            workId: entry['work_id'] as String,
            updatedAt:
                DateTime.tryParse('${entry['updated_at'] ?? ''}')?.toUtc() ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          ),
    ];
  }

  Future<RemoteProgress?> progress(String libraryId, String workId) async {
    final decoded = await _get('/v1/libraries/$libraryId/progress/$workId');
    final progress = decoded['progress'];
    if (progress is! Map) return null;
    return RemoteProgress.fromJson(Map<String, Object?>.from(progress));
  }

  Future<RemoteProgress?> saveProgress({
    required String libraryId,
    required String workId,
    required String fileId,
    required MediaPosition position,
    required bool finished,
    required String deviceId,
    String? operationId,
    DateTime? updatedAt,
  }) async {
    final decoded = await _put(
      '/v1/libraries/$libraryId/progress/$workId',
      body: {
        'file_id': fileId,
        'position': position.toJson(),
        'finished': finished,
        'device_id': deviceId,
        // Wann der Stand entstanden ist, nicht wann er ankam. Eine
        // Gegenstelle, die das nicht kennt, ignoriert das Feld.
        if (updatedAt != null)
          'updated_at': updatedAt.toUtc().millisecondsSinceEpoch,
        // Die Gegenstelle verlangt einen Schlüssel je Schreibvorgang: derselbe
        // Stand zweimal gesendet soll einmal zählen, nicht zweimal in der
        // Historie stehen.
        'operation_id': operationId ?? FundusId.generate(),
      },
    );
    return RemoteProgress.fromJson(decoded);
  }

  Future<RemoteAnnotations> annotations(String libraryId, String workId) async {
    final decoded = await _get('/v1/libraries/$libraryId/annotations/$workId');
    return RemoteAnnotations.fromJson(decoded);
  }

  Future<void> saveBookmark({
    required String libraryId,
    required String workId,
    required String fileId,
    required MediaPosition position,
    String? label,
    String? note,
  }) => _post(
    '/v1/libraries/$libraryId/annotations/$workId/bookmarks',
    body: {
      'file_id': fileId,
      'position': position.toJson(),
      'label': ?label,
      'note': ?note,
    },
  );

  Future<void> saveHighlight({
    required String libraryId,
    required String workId,
    required String fileId,
    required MediaPosition position,
    required String quote,
    String color = '#FFF176',
    String? note,
  }) => _post(
    '/v1/libraries/$libraryId/annotations/$workId/highlights',
    body: {
      'file_id': fileId,
      'position': position.toJson(),
      'quote': quote,
      'color': color,
      'note': ?note,
    },
  );

  Future<void> saveTags({
    required String libraryId,
    required String workId,
    required List<String> tags,
  }) => _put(
    '/v1/libraries/$libraryId/annotations/$workId/tags',
    body: {'tags': tags},
  );

  /// Die Listen der anderen Seite.
  ///
  /// Eine Liste ist keine Ansicht, sondern etwas, das jemand gemacht hat —
  /// sie gehört der Bibliothek und nicht dem Gerät, auf dem sie entstand.
  /// Deshalb reist sie mit.
  Future<List<LibraryPlaylist>> playlists(String libraryId) async {
    final decoded = await _get('/v1/libraries/$libraryId/playlists');
    final rows = decoded['playlists'];
    if (rows is! List) return const [];
    return [
      for (final row in rows)
        if (row is Map<String, Object?>) playlistFromJson(row),
    ];
  }

  /// Legt drüben eine Liste an, die es hier schon gibt — mit derselben
  /// Kennung, damit beide Seiten danach von derselben Liste sprechen.
  Future<LibraryPlaylist> createPlaylist(
    String libraryId,
    LibraryPlaylist playlist,
  ) async {
    final decoded = await _post(
      '/v1/libraries/$libraryId/playlists',
      body: {'id': playlist.id, ..._playlistBody(playlist)},
    );
    return playlistFromJson(decoded);
  }

  /// Schreibt eine Liste drüben fort. [expectedRevision] ist die Fassung, von
  /// der diese Seite ausgeht; stimmt sie nicht, hat jemand anders zuerst
  /// geschrieben und die Gegenstelle sagt das mit 409.
  Future<LibraryPlaylist> updatePlaylist(
    String libraryId,
    LibraryPlaylist playlist, {
    required int expectedRevision,
  }) async {
    final decoded = await _put(
      '/v1/libraries/$libraryId/playlists/${playlist.id}',
      body: {'expected_revision': expectedRevision, ..._playlistBody(playlist)},
    );
    return playlistFromJson(decoded);
  }

  static Map<String, Object?> _playlistBody(LibraryPlaylist playlist) => {
    'name': playlist.name,
    'media_type': ?playlist.mediaType,
    'items': [
      for (final entry in playlist.entries)
        {'work_id': entry.workId, 'file_id': ?entry.fileId},
    ],
  };

  /// Liest eine Liste, wie der Server sie schreibt.
  static LibraryPlaylist playlistFromJson(Map<String, Object?> json) {
    final kindName = json['kind'];
    return LibraryPlaylist(
      id: json['id'] as String,
      name: json['name'] as String,
      kind: LibraryPlaylistKind.values.firstWhere(
        (kind) => kind.name == kindName,
        orElse: () => LibraryPlaylistKind.manual,
      ),
      mediaType: json['media_type'] as String?,
      entries: _entries(json),
      revision: (json['revision'] as num?)?.round() ?? 1,
      createdAt: _time(json['created_at']),
      updatedAt: _time(json['updated_at']),
    );
  }

  /// Die Zeilen einer Liste. `items` ist die genauere Angabe — eine Zeile
  /// darf eine einzelne Datei meinen; eine ältere Gegenstelle schickt nur
  /// `work_ids`, und dann sind es eben ganze Werke.
  static List<PlaylistEntry> _entries(Map<String, Object?> json) {
    final items = json['items'];
    if (items is List) {
      return [
        for (final item in items)
          if (item is Map && item['work_id'] is String)
            PlaylistEntry(
              item['work_id'] as String,
              fileId: item['file_id'] as String?,
            ),
      ];
    }
    final workIds = json['work_ids'];
    if (workIds is! List) return const [];
    return [
      for (final workId in workIds)
        if (workId is String) PlaylistEntry(workId),
    ];
  }

  static DateTime _time(Object? value) => value is String
      ? (DateTime.tryParse(value)?.toUtc() ?? DateTime.now().toUtc())
      : DateTime.now().toUtc();

  /// Löscht eine Liste drüben.
  Future<void> deletePlaylist(String libraryId, String playlistId) async {
    await _delete('/v1/libraries/$libraryId/playlists/$playlistId');
  }

  /// The whole catalogue, works and their files, in one answer.
  ///
  /// This is what a mirror reads. The alternative — the works list, then one
  /// request per work for its files — is a thousand round trips over the very
  /// network the mirror exists to stop depending on.
  Future<List<RemoteWorkRecord>> catalogue(
    String libraryId, {
    Iterable<String>? ids,
  }) async {
    final query = ids == null ? '' : '?ids=${ids.join(',')}';
    final decoded = await _get('/v1/libraries/$libraryId/catalogue$query');
    final entries = decoded['works'];
    if (entries is! List) return const [];
    return [
      for (final entry in entries)
        if (entry is Map) _recordFrom(Map<String, Object?>.from(entry)),
    ];
  }

  static RemoteWorkRecord _recordFrom(Map<String, Object?> value) {
    final id = '${value['id'] ?? ''}';
    if (!FundusId.isSafe(id)) {
      throw const FormatException(
        'Die Gegenstelle lieferte eine ungültige Werk-ID.',
      );
    }
    final authors = value['authors'];
    final files = value['files'];
    return RemoteWorkRecord(
      id: id,
      kind: '${value['kind'] ?? 'document'}',
      title: '${value['title'] ?? 'Ohne Titel'}',
      author: authors is List && authors.isNotEmpty ? '${authors.first}' : null,
      subtitle: value['subtitle'] is String
          ? value['subtitle'] as String
          : null,
      series: value['series'] is String ? value['series'] as String : null,
      seriesSequence: (value['series_sequence'] as num?)?.toDouble(),
      hasCover: value['has_cover'] == true,
      tags: [
        if (value['tags'] case final List tags)
          for (final tag in tags) '$tag',
      ],
      metadata: {
        if (value['language'] != null) 'language': value['language'],
        if (value['description'] != null) 'description': value['description'],
        if (value['publisher'] != null) 'publisher': value['publisher'],
        if (value['published_year'] != null)
          'published_year': value['published_year'],
        if (value['narrators'] case final List narrators)
          if (narrators.isNotEmpty)
            'narrators': [for (final name in narrators) '$name'],
      },
      files: [
        if (files is List)
          for (var index = 0; index < files.length; index++)
            if (files[index] case final Map file)
              _fileFrom(Map<String, Object?>.from(file), index),
      ],
    );
  }

  static RemoteFileRecord _fileFrom(Map<String, Object?> value, int fallback) {
    final id = '${value['id'] ?? ''}';
    if (!FundusId.isSafe(id)) {
      throw const FormatException(
        'Die Gegenstelle lieferte eine ungültige Datei-ID.',
      );
    }
    final filename = '${value['title'] ?? ''}';
    final dot = filename.lastIndexOf('.');
    final seconds = (value['duration_seconds'] as num?)?.toDouble();
    return RemoteFileRecord(
      id: id,
      filename: filename,
      position: (value['position'] as num?)?.toInt() ?? fallback,
      extension: dot > 0 ? filename.substring(dot).toLowerCase() : '',
      durationMs: seconds == null ? null : (seconds * 1000).round(),
    );
  }

  /// What the other side holds, as „this work, in this state".
  ///
  /// Thirty-odd bytes per work rather than the record itself, which is what
  /// makes asking „what changed?" cheap enough to ask every time.
  Future<Map<String, String>> catalogueIndex(String libraryId) async {
    final decoded = await _get('/v1/libraries/$libraryId/catalogue/index');
    final works = decoded['works'];
    if (works is! List) return const {};
    return {
      for (final entry in works)
        if (entry is Map && entry['id'] is String)
          entry['id'] as String: '${entry['hash'] ?? ''}',
    };
  }

  /// The pages of a comic volume, without fetching the volume.
  ///
  /// The other side opens the archive and lists what is in it; a page then
  /// arrives on its own. That is the difference between waiting for one page
  /// and waiting for a hundred and fifty megabytes.
  Future<List<ComicPageRecord>> comicPages(
    String libraryId,
    String fileId,
  ) async {
    final decoded = await _get(
      '/v1/libraries/$libraryId/files/$fileId/comic/pages',
    );
    final pages = decoded['pages'];
    if (pages is! List) return const [];
    return [
      for (final entry in pages)
        if (entry is Map)
          ComicPageRecord(
            id: '${entry['id'] ?? ''}',
            name: '${entry['name'] ?? ''}',
            size: (entry['size'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  Future<Uint8List> comicPage(String libraryId, String fileId, int index) =>
      getBytes('/v1/libraries/$libraryId/files/$fileId/comic/pages/$index');

  /// Where a work's cover can be fetched, for the catalogue mirror.
  Uri coverUri(String libraryId, String workId) =>
      baseUri.resolve('/v1/libraries/$libraryId/works/$workId/cover');

  /// Fetches raw bytes — a cover, a page, a file.
  Future<Uint8List> getBytes(String path) async {
    final http.Response response;
    try {
      response = await _http
          .get(baseUri.resolve(path), headers: _headers)
          .timeout(timeout);
    } on Object catch (error) {
      throw _unreachable(error);
    }
    if (response.statusCode >= 400) {
      throw FundusRemoteException(
        _messageFor('', response.statusCode),
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  Future<Map<String, Object?>> _get(
    String path, {
    Map<String, String> query = const {},
  }) async {
    final http.Response response;
    final uri = query.isEmpty
        ? baseUri.resolve(path)
        : baseUri.resolve(path).replace(queryParameters: query);
    try {
      response = await _http.get(uri, headers: _headers).timeout(timeout);
    } on Object catch (error) {
      throw _unreachable(error);
    }
    return _decode(response);
  }

  Future<Map<String, Object?>> _put(
    String path, {
    required Map<String, Object?> body,
  }) async {
    final http.Response response;
    try {
      response = await _http
          .put(
            baseUri.resolve(path),
            headers: {..._headers, 'content-type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on Object catch (error) {
      throw _unreachable(error);
    }
    return _decode(response);
  }

  Future<Map<String, Object?>> _post(
    String path, {
    required Map<String, Object?> body,
  }) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            baseUri.resolve(path),
            headers: {..._headers, 'content-type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on Object catch (error) {
      throw _unreachable(error);
    }
    return _decode(response);
  }

  Future<Map<String, Object?>> _delete(String path) async {
    final http.Response response;
    try {
      response = await _http
          .delete(baseUri.resolve(path), headers: _headers)
          .timeout(timeout);
    } on Object catch (error) {
      throw _unreachable(error);
    }
    return _decode(response);
  }

  Map<String, String> get _headers => {'authorization': 'Bearer $token'};

  /// Turns a transport failure into something worth reading.
  ///
  /// A refused handshake is the interesting one: it means the certificate is
  /// not the one the pairing code named. That is either a device that has
  /// been reinstalled since — new key, new certificate — or something else
  /// answering in its place, and the two are worth telling apart from "the
  /// other side is switched off".
  static FundusRemoteException _unreachable(Object error) {
    if (error is HandshakeException ||
        (error is http.ClientException &&
            error.message.contains('CERTIFICATE_VERIFY_FAILED'))) {
      return const FundusRemoteException(
        'Das Zertifikat der Gegenstelle passt nicht zum Kopplungscode. '
        'Wenn dort neu installiert wurde, braucht es eine neue Kopplung.',
      );
    }
    return FundusRemoteException('Die Gegenstelle antwortet nicht: $error');
  }

  static Map<String, Object?> _decode(http.Response response) {
    final Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      throw FundusRemoteException(
        'Die Gegenstelle hat etwas geantwortet, das kein JSON ist.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode >= 400) {
      final code = decoded is Map ? '${decoded['error'] ?? ''}' : '';
      throw FundusRemoteException(
        _messageFor(code, response.statusCode),
        statusCode: response.statusCode,
      );
    }
    return decoded is Map
        ? Map<String, Object?>.from(decoded)
        : const <String, Object?>{};
  }

  static String _messageFor(String code, int status) => switch (code) {
    'pairing_unavailable' =>
      'Das andere Gerät bietet gerade keine Kopplung an.',
    'invalid_pairing_code' => 'Code oder PIN stimmen nicht.',
    'pairing_expired' => 'Der Kopplungscode ist abgelaufen.',
    'pairing_locked' =>
      'Zu viele Fehlversuche. Lass dir einen neuen Code zeigen.',
    'unauthorized' =>
      'Diese Verbindung gilt nicht mehr. Das andere Gerät hat sie vermutlich '
          'entkoppelt.',
    'library_not_found' => 'Diese Bibliothek gibt es dort nicht mehr.',
    'work_not_found' => 'Dieses Werk gibt es dort nicht mehr.',
    _ => 'Die Gegenstelle hat mit $status geantwortet.',
  };

  void close() => _http.close();
}

/// A reading position as the other side keeps it.
final class RemoteProgress {
  const RemoteProgress({
    required this.workId,
    required this.position,
    required this.finished,
    required this.revision,
    required this.updatedAt,
    this.fileId,
    this.deviceId = '',
  });

  factory RemoteProgress.fromJson(Map<String, Object?> value) {
    final encoded = value['position'];
    return RemoteProgress(
      workId: '${value['work_id'] ?? ''}',
      fileId: value['file_id'] is String ? value['file_id'] as String : null,
      position: encoded is Map
          ? MediaPosition.fromJson(Map<String, Object?>.from(encoded))
          : const MediaPosition(kind: MediaPositionKind.time, numericValue: 0),
      finished: value['finished'] == true,
      revision: value['revision'] is num
          ? (value['revision'] as num).round()
          : 0,
      updatedAt:
          DateTime.tryParse('${value['updated_at'] ?? ''}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      deviceId: '${value['device_id'] ?? ''}',
    );
  }

  final String workId;
  final String? fileId;
  final MediaPosition position;
  final bool finished;
  final int revision;
  final DateTime updatedAt;
  final String deviceId;
}

/// The marks and notes the other side keeps for a work.
final class RemoteAnnotations {
  const RemoteAnnotations({
    this.tags = const [],
    this.bookmarks = const [],
    this.highlights = const [],
  });

  factory RemoteAnnotations.fromJson(Map<String, Object?> value) {
    List<Map<String, Object?>> listOf(String key) => [
      if (value[key] is List)
        for (final entry in value[key]! as List)
          if (entry is Map) Map<String, Object?>.from(entry),
    ];
    return RemoteAnnotations(
      tags: [
        if (value['tags'] is List)
          for (final tag in value['tags']! as List) '$tag',
      ],
      bookmarks: [
        for (final entry in listOf('bookmarks')) RemoteMark.fromJson(entry),
      ],
      highlights: [
        for (final entry in listOf('highlights')) RemoteMark.fromJson(entry),
      ],
    );
  }

  final List<String> tags;
  final List<RemoteMark> bookmarks;
  final List<RemoteMark> highlights;
}

/// A bookmark or a highlight — the same shape either way.
final class RemoteMark {
  const RemoteMark({
    required this.id,
    required this.position,
    this.fileId,
    this.label,
    this.note,
    this.quote,
    this.color,
    this.createdAt,
  });

  factory RemoteMark.fromJson(Map<String, Object?> value) {
    final encoded = value['position'];
    return RemoteMark(
      id: '${value['id'] ?? ''}',
      fileId: value['file_id'] is String ? value['file_id'] as String : null,
      position: encoded is Map
          ? MediaPosition.fromJson(Map<String, Object?>.from(encoded))
          : const MediaPosition(kind: MediaPositionKind.time, numericValue: 0),
      label: value['label'] is String ? value['label'] as String : null,
      note: value['note'] is String ? value['note'] as String : null,
      quote: value['quote'] is String ? value['quote'] as String : null,
      color: value['color'] is String ? value['color'] as String : null,
      createdAt: DateTime.tryParse('${value['created_at'] ?? ''}')?.toUtc(),
    );
  }

  final String id;
  final String? fileId;
  final MediaPosition position;
  final String? label;
  final String? note;
  final String? quote;
  final String? color;
  final DateTime? createdAt;

  /// What makes two marks the same mark across devices.
  ///
  /// Ids are handed out locally, so the same bookmark made on two devices has
  /// two ids. What it *is* — this spot in this file, with this text — is the
  /// only thing both sides agree on.
  String get fingerprint {
    final at = position.numericValue?.toStringAsFixed(3) ?? position.key ?? '';
    return '${fileId ?? ''}|${position.elementId ?? ''}|$at|${quote ?? ''}';
  }
}

/// One page of a comic, as the other side lists it.
final class ComicPageRecord {
  const ComicPageRecord({
    required this.id,
    required this.name,
    required this.size,
  });

  final String id;
  final String name;
  final int size;
}
