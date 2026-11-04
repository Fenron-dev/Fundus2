import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

import '../app/app_settings.dart';
import '../app/fundus_log.dart';
import '../metadata/metadata_http_client.dart';
import '../metadata/tracking_services.dart';
import 'library_controller.dart';
import 'work_view.dart';

/// Tells AniList, MyAnimeList and Trakt what was watched and read.
///
/// Opt-in per service, and only from the moment a service was connected: an
/// old library does not flood a fresh account. Protected works are never
/// reported, whatever the protection mode says. Updates wait in an outbox
/// until the service answers, so a phone without signal loses nothing.
final class TrackingController extends ChangeNotifier {
  TrackingController({
    required this.settings,
    required this.library,
    http.Client Function()? client,
    this.interval = const Duration(minutes: 10),
  }) : _client = client ?? createMetadataHttpClient;

  final AppSettings settings;
  final LibraryController library;
  final http.Client Function() _client;
  final Duration interval;

  static const services = ['anilist', 'mal', 'trakt'];
  static const _maximumAttempts = 8;
  static const _maximumOutbox = 200;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  String? _lastProblem;

  String? get lastProblem => _lastProblem;
  bool get isRunning => _running;

  bool isConnected(String service) {
    final credentials = settings.trackingCredentials[service];
    return switch (service) {
      'anilist' => credentials?['token'] is String,
      'mal' => credentials?['access_token'] is String,
      'trakt' => credentials?['access_token'] is String,
      _ => false,
    };
  }

  int get pending => _outbox().length;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(reconcile()));
  }

  /// Stores a service's login and starts counting from now.
  Future<void> connect(String service, Map<String, Object?> credentials) async {
    await settings.setTrackingCredentials(service, credentials);
    final state = {...settings.trackingState};
    final since = Map<String, Object?>.from(state['since'] as Map? ?? const {});
    since[service] = DateTime.now().millisecondsSinceEpoch;
    state['since'] = since;
    await settings.setTrackingState(state);
    _notify();
  }

  Future<void> disconnect(String service) async {
    await settings.setTrackingCredentials(service, null);
    final state = {...settings.trackingState};
    state['outbox'] = [
      for (final entry in _outbox())
        if (entry.service != service) entry.toJson(),
    ];
    await settings.setTrackingState(state);
    _notify();
  }

  List<TrackingUpdate> _outbox() => [
    if (settings.trackingState['outbox'] case final List list)
      for (final entry in list) ?TrackingUpdate.fromJson(entry),
  ];

  ProgressTracker? _tracker(String service, http.Client client) {
    final credentials = settings.trackingCredentials[service];
    if (credentials == null || !isConnected(service)) return null;
    Future<void> save(Map<String, Object?> tokens) =>
        settings.setTrackingCredentials(service, {...credentials, ...tokens});
    return switch (service) {
      'anilist' => AniListTracker(
        token: credentials['token'] as String,
        client: client,
      ),
      'mal' => MalTracker(
        clientId: credentials['client_id'] as String? ?? settings.malClientId,
        tokens: credentials,
        onTokens: save,
        client: client,
      ),
      'trakt' => TraktTracker(
        clientId: credentials['client_id'] as String? ?? '',
        clientSecret: credentials['client_secret'] as String? ?? '',
        tokens: credentials,
        onTokens: save,
        client: client,
      ),
      _ => null,
    };
  }

  /// Looks for changed progress and sends what is waiting.
  Future<void> reconcile() async {
    final vault = library.library;
    final connected = services.where(isConnected).toList();
    if (_running || vault == null || connected.isEmpty) return;
    _running = true;
    final client = _client();
    try {
      final state = {...settings.trackingState};
      final reported = Map<String, Object?>.from(
        state['reported'] as Map? ?? const {},
      );
      final since = Map<String, Object?>.from(
        state['since'] as Map? ?? const {},
      );
      final outbox = {for (final update in _outbox()) update.key: update};
      final checkedAt = DateTime.now().millisecondsSinceEpoch;
      final lastCheck = (state['checked_at'] as num?)?.toInt() ?? 0;
      for (final work in library.works) {
        final listened = work.summary.lastListenedAt?.millisecondsSinceEpoch;
        // Never a protected work, and only what moved since the last look.
        if (work.summary.isHhh || listened == null || listened <= lastCheck) {
          continue;
        }
        for (final service in connected) {
          final from = (since[service] as num?)?.toInt() ?? checkedAt;
          if (listened < from) continue;
          final update = _updateFor(service, work, vault, reported);
          if (update != null) outbox[update.key] = update;
        }
      }
      String? problem;
      final remaining = <Map<String, Object?>>[];
      final attempts = Map<String, Object?>.from(
        state['attempts'] as Map? ?? const {},
      );
      for (final update in outbox.values) {
        final tracker = _tracker(update.service, client);
        if (tracker == null) continue;
        try {
          await tracker.send(update);
          reported[update.key] = _mark(update, reported[update.key]);
          attempts.remove(update.key);
        } on TrackingAuthException {
          problem =
              'Die Anmeldung bei ${_label(update.service)} ist '
              'abgelaufen. Bitte neu verbinden.';
          remaining.add(update.toJson());
        } on Object catch (error) {
          final tries = ((attempts[update.key] as num?)?.toInt() ?? 0) + 1;
          attempts[update.key] = tries;
          if (tries < _maximumAttempts) remaining.add(update.toJson());
          problem ??= '${_label(update.service)} ist gerade nicht erreichbar.';
          FundusLog.instance.warn('tracking.send.failed', {
            'service': update.service,
            'error': error.runtimeType.toString(),
          });
        }
      }
      state
        ..['reported'] = reported
        ..['outbox'] = remaining.length > _maximumOutbox
            ? remaining.sublist(remaining.length - _maximumOutbox)
            : remaining
        ..['attempts'] = attempts
        ..['checked_at'] = checkedAt;
      await settings.setTrackingState(state);
      _lastProblem = problem;
    } finally {
      client.close();
      _running = false;
      _notify();
    }
  }

  /// What a service should now know about a work, or null when it knows.
  TrackingUpdate? _updateFor(
    String service,
    WorkView work,
    FundusLibrary vault,
    Map<String, Object?> reported,
  ) {
    final ids = work.summary.externalIds;
    final kind = work.kind;
    final video = const {'anime', 'tv', 'series', 'movie'}.contains(kind);
    final reading = const {
      'manga',
      'comic',
      'webnovel',
      'light_novel',
      'novel',
      'ebook',
    }.contains(kind);
    if (!video && !reading) return null;
    final files = vault.contentFiles(work.id);
    final finished = vault.finishedFiles(work.id);
    final workDone = vault.loadProgress(work.id)?.finished ?? false;
    final completed =
        workDone || (files.isNotEmpty && finished.length >= files.length);
    final progress = files.length <= 1 ? (completed ? 1 : 0) : finished.length;
    final key = '$service:${work.id}';
    switch (service) {
      case 'anilist' || 'mal':
        if (ids[service] == null || (progress == 0 && !completed)) return null;
        final mark = '$progress/$completed';
        if (reported[key] == mark) return null;
        return TrackingUpdate(
          service: service,
          workId: work.id,
          media: video ? 'anime' : 'manga',
          ids: ids,
          progress: progress,
          completed: completed,
        );
      case 'trakt':
        if (!video ||
            (ids['tmdb'] == null &&
                ids['imdb'] == null &&
                ids['tvdb'] == null)) {
          return null;
        }
        if (kind == 'movie') {
          if (!completed || reported[key] == 'watched') return null;
          return TrackingUpdate(
            service: service,
            workId: work.id,
            media: 'movie',
            ids: ids,
            completed: true,
            watchedAt: work.summary.lastListenedAt,
          );
        }
        final told = {
          if (reported[key] case final List list) ...list.whereType<String>(),
        };
        final episodes = [
          for (final track in vault.playbackTracks(work.id))
            if (finished.contains(track.fileId) &&
                track.episode != null &&
                !told.contains(
                  '${track.episode!.season}x${track.episode!.episode}',
                ))
              (season: track.episode!.season, episode: track.episode!.episode),
        ];
        if (episodes.isEmpty) return null;
        return TrackingUpdate(
          service: service,
          workId: work.id,
          media: 'show',
          ids: ids,
          episodes: episodes,
          watchedAt: work.summary.lastListenedAt,
        );
    }
    return null;
  }

  /// What is remembered as told, so the next round sends only what is new.
  static Object _mark(TrackingUpdate update, Object? previous) =>
      switch (update.service) {
        'trakt' when update.media == 'movie' => 'watched',
        'trakt' => [
          if (previous case final List list) ...list.whereType<String>(),
          for (final episode in update.episodes)
            '${episode.season}x${episode.episode}',
        ],
        _ => '${update.progress}/${update.completed}',
      };

  static String _label(String service) => switch (service) {
    'anilist' => 'AniList',
    'mal' => 'MyAnimeList',
    'trakt' => 'Trakt',
    _ => service,
  };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
