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
    final files = {
      normaliseEpisodeName('sf100.mp3'): 'file-a',
      normaliseEpisodeName('SF 100 Monkey Island'): 'file-b',
    };

    expect(matchEpisode(episodes.first, files), 'file-a');
  });

  test('sonst wird über den Titel zugeordnet', () {
    final episodes = parseFeed(feed);
    final files = {
      normaliseEpisodeName('SF 101 - Zak McKracken.mp3'): 'file-c',
    };

    expect(matchEpisode(episodes[1], files), 'file-c');
  });

  test('was nirgends passt, bleibt ohne Text', () {
    final episodes = parseFeed(feed);

    expect(matchEpisode(episodes.first, const {}), isNull);
  });
}
