import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Libraries that come from Kodi, Jellyfin or Calibre already carry their
/// metadata in files beside the media. Fundus reads them instead of asking a
/// person to type it all in again.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-sidecars-');
  });

  tearDown(() => root.delete(recursive: true));

  group('NFO', () {
    test('a Kodi movie.nfo gives title, plot, ids and genres', () async {
      final file = File('${root.path}/movie.nfo')
        ..writeAsStringSync('''﻿<?xml version="1.0" encoding="UTF-8"?>
<movie>
  <title>Nordwind</title>
  <originaltitle>North Wind</originaltitle>
  <plot>Ein Sturm zieht auf.</plot>
  <year>2019</year>
  <genre>Drama / Thriller</genre>
  <tag>Lieblingsfilm</tag>
  <director>Ada Regie</director>
  <studio>Nordfilm</studio>
  <set><name>Wetter-Reihe</name></set>
  <ratings><rating name="imdb" default="true"><value>7.4</value></rating></ratings>
  <uniqueid type="imdb" default="true">tt1234567</uniqueid>
  <uniqueid type="tmdb">98765</uniqueid>
</movie>''');
      final metadata = (await const NfoMetadataReader().read(file))!;
      expect(metadata.title, 'Nordwind');
      expect(metadata.alternateTitles, ['North Wind']);
      expect(metadata.description, 'Ein Sturm zieht auf.');
      expect(metadata.publishedYear, 2019);
      expect(metadata.genres, ['Drama', 'Thriller']);
      expect(metadata.tags, ['Lieblingsfilm']);
      expect(metadata.authors, ['Ada Regie']);
      expect(metadata.publisher, 'Nordfilm');
      expect(metadata.series, 'Wetter-Reihe');
      expect(metadata.externalRating, 7.4);
      expect(metadata.sourceLinks, {'imdb': 'tt1234567', 'tmdb': '98765'});
    });

    test('a release note still names its IMDb link', () async {
      final file = File('${root.path}/release.nfo')
        ..writeAsStringSync(
          '*** TEAM ***\nhttps://www.imdb.com/title/tt7654321/\n',
        );
      final metadata = (await const NfoMetadataReader().read(file))!;
      expect(metadata.title, isNull);
      expect(metadata.sourceLinks, {'imdb': 'tt7654321'});
    });

    test('XML with entity tricks is refused, not expanded', () async {
      final file = File('${root.path}/evil.nfo')
        ..writeAsStringSync('''<?xml version="1.0"?>
<!DOCTYPE movie [<!ENTITY secret SYSTEM "file:///etc/passwd">]>
<movie><title>&secret;</title></movie>''');
      final metadata = await const NfoMetadataReader().read(file);
      expect(metadata?.title ?? '', isNot(contains('root:')));
    });
  });

  group('Calibre', () {
    test('metadata.opf gives authors, series, tags and identifiers', () async {
      final file = File('${root.path}/metadata.opf')
        ..writeAsStringSync('''<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier opf:scheme="calibre" id="calibre_id">12</dc:identifier>
    <dc:identifier opf:scheme="ISBN">9783123456789</dc:identifier>
    <dc:title>Der Schacht</dc:title>
    <dc:creator opf:file-as="May, Karl" opf:role="aut">Karl May</dc:creator>
    <dc:creator opf:role="trl">Jemand Anderes</dc:creator>
    <dc:description>&lt;p&gt;Ein &lt;b&gt;Abenteuer&lt;/b&gt;.&lt;/p&gt;</dc:description>
    <dc:publisher>Verlag</dc:publisher>
    <dc:date>1895-03-01T00:00:00+00:00</dc:date>
    <dc:language>deu</dc:language>
    <dc:subject>Abenteuer</dc:subject>
    <dc:subject>Klassiker</dc:subject>
    <meta name="calibre:series" content="Orientzyklus"/>
    <meta name="calibre:series_index" content="3.0"/>
    <meta name="calibre:rating" content="8"/>
  </metadata>
  <guide><reference type="cover" title="Cover" href="cover.jpg"/></guide>
</package>''');
      final metadata = (await const CalibreOpfReader().read(file))!;
      expect(metadata.title, 'Der Schacht');
      expect(metadata.authors, ['Karl May']);
      expect(metadata.description, 'Ein Abenteuer.');
      expect(metadata.publisher, 'Verlag');
      expect(metadata.publishedYear, 1895);
      expect(metadata.language, 'deu');
      expect(metadata.tags, ['Abenteuer', 'Klassiker']);
      expect(metadata.series, 'Orientzyklus');
      expect(metadata.sequence, 3);
      expect(metadata.externalRating, 4);
      expect(metadata.coverPath, 'cover.jpg');
      expect(metadata.sourceLinks, {'isbn': '9783123456789'});
    });
  });

  group('scan', () {
    test('a film folder takes its movie.nfo', () async {
      final film = Directory('${root.path}/Filme/nordwind_2019')
        ..createSync(recursive: true);
      File('${film.path}/nordwind.mkv').writeAsBytesSync([1, 2, 3]);
      File('${film.path}/movie.nfo').writeAsStringSync(
        '<movie><title>Nordwind</title><plot>Sturm.</plot>'
        '<uniqueid type="tmdb">98765</uniqueid><genre>Drama</genre></movie>',
      );
      final library = await FundusLibrary.create(root);
      addTearDown(library.close);
      await library.index().drain<void>();

      final work = library.listWorks().single;
      expect(work.title, 'Nordwind');
      expect(work.description, 'Sturm.');
      expect(work.genres, ['Drama']);
      expect(work.metadataOrigins['title']?.source, WorkMetadataSource.nfo);
    });

    test('a Calibre library becomes one work per book', () async {
      final calibre = Directory('${root.path}/Bücher/Calibre')
        ..createSync(recursive: true);
      File('${calibre.path}/metadata.db').writeAsBytesSync([0]);
      for (final (folder, title, index) in [
        ('Der Schacht (12)', 'Der Schacht', '3.0'),
        ('Im Sudan (13)', 'Im Sudan', '4.0'),
      ]) {
        final book = Directory('${calibre.path}/Karl May/$folder')
          ..createSync(recursive: true);
        File('${book.path}/$title - Karl May.epub').writeAsBytesSync([1]);
        File('${book.path}/cover.jpg').writeAsBytesSync([255, 216, 255, 217]);
        File('${book.path}/metadata.opf').writeAsStringSync(
          '''<?xml version='1.0'?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>$title</dc:title>
    <dc:creator opf:role="aut">Karl May</dc:creator>
    <meta name="calibre:series" content="Orientzyklus"/>
    <meta name="calibre:series_index" content="$index"/>
  </metadata>
</package>''',
        );
      }
      final library = await FundusLibrary.create(root);
      addTearDown(library.close);
      await library.index().drain<void>();

      final works = library.listWorks()
        ..sort((a, b) => a.title.compareTo(b.title));
      expect(works.map((work) => work.title), ['Der Schacht', 'Im Sudan']);
      expect(works.first.series, 'Orientzyklus');
      expect(works.first.seriesSequence, 3);
      expect(works.first.author, 'Karl May');
      expect(
        works.first.metadataOrigins['title']?.source,
        WorkMetadataSource.calibre,
      );
      expect(library.contentFiles(works.first.id), hasLength(1));
    });
  });
}
