import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/metadata/podcast_feed.dart';

/// Was ein Ordner voller MP3s nicht sagen kann: worum es in einer Folge geht.
void main() {
  const feed = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title>Stay Forever</title>
    <item>
      <title>SF 100: Monkey Island</title>
      <description><![CDATA[<p>Ein Spiel &amp; ein Affe.</p><p>Zwei Stunden.</p>]]></description>
      <pubDate>Tue, 02 Sep 2025 05:00:00 +0000</pubDate>
      <enclosure url="https://stayforever.de/media/sf100.mp3" type="audio/mpeg"/>
    </item>
    <item>
      <title>SF 101: Zak McKracken</title>
      <itunes:summary>Aliens in Seattle.</itunes:summary>
      <pubDate>Tue, 16 Sep 2025 05:00:00 +0000</pubDate>
    </item>
  </channel>
</rss>
''';

  test('Titel, Text und Datum kommen an', () {
    final episodes = parseFeed(feed);

    expect(episodes, hasLength(2));
    expect(episodes.first.title, 'SF 100: Monkey Island');
    // HTML im Text ist Verpackung, nicht Inhalt.
    expect(
      episodes.first.description,
      'Ein Spiel & ein Affe.\n\nZwei Stunden.',
    );
    expect(episodes.first.publishedAt, DateTime.utc(2025, 9, 2, 5));
    expect(episodes.first.fileName, 'sf100.mp3');
    // itunes:summary zählt genauso.
    expect(episodes[1].description, 'Aliens in Seattle.');
  });

  test('ein kaputter Feed kostet keine Ausnahme', () {
    expect(parseFeed('das ist kein XML'), isEmpty);
  });

  test('die Datei aus dem Enclosure schlägt den Titel', () {
    final episodes = parseFeed(feed);
    final matched = matchEpisodes(episodes, const [
      EpisodeFile(fileId: 'file-a', name: 'sf100.mp3'),
      EpisodeFile(fileId: 'file-b', name: 'SF 100 Monkey Island.mp3'),
    ]);

    expect(matched[0], 'file-a');
  });

  test('ein anders benannter Mitschnitt wird über die Nummer gefunden', () {
    // Der Feed sagt „SF 100: Monkey Island", auf der Platte liegt
    // „SF_100.mp3" — kein Wort davon stimmt überein, die Nummer schon.
    final matched = matchEpisodes(parseFeed(feed), const [
      EpisodeFile(fileId: 'a', name: 'SF_100.mp3'),
      EpisodeFile(fileId: 'b', name: 'SF_101.mp3'),
    ]);

    expect(matched[0], 'a');
    expect(matched[1], 'b');
  });

  test('ein enthaltener Titel reicht', () {
    final matched = matchEpisodes(parseFeed(feed), const [
      EpisodeFile(
        fileId: 'a',
        name: 'Stay Forever - SF 100 Monkey Island (2025).mp3',
      ),
    ]);

    expect(matched[0], 'a');
  });

  test('eine Nummer, die zweimal vorkommt, entscheidet nichts', () {
    final matched = matchEpisodes(parseFeed(feed), const [
      EpisodeFile(fileId: 'a', name: 'Teil 100 von A.mp3'),
      EpisodeFile(fileId: 'b', name: 'Teil 100 von B.mp3'),
    ]);

    expect(matched, isEmpty);
  });

  test('eine Jahreszahl ist keine Folgennummer', () {
    expect(episodeNumberIn('Rückblick 1999.mp3'), isNull);
    expect(episodeNumberIn('SF 100.mp3'), 100);
    expect(episodeNumberIn('Ohne Nummer.mp3'), isNull);
  });

  test('keine Datei bekommt zwei Folgen', () {
    final matched = matchEpisodes(parseFeed(feed), const [
      EpisodeFile(fileId: 'nur-eine', name: 'SF 100.mp3'),
    ]);

    expect(matched.values.toSet(), hasLength(matched.length));
  });
}
