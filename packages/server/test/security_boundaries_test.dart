import 'dart:convert';
import 'dart:io';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import '../../core/test/epub_package_test.dart' show epubFixture;

void main() {
  late Directory root;
  late FundusLibrary library;
  late LibraryWorkSummary visible;
  late LibraryWorkSummary hidden;
  late FundusLibraryRegistry registry;
  late Handler handler;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-boundaries-');
    final docs = Directory('${root.path}/Documents')..createSync();
    File('${docs.path}/Public.pdf').writeAsBytesSync([1, 2, 3]);
    File('${docs.path}/Secret.pdf').writeAsBytesSync([1, 2, 3]);
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    visible = library.listWorks().firstWhere((w) => w.title == 'Public');
    hidden = library.listWorks().firstWhere((w) => w.title == 'Secret');
    await library.updateWorkMetadata(
      workId: hidden.id,
      title: hidden.title,
      authors: hidden.authors,
      contentSensitivity: 'adult_explicit',
    );
    registry = FundusLibraryRegistry()..register(library, name: 'Test');
    final authority = FundusPairingAuthority(
      devices: [
        FundusPairedDevice(
          id: 'restricted',
          name: 'Phone',
          pairedAt: DateTime.now(),
          tokenHash: FundusPairingAuthority.tokenDigest('limited'),
        ),
      ],
    );
    handler = FundusServerHandler(
      token: 'host',
      serverId: 'test',
      registry: registry,
      pairingAuthority: authority,
    ).handler;
  });
  tearDown(() async {
    await library.flushSidecarWrites();
    registry.close();
    await root.delete(recursive: true);
  });
  Future<Response> request(
    String method,
    String path, [
    Object? body,
  ]) async => handler(
    Request(
      method,
      Uri.parse(
        'https://localhost/v1/libraries/${library.manifest.libraryId}/$path',
      ),
      headers: {
        'authorization': 'Bearer limited',
        'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );

  test(
    'a visible URL cannot delete another works bookmark or highlight',
    () async {
      final fileId = library.playbackTracks(hidden.id).single.fileId;
      final marks = await library.addBookmark(
        workId: hidden.id,
        fileId: fileId,
        position: const Duration(seconds: 3),
      );
      final markId = marks.bookmarks.single.id;
      final response = await request(
        'DELETE',
        'annotations/${visible.id}/bookmarks/$markId',
      );
      expect(response.statusCode, 200);
      expect(library.loadAnnotations(hidden.id).bookmarks.single.id, markId);
      await request('DELETE', 'annotations/${visible.id}/highlights/$markId');
      expect(library.loadAnnotations(hidden.id).bookmarks.single.id, markId);
    },
  );
  test('POST never replaces an existing inaccessible playlist', () async {
    final list = library.savePlaylist(
      name: 'Secret list',
      workIds: [hidden.id],
    );
    final response = await request('POST', 'playlists', {
      'id': list.id,
      'name': 'Overwrite',
      'work_ids': [visible.id],
    });
    expect(response.statusCode, 409);
    expect(library.loadPlaylist(list.id)?.name, 'Secret list');
  });
  test('playlist file must belong to its work', () async {
    final response = await request('POST', 'playlists', {
      'name': 'Invalid',
      'items': [
        {
          'work_id': visible.id,
          'file_id': library.playbackTracks(hidden.id).single.fileId,
        },
      ],
    });
    expect(response.statusCode, 400);
  });
  test('host never publishes another servers mirrored catalogue', () async {
    library.registerPeerSource(
      sourceId: 'peer-other',
      displayName: 'Other',
      libraryId: 'other',
      baseUrl: 'https://localhost',
    );
    final id = FundusId.generate();
    library.mirrorRemoteCatalogue(
      sourceId: 'peer-other',
      works: [RemoteWorkRecord(id: id, kind: 'document', title: 'Foreign')],
    );
    for (final path in ['works', 'catalogue', 'catalogue/index']) {
      final response = await request('GET', path);
      expect(response.statusCode, 200);
      expect(await response.readAsString(), isNot(contains(id)));
    }
  });
  test('unrelated nonces do not consume the pairing invitation', () async {
    final authority = FundusPairingAuthority();
    final session = authority.begin();
    for (var i = 0; i < 8; i++) {
      await expectLater(
        authority.claim(
          nonce: 'unrelated',
          pin: '000000',
          deviceId: 'x',
          deviceName: 'X',
        ),
        throwsA(isA<FundusPairingException>()),
      );
    }
    final paired = await authority.claim(
      nonce: session.nonce,
      pin: session.pin,
      deviceId: 'real',
      deviceName: 'Real',
    );
    expect(paired.device.id, 'real');
  });
  test('restricted catalogue never exports protected custom fields', () async {
    final definition = await library.savePropertyDefinition(
      mediaKind: '',
      name: 'Private field',
      valueType: PropertyValueType.text,
      protected: true,
    );
    await library.setWorkProperty(
      workId: visible.id,
      definitionId: definition.id,
      value: 'Private value',
    );
    final reply = await request('GET', 'catalogue');
    final text = await reply.readAsString();
    expect(text, isNot(contains('Private field')));
    expect(text, isNot(contains('Private value')));
  });
  test(
    'protected tags are neither disclosed nor erased by limited tag writes',
    () async {
      await library.replaceWorkTags(visible.id, ['Public tag', 'Private tag']);
      await library.setTagProtected('Private tag', protected: true);
      for (final path in [
        'works',
        'catalogue',
        'works/${visible.id}',
        'annotations/${visible.id}',
      ]) {
        final response = await request('GET', path);
        expect(await response.readAsString(), isNot(contains('Private tag')));
      }
      final response = await request('PUT', 'annotations/${visible.id}/tags', {
        'tags': ['New public tag'],
      });
      expect(response.statusCode, 200);
      expect(await response.readAsString(), isNot(contains('Private tag')));
      expect(library.loadAnnotations(visible.id).tags, contains('Private tag'));
    },
  );
  test(
    'malformed progress cursor is a client error, not a server failure',
    () async {
      final response = await request(
        'GET',
        'progress?since=999999999999999999',
      );
      expect(response.statusCode, 400);
    },
  );

  test(
    'chapter metadata uses the same protection and library gates as file content',
    () async {
      final book = File('${root.path}/Webnovels/Secret/Novel.epub');
      await book.parent.create(recursive: true);
      await book.writeAsBytes(epubFixture());
      await library.index().drain<void>();
      final novel = library.listWorks().firstWhere(
        (work) => work.kind == 'webnovel',
      );
      await library.updateWorkMetadata(
        workId: novel.id,
        title: novel.title,
        authors: novel.authors,
        contentSensitivity: 'adult_explicit',
      );
      final fileId = library.playbackTracks(novel.id).single.fileId;
      final denied = await request('GET', 'files/$fileId/publication-manifest');
      expect(denied.statusCode, 404);
      expect(await denied.readAsString(), isNot(contains('Kapitel Eins')));
      final allowed = await handler(
        Request(
          'GET',
          Uri.parse(
            'https://localhost/v1/libraries/${library.manifest.libraryId}/files/$fileId/publication-manifest',
          ),
          headers: {'authorization': 'Bearer host'},
        ),
      );
      expect(allowed.statusCode, 200);
      final body = await allowed.readAsString();
      expect(body, contains('Kapitel Eins'));
      expect(body, isNot(contains('Erster Absatz.')));
    },
  );
}
