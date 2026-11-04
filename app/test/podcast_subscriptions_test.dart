import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/podcast_subscriptions.dart';
import 'package:fundus/metadata/podcast_feed.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A subscribed show gets its new episodes; the back catalogue, unsafe
/// addresses and repeated checks do not turn into downloads.
void main() {
  late Directory root;
  late LibraryController library;

  String rfc822(DateTime value) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final utc = value.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${days[utc.weekday - 1]}, ${two(utc.day)} ${months[utc.month - 1]} '
        '${utc.year} ${two(utc.hour)}:${two(utc.minute)}:00 +0000';
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-podcasts-');
    final show = Directory('${root.path}/Podcasts/Sender/Die Sendung')
      ..createSync(recursive: true);
    File('${show.path}/001 - Alt.mp3').writeAsBytesSync(List.filled(16, 1));
    library = LibraryController();
    await library.open(root, createIfMissing: true);
    await library.scan();
    final work = library.library!.listWorks().single;
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
      externalIds: const {'feed': 'https://feed.example.org/show.xml'},
    );
    library.library!.subscribePodcast(work.id);
  });

  tearDown(() async {
    await library.library?.flushSidecarWrites();
    library.dispose();
    await root.delete(recursive: true);
  });

  test('new episodes arrive, old and unsafe ones do not', () async {
    final soon = DateTime.now().add(const Duration(days: 1));
    final feed =
        '''<?xml version="1.0"?>
<rss version="2.0"><channel><title>Die Sendung</title>
<item><title>Folge 1: Alt</title><guid>ep-1</guid>
  <pubDate>Mon, 06 Jan 2020 05:00:00 +0000</pubDate>
  <enclosure url="https://cdn.example.org/ep1.mp3" type="audio/mpeg"/></item>
<item><title>Folge 2: Neu/Spezial</title><guid>ep-2</guid>
  <pubDate>${rfc822(soon)}</pubDate>
  <description>&lt;p&gt;Worum es geht.&lt;/p&gt;</description>
  <enclosure url="https://cdn.example.org/ep2.mp3" type="audio/mpeg"/></item>
<item><title>Folge 3: Unsicher</title><guid>ep-3</guid>
  <pubDate>${rfc822(soon)}</pubDate>
  <enclosure url="https://cdn.example.org/ep3.mp3" type="audio/mpeg"/></item>
</channel></rss>''';
    final requested = <String>[];
    final client = MockClient.streaming((request, _) async {
      requested.add(request.url.toString());
      http.StreamedResponse respond(
        int status,
        List<int> body, {
        Map<String, String> headers = const {},
      }) => http.StreamedResponse(
        Stream.value(body),
        status,
        headers: headers,
        contentLength: body.length,
      );
      switch (request.url.toString()) {
        case 'https://feed.example.org/show.xml':
          return respond(200, utf8.encode(feed));
        case 'https://cdn.example.org/ep2.mp3':
          return respond(
            302,
            const [],
            headers: const {'location': 'https://mirror.example.org/ep2.mp3'},
          );
        case 'https://mirror.example.org/ep2.mp3':
          return respond(200, List.filled(32, 7));
        case 'https://cdn.example.org/ep3.mp3':
          // A redirect down to plain http is refused.
          return respond(
            302,
            const [],
            headers: const {'location': 'http://evil.example.org/ep3.mp3'},
          );
      }
      return respond(404, const []);
    });
    final podcasts = PodcastSubscriptionController(
      library: library,
      client: () => client,
      mayDownload: () async => true,
    );
    addTearDown(podcasts.dispose);

    final report = await podcasts.checkNow();
    expect(report.checked, 1);
    expect(report.downloaded, 1);
    expect(requested, isNot(contains('https://cdn.example.org/ep1.mp3')));
    expect(requested, isNot(contains('http://evil.example.org/ep3.mp3')));

    final vault = library.library!;
    final work = vault.listWorks().single;
    final files = vault.contentFiles(work.id).map((file) => file.filename);
    expect(files, hasLength(2));
    final fresh = files.firstWhere((name) => name.contains('Neu'));
    expect(fresh, isNot(contains('/')));
    expect(fresh, endsWith('.mp3'));
    final subscription = vault.podcastSubscriptions().single;
    expect(subscription.seen, containsAll(['ep-1', 'ep-2']));
    expect(subscription.seen, isNot(contains('ep-3')));
    expect(subscription.lastError, contains('unsichere'));

    // The second check fetches nothing that is already there.
    requested.clear();
    final again = await podcasts.checkNow();
    expect(again.downloaded, 0);
    expect(requested, isNot(contains('https://mirror.example.org/ep2.mp3')));
  });

  test('episode names cannot leave their folder', () {
    final name = PodcastSubscriptionController.episodeFileName(
      FeedEpisode(
        title: '../../etc/passwd: "Folge" *1*',
        publishedAt: DateTime.utc(2026, 11, 3),
      ),
      Uri.parse('https://cdn.example.org/download?id=1'),
    );
    expect(name, isNot(contains('/')));
    expect(name, isNot(startsWith('.')));
    expect(name, startsWith('2026-11-03 - '));
    expect(name, endsWith('.mp3'));
  });
}
