import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('schema 27 migrates to podcast subscriptions', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-db-v27-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.db');
    final current = FundusDatabase.openFile(file);
    current.rawExecute('DROP TABLE podcast_subscriptions');
    current.rawExecute('PRAGMA user_version = 27');
    current.close();

    final migrated = FundusDatabase.openFile(file);
    addTearDown(migrated.close);
    expect(migrated.userVersion, FundusDatabase.schemaVersion);
    expect(migrated.tableExists('podcast_subscriptions'), isTrue);
    expect(migrated.podcastSubscriptions(), isEmpty);
  });

  test('only a show with an https feed can be subscribed', () async {
    final root = await Directory.systemTemp.createTemp('fundus-podcast-');
    addTearDown(() => root.delete(recursive: true));
    final show = Directory('${root.path}/Podcasts/Sender/Die Sendung')
      ..createSync(recursive: true);
    File('${show.path}/001.mp3').writeAsBytesSync([1, 2, 3]);
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();
    final work = library.listWorks().single;

    expect(
      () => library.subscribePodcast(work.id),
      throwsFormatException,
      reason: 'no feed at all',
    );
    Future<void> feed(String url) => library.updateWorkMetadata(
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
      externalIds: {'feed': url},
    );
    await feed('http://example.org/feed.xml');
    expect(() => library.subscribePodcast(work.id), throwsFormatException);
    expect(library.podcastSubscriptions(), isEmpty);

    await feed('https://example.org/feed.xml');
    library.subscribePodcast(work.id);
    final subscription = library.podcastSubscriptions().single;
    expect(subscription.feedUrl, 'https://example.org/feed.xml');
    expect(subscription.title, work.title);

    library.recordPodcastCheck(
      workId: work.id,
      checkedAt: DateTime.utc(2026, 11, 1),
      seen: {'episode-1', 'episode-2'},
    );
    expect(library.podcastSubscriptions().single.seen, {
      'episode-1',
      'episode-2',
    });
    library.unsubscribePodcast(work.id);
    expect(library.podcastSubscriptions(), isEmpty);
  });
}
