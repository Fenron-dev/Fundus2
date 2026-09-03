import 'dart:io';

import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// The loopback door the media engine plays through.
///
/// It exists because mpv knows neither the pinned certificate nor the bearer
/// token, and teaching a media engine either would mean handing it the keys.
/// What matters is that bytes come through, that *ranges* come through —
/// without them there is no seeking — and that a guessed address does not.
void main() {
  late Directory temporary;
  late FundusLibrary library;
  late FundusLibraryRegistry registry;
  late HttpServer socket;
  late FundusStreamProxy proxy;
  late String fileId;
  late List<int> contents;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-proxy-');
    final work = Directory('${temporary.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    contents = List<int>.generate(4096, (index) => index % 251);
    await File('${work.path}/01 - Anfang.mp3').writeAsBytes(contents);
    library = await FundusLibrary.create(temporary);
    await for (final _ in library.index()) {}
    fileId = library
        .playbackTracks(library.listWorks().single.id)
        .single
        .fileId;

    registry = FundusLibraryRegistry()..register(library, name: 'Hörbücher');
    final handler = FundusServerHandler(
      token: 'geheim',
      serverId: 'server-test',
      registry: registry,
    );
    socket = await shelf_io.serve(handler.handler, 'localhost', 0);
    proxy = await FundusStreamProxy.start(
      baseUri: Uri.parse('http://localhost:${socket.port}'),
      token: 'geheim',
      libraryId: library.manifest.libraryId,
    );
  });

  tearDown(() async {
    await proxy.close();
    await socket.close(force: true);
    registry.close();
    await temporary.delete(recursive: true);
  });

  Future<HttpClientResponse> fetch(Uri uri, {String? range}) async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  test('die Datei kommt durch, ohne dass der Player ein Token kennt', () async {
    final response = await fetch(proxy.uriFor(fileId, extension: '.mp3'));

    expect(response.statusCode, 200);
    final bytes = await response.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    expect(bytes, contents);
  });

  test('ein Bereich kommt als Bereich zurück — sonst kein Spulen', () async {
    final response = await fetch(
      proxy.uriFor(fileId, extension: '.mp3'),
      range: 'bytes=1000-1099',
    );

    expect(response.statusCode, HttpStatus.partialContent);
    final bytes = await response.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    expect(bytes, contents.sublist(1000, 1100));
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 1000-1099/4096',
    );
  });

  test('eine geratene Adresse bekommt nichts', () async {
    final real = proxy.uriFor(fileId);
    final guessed = real.replace(path: '/geraten/$fileId');

    final response = await fetch(guessed);

    expect(response.statusCode, HttpStatus.notFound);
  });

  test('eine unbekannte Datei endet nicht im Absturz', () async {
    final response = await fetch(proxy.uriFor('gibt-es-nicht'));

    expect(response.statusCode, HttpStatus.notFound);
  });
}
