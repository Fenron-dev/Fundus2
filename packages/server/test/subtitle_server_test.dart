import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// A film's subtitle files travel with it to every paired device, under the
/// same rules as the film: a work somebody may not see has no subtitles
/// either.
void main() {
  late Directory root;
  late FundusLibrary library;
  late FundusLibraryRegistry registry;
  late FundusPairingAuthority authority;
  late FundusServerHandler server;
  const deviceToken = 'device-token';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-subtitle-server-');
    final film = Directory('${root.path}/Filme/Nordwind')
      ..createSync(recursive: true);
    File('${film.path}/Nordwind.mkv').writeAsBytesSync([1, 2, 3]);
    File('${film.path}/Nordwind.de.srt').writeAsStringSync('1\nHallo\n');
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    registry = FundusLibraryRegistry()..register(library, name: 'Filme');
    authority = FundusPairingAuthority(
      devices: [
        FundusPairedDevice(
          id: 'phone-1',
          name: 'Telefon',
          tokenHash: FundusPairingAuthority.tokenDigest(deviceToken),
          pairedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    server = FundusServerHandler(
      token: 'secret',
      serverId: 'server-test',
      registry: registry,
      pairingAuthority: authority,
    );
  });

  tearDown(() async {
    registry.close();
    await root.delete(recursive: true);
  });

  Future<Response> get(String path) async => server.handler(
    Request(
      'GET',
      Uri.parse('http://localhost$path'),
      headers: const {'authorization': 'Bearer $deviceToken'},
    ),
  );

  test('the work names its subtitles and serves their bytes', () async {
    final libraryId = library.manifest.libraryId;
    final work = library.listWorks().single;
    final response = await get('/v1/libraries/$libraryId/works/${work.id}');
    final body = jsonDecode(await response.readAsString()) as Map;
    final file = (body['files'] as List).single as Map;
    final subtitle = (file['subtitles'] as List).single as Map;
    expect(subtitle['title'], 'Nordwind.de.srt');

    final content = await get(
      '/v1/libraries/$libraryId/files/${subtitle['id']}/content',
    );
    expect(content.statusCode, 200);
    expect(await content.readAsString(), '1\nHallo\n');
  });

  test('a protected film keeps its subtitles to itself', () async {
    final libraryId = library.manifest.libraryId;
    final work = library.listWorks().single;
    final subtitleId = library
        .playbackTracks(work.id)
        .single
        .subtitles
        .single
        .fileId;
    await library.updateWorkMetadata(
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
      contentSensitivity: 'adult_explicit',
    );
    registry.lookup(libraryId)!.invalidate();

    final hidden = await get(
      '/v1/libraries/$libraryId/files/$subtitleId/content',
    );
    expect(hidden.statusCode, 404);

    await authority.setAdultExplicitAllowed('phone-1', true);
    final visible = await get(
      '/v1/libraries/$libraryId/files/$subtitleId/content',
    );
    expect(visible.statusCode, 200);
  });

  test('an unknown file id stays unknown', () async {
    final libraryId = library.manifest.libraryId;
    final response = await get(
      '/v1/libraries/$libraryId/files/does-not-exist/content',
    );
    expect(response.statusCode, 404);
  });
}
