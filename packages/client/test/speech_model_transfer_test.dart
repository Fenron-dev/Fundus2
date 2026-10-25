import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-model-download-');
  });
  tearDown(() => root.delete(recursive: true));
  final bytes = utf8.encode('model data');
  final model = SpeechModelManifest(
    id: 'a' * 64,
    languages: ['en'],
    files: [
      for (final path in [
        'config.json',
        'tokenizer.json',
        'model.q8.gguf',
        'default-voice.safetensors',
      ])
        SpeechModelFile(
          path: path,
          bytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
        ),
    ],
  );

  test(
    'streams paired model bytes with exact size and hash verification',
    () async {
      final requests = <http.Request>[];
      final client = FundusRemoteClient(
        baseUri: Uri.parse('https://paired-server'),
        token: 'secret',
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/v1/tts/model') {
            return http.Response(jsonEncode(model.toJson()), 200);
          }
          return http.Response.bytes(bytes, 200);
        }),
      );
      addTearDown(client.close);
      final offer = await client.speechModel();
      expect(offer!.id, model.id);
      final file = File('${root.path}/staging');
      var received = 0;
      await client.downloadSpeechModelFile(
        model: offer,
        index: 2,
        destination: file,
        onProgress: (value) => received = value,
      );
      expect(await file.readAsBytes(), bytes);
      expect(received, bytes.length);
      expect(
        requests.every(
          (request) => request.headers['authorization'] == 'Bearer secret',
        ),
        isTrue,
      );
      expect(requests.every((request) => !request.followRedirects), isTrue);
    },
  );

  test(
    'changed model bytes or redirects never count as a completed transfer',
    () async {
      var redirect = false;
      final client = FundusRemoteClient(
        baseUri: Uri.parse('https://paired-server'),
        token: 'secret',
        httpClient: MockClient(
          (request) async => redirect
              ? http.Response(
                  '',
                  302,
                  headers: {'location': 'https://unrelated-host/model'},
                )
              : http.Response('badl data!', 200),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.downloadSpeechModelFile(
          model: model,
          index: 2,
          destination: File('${root.path}/bad'),
        ),
        throwsFormatException,
      );
      redirect = true;
      await expectLater(
        client.downloadSpeechModelFile(
          model: model,
          index: 2,
          destination: File('${root.path}/redirect'),
        ),
        throwsA(isA<FundusRemoteException>()),
      );
      expect(File('${root.path}/redirect').existsSync(), isFalse);
    },
  );

  test(
    'an old server without model distribution is a supported empty offer',
    () async {
      final client = FundusRemoteClient(
        baseUri: Uri.parse('https://paired-server'),
        token: 'secret',
        httpClient: MockClient(
          (_) async => http.Response('{"error":"not_found"}', 404),
        ),
      );
      addTearDown(client.close);
      expect(await client.speechModel(), isNull);
    },
  );
}
