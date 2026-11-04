import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../app/fundus_log.dart';
import '../app/offline_conditions.dart';
import '../metadata/metadata_http_client.dart';
import '../metadata/podcast_feed.dart';
import 'library_controller.dart';

/// What one round of checking the subscriptions did.
final class PodcastCheckReport {
  const PodcastCheckReport({
    this.checked = 0,
    this.downloaded = 0,
    this.failed = 0,
    this.skippedReason,
  });

  final int checked;
  final int downloaded;
  final int failed;

  /// Set when nothing was checked at all, saying why.
  final String? skippedReason;
}

/// Fetches the new episodes of subscribed podcasts into their folders.
///
/// Only what came out after subscribing counts as new: subscribing to a show
/// with six hundred episodes must not start six hundred downloads. Every
/// address, the feed's and each episode's, has to be HTTPS, redirects
/// included. On a phone episodes wait for Wi-Fi.
final class PodcastSubscriptionController extends ChangeNotifier {
  PodcastSubscriptionController({
    required this.library,
    http.Client Function()? client,
    Future<bool> Function()? mayDownload,
    this.interval = const Duration(hours: 6),
  }) : _client = client ?? createMetadataHttpClient,
       _mayDownload = mayDownload ?? _wifiOrDesktop;

  final LibraryController library;
  final http.Client Function() _client;
  final Future<bool> Function() _mayDownload;
  final Duration interval;

  /// Larger is no episode; it is a mistake or an attack on the disk.
  static const maximumEpisodeBytes = 2 * 1024 * 1024 * 1024;
  static const maximumPerCheck = 5;
  static const _maximumRedirects = 5;

  Timer? _timer;
  Timer? _firstCheck;
  bool _checking = false;
  bool _disposed = false;
  PodcastCheckReport? _last;

  bool get isChecking => _checking;
  PodcastCheckReport? get lastReport => _last;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(checkNow()));
    // Not right at start-up: the library is still opening then.
    _firstCheck ??= Timer(const Duration(minutes: 2), () {
      if (!_disposed) unawaited(checkNow());
    });
  }

  static Future<bool> _wifiOrDesktop() async {
    if (!Platform.isAndroid) return true;
    return (await readOfflineConditions()).wifi == true;
  }

  Future<PodcastCheckReport> checkNow() async {
    final vault = library.library;
    if (_checking || vault == null || vault.isReadOnly) {
      return const PodcastCheckReport();
    }
    final subscriptions = vault.podcastSubscriptions();
    if (subscriptions.isEmpty) return const PodcastCheckReport();
    if (!await _mayDownload()) {
      return _last = const PodcastCheckReport(
        skippedReason: 'Neue Folgen werden nur im WLAN geladen.',
      );
    }
    _checking = true;
    _notify();
    final client = _client();
    var checked = 0;
    var downloaded = 0;
    var failed = 0;
    try {
      for (final subscription in subscriptions) {
        if (_disposed || !identical(library.library, vault)) break;
        checked++;
        try {
          downloaded += await _check(vault, subscription, client);
        } on Object catch (error) {
          failed++;
          vault.recordPodcastCheck(
            workId: subscription.workId,
            checkedAt: DateTime.now().toUtc(),
            error: _describe(error),
            seen: subscription.seen,
          );
          FundusLog.instance.warn('podcast.check.failed', {
            'error': error.runtimeType.toString(),
          });
        }
      }
    } finally {
      client.close();
      _checking = false;
    }
    if (downloaded > 0) library.refresh();
    _last = PodcastCheckReport(
      checked: checked,
      downloaded: downloaded,
      failed: failed,
    );
    _notify();
    return _last!;
  }

  Future<int> _check(
    FundusLibrary vault,
    PodcastSubscription subscription,
    http.Client client,
  ) async {
    final feedUri = Uri.parse(subscription.feedUrl);
    if (!feedUri.isScheme('https')) {
      throw const FormatException('Der Feed ist nicht per https erreichbar.');
    }
    final episodes = await PodcastFeed(client: client).read(feedUri.toString());
    final seen = {...subscription.seen};
    final fresh = <FeedEpisode>[];
    for (final episode in episodes) {
      final published = episode.publishedAt;
      if (seen.contains(episode.identity)) continue;
      // The back catalogue and anything undated are only remembered.
      if (published == null || published.isBefore(subscription.subscribedAt)) {
        seen.add(episode.identity);
        continue;
      }
      fresh.add(episode);
    }
    fresh.sort((a, b) => a.publishedAt!.compareTo(b.publishedAt!));
    final directory = vault.workDirectoryPath(subscription.workId);
    if (directory == null || directory.isEmpty) {
      throw const FileSystemException('Der Ordner des Podcasts fehlt.');
    }
    var downloaded = 0;
    String? failure;
    final written = <({String name, FeedEpisode episode})>[];
    for (final episode in fresh.take(maximumPerCheck)) {
      final url = episode.enclosureUrl;
      if (url == null || !url.isScheme('https')) {
        // Nothing to fetch, or nothing to fetch safely.
        seen.add(episode.identity);
        continue;
      }
      try {
        final name = await _download(
          client,
          url,
          Directory(directory),
          episode,
        );
        seen.add(episode.identity);
        written.add((name: name, episode: episode));
        downloaded++;
      } on Object catch (error) {
        // One broken episode must not cost the others, and an episode that
        // failed is tried again next time rather than marked as done.
        failure ??= _describe(error);
      }
    }
    vault.recordPodcastCheck(
      workId: subscription.workId,
      checkedAt: DateTime.now().toUtc(),
      error: failure,
      seen: seen,
    );
    if (written.isNotEmpty) {
      await _index(vault, subscription.workId, written);
    }
    return downloaded;
  }

  /// Streams one episode into the folder, under a name it cannot escape.
  Future<String> _download(
    http.Client client,
    Uri url,
    Directory directory,
    FeedEpisode episode,
  ) async {
    var target = url;
    http.StreamedResponse? response;
    for (var hop = 0; hop <= _maximumRedirects; hop++) {
      final request = http.Request('GET', target)
        ..followRedirects = false
        ..headers['user-agent'] = metadataUserAgent;
      response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.isRedirect ||
          const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        await response.stream.drain<void>();
        final location = response.headers['location'];
        final next = location == null ? null : target.resolve(location);
        if (next == null || !next.isScheme('https')) {
          throw const FormatException(
            'Die Folge wird über eine unsichere Adresse ausgeliefert.',
          );
        }
        target = next;
        continue;
      }
      break;
    }
    if (response == null || response.statusCode != 200) {
      await response?.stream.drain<void>();
      throw HttpException('Folge nicht geladen (${response?.statusCode}).');
    }
    final declared = response.contentLength ?? episode.enclosureBytes;
    if (declared != null && declared > maximumEpisodeBytes) {
      await response.stream.drain<void>();
      throw const FormatException('Die Folge ist unplausibel groß.');
    }
    final name = _uniqueName(directory, episodeFileName(episode, target));
    final file = File(p.join(directory.path, name));
    final partial = File('${file.path}.part');
    final sink = partial.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > maximumEpisodeBytes) {
          throw const FormatException('Die Folge ist unplausibel groß.');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      await partial.rename(file.path);
    } on Object {
      await sink.close().catchError((Object _) {});
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    return name;
  }

  /// Makes the new files part of the work and gives them the feed's words.
  Future<void> _index(
    FundusLibrary vault,
    String workId,
    List<({String name, FeedEpisode episode})> written,
  ) async {
    final work = vault.workSummary(workId);
    if (work == null) return;
    await library.scan(subtree: work.sourcePath);
    final files = {
      for (final file in vault.contentFiles(workId))
        file.filename.toLowerCase(): file.fileId,
    };
    for (final entry in written) {
      final fileId = files[entry.name.toLowerCase()];
      if (fileId == null) continue;
      vault.setFileDetail(
        workId: workId,
        fileId: fileId,
        title: entry.episode.title,
        description: entry.episode.description,
        publishedAt: entry.episode.publishedAt,
      );
    }
  }

  /// A file name for an episode that stays inside its folder.
  @visibleForTesting
  static String episodeFileName(FeedEpisode episode, Uri url) {
    final fromUrl = Uri.decodeComponent(url.pathSegments.lastOrNull ?? '');
    final extension = p.extension(fromUrl).toLowerCase();
    const audio = {'.mp3', '.m4a', '.m4b', '.aac', '.ogg', '.opus', '.mp4'};
    final suffix = audio.contains(extension)
        ? extension
        : switch (episode.enclosureType) {
            'audio/mp4' || 'audio/x-m4a' => '.m4a',
            'audio/ogg' => '.ogg',
            'video/mp4' => '.mp4',
            _ => '.mp3',
          };
    final date = episode.publishedAt;
    final prefix = date == null
        ? ''
        : '${date.year.toString().padLeft(4, '0')}-'
              '${date.month.toString().padLeft(2, '0')}-'
              '${date.day.toString().padLeft(2, '0')} - ';
    var stem = '$prefix${episode.title}'
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '')
        .trim();
    if (stem.isEmpty) stem = 'Folge';
    if (stem.length > 150) stem = stem.substring(0, 150).trim();
    return '$stem$suffix';
  }

  static String _uniqueName(Directory directory, String name) {
    var candidate = name;
    var counter = 2;
    while (File(p.join(directory.path, candidate)).existsSync()) {
      candidate =
          '${p.basenameWithoutExtension(name)} ($counter)${p.extension(name)}';
      counter++;
    }
    return candidate;
  }

  static String _describe(Object error) => switch (error) {
    FormatException(:final message) => message,
    HttpException(:final message) => message,
    TimeoutException() => 'Der Feed hat nicht rechtzeitig geantwortet.',
    _ => 'Der Feed ließ sich nicht abrufen.',
  };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _firstCheck?.cancel();
    super.dispose();
  }
}
