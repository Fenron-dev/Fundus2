import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/tracking_controller.dart';
import 'package:fundus/metadata/tracking_services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// What was watched goes to the services somebody connected — from then on,
/// once, and never for a protected work.
void main() {
  test('updates survive the outbox', () {
    const update = TrackingUpdate(
      service: 'trakt',
      workId: 'w1',
      media: 'show',
      ids: {'tmdb': '1399'},
      episodes: [(season: 1, episode: 2)],
    );
    final copy = TrackingUpdate.fromJson(
      jsonDecode(jsonEncode(update.toJson())),
    )!;
    expect(copy.key, 'trakt:w1');
    expect(copy.episodes.single, (season: 1, episode: 2));
    expect(copy.ids, {'tmdb': '1399'});
  });

  test('a pasted MyAnimeList address only counts with its own state', () {
    const address =
        'https://example.org/callback?code=abcdefghijklmnopqrstuvwxyz&state=s1';
    expect(MalTracker.codeFrom(address, state: 's1'), startsWith('abcdef'));
    expect(MalTracker.codeFrom(address, state: 'other'), isNull);
  });

  group('reconcile', () {
    late Directory root;
    late LibraryController library;
    late AppSettings settings;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-tracking-');
      for (final title in ['Offen', 'Geheim']) {
        final show = Directory('${root.path}/Anime/$title')
          ..createSync(recursive: true);
        File('${show.path}/$title - 01.mkv').writeAsBytesSync([1]);
        File('${show.path}/$title - 02.mkv').writeAsBytesSync([2]);
      }
      library = LibraryController();
      await library.open(root, createIfMissing: true);
      await library.scan();
      for (final work in library.library!.listWorks()) {
        await library.library!.updateWorkMetadata(
          workId: work.id,
          title: work.title,
          authors: work.authors,
          subtitle: work.subtitle,
          series: work.series,
          seriesSequence: work.seriesSequence,
          narrators: work.narrators,
          language: work.language,
          description: work.description,
          publisher: work.publisher,
          publishedYear: work.publishedYear,
          externalIds: const {'anilist': '21'},
          contentSensitivity: work.title == 'Geheim' ? 'adult_explicit' : null,
        );
      }
      settings = AppSettings.inMemory();
    });

    tearDown(() async {
      await library.library?.flushSidecarWrites();
      library.dispose();
      await root.delete(recursive: true);
    });

    Future<void> watchFirstEpisode(String title) async {
      final vault = library.library!;
      final work = vault.listWorks().firstWhere((work) => work.title == title);
      final first = vault.playbackTracks(work.id).first;
      vault.setFileFinished(
        workId: work.id,
        fileId: first.fileId,
        finished: true,
      );
      vault.saveProgress(
        workId: work.id,
        fileId: first.fileId,
        position: const Duration(minutes: 20),
        deviceId: 'phone',
      );
      library.refresh();
    }

    test('one episode watched is told once, the protected one never', () async {
      final sent = <Map<String, Object?>>[];
      final tracking = TrackingController(
        settings: settings,
        library: library,
        client: () => MockClient((request) async {
          sent.add(jsonDecode(request.body) as Map<String, Object?>);
          expect(request.headers['authorization'], 'Bearer anilist-token');
          return http.Response('{"data":{"SaveMediaListEntry":{"id":1}}}', 200);
        }),
      );
      addTearDown(tracking.dispose);
      await tracking.connect('anilist', {'token': 'anilist-token'});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await watchFirstEpisode('Offen');
      await watchFirstEpisode('Geheim');

      await tracking.reconcile();
      expect(sent, hasLength(1));
      final variables = sent.single['variables'] as Map;
      expect(variables['mediaId'], 21);
      expect(variables['progress'], 1);
      expect(variables['status'], 'CURRENT');

      await tracking.reconcile();
      expect(sent, hasLength(1));
    });

    test('without a connection the update waits', () async {
      var online = false;
      final tracking = TrackingController(
        settings: settings,
        library: library,
        client: () => MockClient((request) async {
          if (!online) throw http.ClientException('offline');
          return http.Response('{}', 200);
        }),
      );
      addTearDown(tracking.dispose);
      await tracking.connect('anilist', {'token': 'anilist-token'});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await watchFirstEpisode('Offen');

      await tracking.reconcile();
      expect(tracking.pending, 1);
      expect(tracking.lastProblem, contains('AniList'));

      online = true;
      await tracking.reconcile();
      expect(tracking.pending, 0);
    });
  });
}
