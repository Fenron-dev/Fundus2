import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/media/phonon_model_store.dart';
import 'package:fundus/media/speech_model_controller.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory root;
  late AppSettings settings;
  late SpeechModelController controller;
  late FundusRemoteClient client;
  var offers = 0;
  var corrupt = false;
  final data = {
    'config.json': utf8.encode('{"languages":["en"]}'),
    'tokenizer.json': utf8.encode('{}'),
    'model.q8.gguf': utf8.encode('weights'),
    'default-voice.safetensors': utf8.encode('voice'),
  };
  final model = SpeechModelManifest(
    id: 'a' * 64,
    languages: ['en'],
    files: [
      for (final entry in data.entries)
        SpeechModelFile(
          path: entry.key,
          bytes: entry.value.length,
          sha256: sha256.convert(entry.value).toString(),
        ),
    ],
  );

  setUp(() async {
    offers = 0;
    corrupt = false;
    root = await Directory.systemTemp.createTemp('fundus-speech-install-');
    settings = AppSettings.inMemory();
    client = FundusRemoteClient(
      baseUri: Uri.parse('https://paired'),
      token: 'paired',
      httpClient: MockClient((request) async {
        if (request.url.path == '/v1/tts/model') {
          offers++;
          return http.Response(jsonEncode(model.toJson()), 200);
        }
        final entry = model.files[int.parse(request.url.pathSegments.last)];
        final bytes = data[entry.path]!;
        return http.Response.bytes(
          corrupt ? List.filled(bytes.length, 0) : bytes,
          200,
        );
      }),
    );
    controller = SpeechModelController(
      settings: settings,
      servers: () => [(id: 'host', name: 'BeeServe', client: client)],
      storageRoot: () async => root,
    );
  });
  tearDown(() async {
    controller.dispose();
    client.close();
    settings.dispose();
    await root.delete(recursive: true);
  });

  test('a model is installed atomically once and reused offline', () async {
    final paths = await Future.wait([
      controller.ensureAvailable(),
      controller.ensureAvailable(),
    ]);
    expect(paths.first, isNotNull);
    expect(paths.first, paths.last);
    expect(offers, 1);
    expect(settings.phononModelDirectory, paths.first);
    await PhononModelStore.verifyIntegrity(paths.first!);
    await PhononModelStore.validateCpuModelDirectory(paths.first!);
    expect(controller.progress, 1);
    expect(await controller.ensureAvailable(), paths.first);
    expect(offers, 1);
    expect(await Directory('${root.path}/phonon-models').list().length, 1);
  });

  test(
    'a broken transfer never sets the model path and can be retried',
    () async {
      corrupt = true;
      expect(await controller.ensureAvailable(), isNull);
      expect(settings.phononModelDirectory, isNull);
      expect(controller.failure, contains('Prüfsumme'));
      expect(await Directory('${root.path}/phonon-models').list().length, 0);
      expect(await controller.ensureAvailable(), isNull);
      expect(
        offers,
        1,
        reason: 'heartbeats must not restart a failed large transfer',
      );
      corrupt = false;
      expect(await controller.ensureAvailable(retry: true), isNotNull);
      expect(offers, 2);
    },
  );
}
