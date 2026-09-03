import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// Packing the catalogue for the trip.
///
/// A catalogue is thousands of works described in words, most of them
/// repeated — it packs down to a fraction, and over a home network that
/// fraction is the difference between a list that appears and one that
/// arrives. What must not happen is packing things that are already packed,
/// or packing for a client that cannot unpack.
void main() {
  late Directory temporary;
  late FundusLibrary library;
  late FundusLibraryRegistry registry;
  late HttpServer socket;
  late String libraryId;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-gzip-');
    // Genug Werke, dass die Antwort über der Schwelle liegt.
    for (var index = 0; index < 40; index++) {
      final work = Directory(
        '${temporary.path}/Hörbücher/Karl May/Der Schacht $index',
      );
      await work.create(recursive: true);
      await File(
        '${work.path}/01 - Anfang.mp3',
      ).writeAsBytes(List.filled(64, 1));
    }
    library = await FundusLibrary.create(temporary);
    await for (final _ in library.index()) {}
    libraryId = library.manifest.libraryId;

    registry = FundusLibraryRegistry()..register(library, name: 'Hörbücher');
    socket = await shelf_io.serve(
      FundusServerHandler(
        token: 'geheim',
        serverId: 'server-test',
        registry: registry,
      ).handler,
      'localhost',
      0,
    );
  });

  tearDown(() async {
    await socket.close(force: true);
    registry.close();
    await temporary.delete(recursive: true);
  });

  Future<HttpClientResponse> fetch(String path, {bool gzip = true}) async {
    final client = HttpClient()..autoUncompress = false;
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://localhost:${socket.port}$path'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer geheim');
    request.headers.set(
      HttpHeaders.acceptEncodingHeader,
      gzip ? 'gzip' : 'identity',
    );
    return request.close();
  }

  test('der Katalog kommt gepackt, wenn der Client das kann', () async {
    final packed = await fetch('/v1/libraries/$libraryId/catalogue');
    expect(packed.headers.value('content-encoding'), 'gzip');

    final bytes = await packed.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    final decoded = jsonDecode(utf8.decode(gzip.decode(bytes)));
    expect((decoded as Map)['works'], hasLength(40));

    final plain = await fetch(
      '/v1/libraries/$libraryId/catalogue',
      gzip: false,
    );
    final raw = await plain.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    // Der ganze Zweck: deutlich weniger unterwegs.
    expect(bytes.length * 3, lessThan(raw.length));
  });

  test('wer nicht auspacken kann, bekommt es ungepackt', () async {
    final response = await fetch(
      '/v1/libraries/$libraryId/catalogue',
      gzip: false,
    );

    expect(response.headers.value('content-encoding'), isNull);
    final bytes = await response.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    expect(jsonDecode(utf8.decode(bytes)), isA<Map<String, Object?>>());
  });

  test('eine kurze Antwort wird nicht gepackt', () async {
    final response = await fetch('/v1/libraries');

    // Ein Paket mehr für ein paar hundert Byte lohnt nicht.
    expect(response.headers.value('content-encoding'), isNull);
  });

  test('Mediendateien werden nicht noch einmal gepackt', () async {
    final workId = library.listWorks().first.id;
    final fileId = library.playbackTracks(workId).single.fileId;

    final response = await fetch(
      '/v1/libraries/$libraryId/files/$fileId/content',
    );

    expect(response.headers.value('content-encoding'), isNull);
  });
}
