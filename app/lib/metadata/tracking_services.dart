import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'metadata_http_client.dart';

/// One change of progress to tell a tracking service.
final class TrackingUpdate {
  const TrackingUpdate({
    required this.service,
    required this.workId,
    required this.media,
    required this.ids,
    this.progress = 0,
    this.completed = false,
    this.episodes = const [],
    this.watchedAt,
  });

  /// `anilist`, `mal` or `trakt`.
  final String service;
  final String workId;

  /// `anime`, `manga`, `movie` or `show`.
  final String media;

  /// The work's ids at that service: `anilist`, `mal`, `tmdb`, `imdb`, `tvdb`.
  final Map<String, String> ids;

  /// Episodes watched or chapters read.
  final int progress;
  final bool completed;

  /// For Trakt shows: the season and episode numbers newly watched.
  final List<({int season, int episode})> episodes;
  final DateTime? watchedAt;

  String get key => '$service:$workId';

  Map<String, Object?> toJson() => {
    'service': service,
    'work_id': workId,
    'media': media,
    'ids': ids,
    'progress': progress,
    'completed': completed,
    'episodes': [
      for (final episode in episodes) [episode.season, episode.episode],
    ],
    if (watchedAt != null) 'watched_at': watchedAt!.toUtc().toIso8601String(),
  };

  static TrackingUpdate? fromJson(Object? value) {
    if (value is! Map) return null;
    final service = value['service'];
    final workId = value['work_id'];
    final media = value['media'];
    final ids = value['ids'];
    if (service is! String ||
        workId is! String ||
        media is! String ||
        ids is! Map) {
      return null;
    }
    return TrackingUpdate(
      service: service,
      workId: workId,
      media: media,
      ids: {
        for (final entry in ids.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      },
      progress: (value['progress'] as num?)?.toInt() ?? 0,
      completed: value['completed'] == true,
      episodes: [
        if (value['episodes'] case final List list)
          for (final entry in list)
            if (entry case [final num season, final num episode])
              (season: season.toInt(), episode: episode.toInt()),
      ],
      watchedAt: DateTime.tryParse('${value['watched_at'] ?? ''}'),
    );
  }
}

/// A service that keeps a list of what somebody watched and read.
abstract interface class ProgressTracker {
  String get service;

  /// Sends one update; throws when it did not arrive.
  Future<void> send(TrackingUpdate update);
}

/// Thrown when a service refuses the stored login; the person has to sign in
/// again rather than Fundus retrying forever.
final class TrackingAuthException implements Exception {
  const TrackingAuthException(this.service);

  final String service;
}

Map<String, String> _jsonHeaders(String token) => {
  'authorization': 'Bearer $token',
  'content-type': 'application/json',
  'accept': 'application/json',
  'user-agent': metadataUserAgent,
};

void _check(String service, http.Response response) {
  if (response.statusCode == 401 || response.statusCode == 403) {
    throw TrackingAuthException(service);
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw http.ClientException(
      '$service antwortete mit ${response.statusCode}.',
    );
  }
}

/// AniList: a token the person copied after signing in.
final class AniListTracker implements ProgressTracker {
  AniListTracker({required this.token, http.Client? client})
    : _client = client ?? createMetadataHttpClient();

  final String token;
  final http.Client _client;

  @override
  String get service => 'anilist';

  /// Signing in with the person's own AniList client. AniList's own PIN page
  /// shows the token, so nothing has to listen for a redirect here.
  static Uri authorizeUrl(String clientId) => Uri.https(
    'anilist.co',
    '/api/v2/oauth/authorize',
    {'client_id': clientId, 'response_type': 'token'},
  );

  @override
  Future<void> send(TrackingUpdate update) async {
    final id = int.tryParse(update.ids['anilist'] ?? '');
    if (id == null) return;
    final response = await _client
        .post(
          Uri.https('graphql.anilist.co', '/'),
          headers: _jsonHeaders(token),
          body: jsonEncode({
            'query':
                r'mutation ($mediaId: Int, $progress: Int, $status: MediaListStatus) '
                r'{ SaveMediaListEntry(mediaId: $mediaId, progress: $progress, '
                r'status: $status) { id } }',
            'variables': {
              'mediaId': id,
              'progress': update.progress,
              'status': update.completed ? 'COMPLETED' : 'CURRENT',
            },
          }),
        )
        .timeout(const Duration(seconds: 15));
    _check(service, response);
  }
}

/// MyAnimeList: OAuth with PKCE and refresh tokens.
final class MalTracker implements ProgressTracker {
  MalTracker({
    required this.clientId,
    required this.tokens,
    required this.onTokens,
    http.Client? client,
  }) : _client = client ?? createMetadataHttpClient();

  final String clientId;
  Map<String, Object?> tokens;
  final Future<void> Function(Map<String, Object?> tokens) onTokens;
  final http.Client _client;

  @override
  String get service => 'mal';

  /// A verifier for one sign-in. MyAnimeList only knows the plain method.
  static String newVerifier() {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(
      96,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  static Uri authorizeUrl({
    required String clientId,
    required String verifier,
    required String state,
  }) => Uri.https('myanimelist.net', '/v1/oauth2/authorize', {
    'response_type': 'code',
    'client_id': clientId,
    'code_challenge': verifier,
    'code_challenge_method': 'plain',
    'state': state,
  });

  /// The code from what the person pasted: the whole address the browser
  /// landed on, or only the code. A foreign state is refused.
  static String? codeFrom(String pasted, {required String state}) {
    final text = pasted.trim();
    final uri = Uri.tryParse(text);
    if (uri != null && uri.queryParameters.containsKey('code')) {
      if (uri.queryParameters['state'] != state) return null;
      return uri.queryParameters['code'];
    }
    return RegExp(r'^[A-Za-z0-9._~-]{20,}$').hasMatch(text) ? text : null;
  }

  static Future<Map<String, Object?>> exchange({
    required String clientId,
    required String code,
    required String verifier,
    http.Client? client,
  }) => _token(client ?? createMetadataHttpClient(), {
    'client_id': clientId,
    'grant_type': 'authorization_code',
    'code': code,
    'code_verifier': verifier,
  });

  static Future<Map<String, Object?>> _token(
    http.Client client,
    Map<String, String> form,
  ) async {
    final response = await client
        .post(
          Uri.https('myanimelist.net', '/v1/oauth2/token'),
          headers: const {'user-agent': metadataUserAgent},
          body: form,
        )
        .timeout(const Duration(seconds: 15));
    _check('mal', response);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['access_token'] is! String) {
      throw const FormatException('MyAnimeList lieferte kein Token.');
    }
    final expiresIn = (decoded['expires_in'] as num?)?.toInt() ?? 3600;
    return {
      'access_token': decoded['access_token'],
      if (decoded['refresh_token'] is String)
        'refresh_token': decoded['refresh_token'],
      'expires_at': DateTime.now()
          .add(Duration(seconds: expiresIn))
          .millisecondsSinceEpoch,
    };
  }

  Future<String> _access() async {
    final expires = (tokens['expires_at'] as num?)?.toInt() ?? 0;
    final refresh = tokens['refresh_token'];
    if (DateTime.now().millisecondsSinceEpoch < expires - 60000 ||
        refresh is! String) {
      return tokens['access_token'] as String? ?? '';
    }
    tokens = await _token(_client, {
      'client_id': clientId,
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
    });
    await onTokens(tokens);
    return tokens['access_token'] as String;
  }

  @override
  Future<void> send(TrackingUpdate update) async {
    final id = int.tryParse(update.ids['mal'] ?? '');
    if (id == null) return;
    final anime = update.media == 'anime';
    final response = await _client
        .patch(
          Uri.https(
            'api.myanimelist.net',
            '/v2/${anime ? 'anime' : 'manga'}/$id/my_list_status',
          ),
          headers: {
            'authorization': 'Bearer ${await _access()}',
            'user-agent': metadataUserAgent,
          },
          body: {
            'status': update.completed
                ? 'completed'
                : (anime ? 'watching' : 'reading'),
            anime ? 'num_watched_episodes' : 'num_chapters_read':
                '${update.progress}',
          },
        )
        .timeout(const Duration(seconds: 15));
    _check(service, response);
  }
}

/// Trakt: the device-code sign-in, so nothing has to catch a redirect.
final class TraktTracker implements ProgressTracker {
  TraktTracker({
    required this.clientId,
    required this.clientSecret,
    required this.tokens,
    required this.onTokens,
    http.Client? client,
  }) : _client = client ?? createMetadataHttpClient();

  final String clientId;
  final String clientSecret;
  Map<String, Object?> tokens;
  final Future<void> Function(Map<String, Object?> tokens) onTokens;
  final http.Client _client;

  @override
  String get service => 'trakt';

  static Map<String, String> _headers(String clientId, [String? token]) => {
    'content-type': 'application/json',
    'trakt-api-version': '2',
    'trakt-api-key': clientId,
    'user-agent': metadataUserAgent,
    if (token != null) 'authorization': 'Bearer $token',
  };

  /// Asks for a code the person types in at trakt.tv/activate.
  static Future<
    ({
      String deviceCode,
      String userCode,
      Uri url,
      Duration interval,
      Duration expiresIn,
    })
  >
  startDeviceLogin(String clientId, {http.Client? client}) async {
    final response = await (client ?? createMetadataHttpClient())
        .post(
          Uri.https('api.trakt.tv', '/oauth/device/code'),
          headers: _headers(clientId),
          body: jsonEncode({'client_id': clientId}),
        )
        .timeout(const Duration(seconds: 15));
    _check('trakt', response);
    final decoded = jsonDecode(response.body) as Map;
    return (
      deviceCode: decoded['device_code'] as String,
      userCode: decoded['user_code'] as String,
      url: Uri.parse(decoded['verification_url'] as String),
      interval: Duration(seconds: (decoded['interval'] as num?)?.toInt() ?? 5),
      expiresIn: Duration(
        seconds: (decoded['expires_in'] as num?)?.toInt() ?? 600,
      ),
    );
  }

  /// One poll of the device login: tokens once confirmed, null while waiting.
  static Future<Map<String, Object?>?> pollDeviceLogin({
    required String clientId,
    required String clientSecret,
    required String deviceCode,
    http.Client? client,
  }) async {
    final response = await (client ?? createMetadataHttpClient())
        .post(
          Uri.https('api.trakt.tv', '/oauth/device/token'),
          headers: _headers(clientId),
          body: jsonEncode({
            'code': deviceCode,
            'client_id': clientId,
            'client_secret': clientSecret,
          }),
        )
        .timeout(const Duration(seconds: 15));
    // 400: not yet confirmed. Anything else is an answer.
    if (response.statusCode == 400 || response.statusCode == 429) return null;
    _check('trakt', response);
    return _tokensFrom(response.body);
  }

  static Map<String, Object?> _tokensFrom(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['access_token'] is! String) {
      throw const FormatException('Trakt lieferte kein Token.');
    }
    final expiresIn = (decoded['expires_in'] as num?)?.toInt() ?? 7776000;
    return {
      'access_token': decoded['access_token'],
      if (decoded['refresh_token'] is String)
        'refresh_token': decoded['refresh_token'],
      'expires_at': DateTime.now()
          .add(Duration(seconds: expiresIn))
          .millisecondsSinceEpoch,
    };
  }

  Future<String> _access() async {
    final expires = (tokens['expires_at'] as num?)?.toInt() ?? 0;
    final refresh = tokens['refresh_token'];
    if (DateTime.now().millisecondsSinceEpoch < expires - 86400000 ||
        refresh is! String) {
      return tokens['access_token'] as String? ?? '';
    }
    final response = await _client
        .post(
          Uri.https('api.trakt.tv', '/oauth/token'),
          headers: _headers(clientId),
          body: jsonEncode({
            'refresh_token': refresh,
            'client_id': clientId,
            'client_secret': clientSecret,
            'redirect_uri': 'urn:ietf:wg:oauth:2.0:oob',
            'grant_type': 'refresh_token',
          }),
        )
        .timeout(const Duration(seconds: 15));
    _check(service, response);
    tokens = _tokensFrom(response.body);
    await onTokens(tokens);
    return tokens['access_token'] as String;
  }

  static Map<String, Object?> _traktIds(Map<String, String> ids) => {
    'tmdb': ?int.tryParse(ids['tmdb'] ?? ''),
    'imdb': ?ids['imdb'],
    'tvdb': ?int.tryParse(ids['tvdb'] ?? ''),
  };

  @override
  Future<void> send(TrackingUpdate update) async {
    final ids = _traktIds(update.ids);
    if (ids.isEmpty) return;
    final at = (update.watchedAt ?? DateTime.now()).toUtc().toIso8601String();
    final Map<String, Object?> body;
    if (update.media == 'movie') {
      if (!update.completed) return;
      body = {
        'movies': [
          {'ids': ids, 'watched_at': at},
        ],
      };
    } else {
      if (update.episodes.isEmpty) return;
      final seasons = <int, List<int>>{};
      for (final episode in update.episodes) {
        (seasons[episode.season] ??= []).add(episode.episode);
      }
      body = {
        'shows': [
          {
            'ids': ids,
            'seasons': [
              for (final entry in seasons.entries)
                {
                  'number': entry.key,
                  'episodes': [
                    for (final number in entry.value)
                      {'number': number, 'watched_at': at},
                  ],
                },
            ],
          },
        ],
      };
    }
    final response = await _client
        .post(
          Uri.https('api.trakt.tv', '/sync/history'),
          headers: _headers(clientId, await _access()),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    _check(service, response);
  }
}
