import 'dart:async';
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
      final installed = await Directory('${root.path}/phonon-models')
          .list()
          .where((entity) => entity.path.split('/').last.startsWith('model-'))
          .length;
      expect(installed, 0);
      corrupt = false;
      expect(await controller.ensureAvailable(), isNotNull);
      expect(offers, 2);
    },
  );

  test('nothing is fetched until somebody asks', () async {
    // Constructing the controller and having a server is not consent.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(offers, 0);
    final offer = await controller.findOffer();
    expect(offer, isNotNull);
    expect(offer!.model.totalBytes, model.totalBytes);
    expect(settings.phononModelDirectory, isNull);
    expect(
      await Directory('${root.path}/phonon-models').exists(),
      isFalse,
      reason: 'looking at the offer must not download anything',
    );
  });

  test('an interrupted download continues instead of starting over', () async {
    final big = List<int>.generate(64 * 1024, (index) => index % 251);
    final bigModel = SpeechModelManifest(
      id: 'b' * 64,
      languages: ['en'],
      files: [
        for (final entry in {...data, 'model.q8.gguf': big}.entries)
          SpeechModelFile(
            path: entry.key,
            bytes: entry.value.length,
            sha256: sha256.convert(entry.value).toString(),
          ),
      ],
    );
    final ranges = <String?>[];
    var interrupt = true;
    final resumable = FundusRemoteClient(
      baseUri: Uri.parse('https://paired'),
      token: 'paired',
      httpClient: MockClient.streaming((request, _) async {
        if (request.url.path == '/v1/tts/model') {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(bigModel.toJson()))),
            200,
          );
        }
        final entry = bigModel.files[int.parse(request.url.pathSegments.last)];
        final bytes = entry.path == 'model.q8.gguf' ? big : data[entry.path]!;
        if (entry.path != 'model.q8.gguf') {
          return http.StreamedResponse(Stream.value(bytes), 200);
        }
        final range = request.headers['range'];
        ranges.add(range);
        if (interrupt) {
          interrupt = false;
          // Half the file arrives, then the connection drops.
          final controller = StreamController<List<int>>();
          controller.add(bytes.sublist(0, bytes.length ~/ 2));
          controller.addError(const SocketException('Verbindung weg'));
          unawaited(controller.close());
          return http.StreamedResponse(
            controller.stream,
            200,
            contentLength: bytes.length,
          );
        }
        final from = int.parse(range!.substring(6, range.length - 1));
        return http.StreamedResponse(
          Stream.value(bytes.sublist(from)),
          206,
          contentLength: bytes.length - from,
          headers: {
            'content-range': 'bytes $from-${bytes.length - 1}/${bytes.length}',
          },
        );
      }),
    );
    final resuming = SpeechModelController(
      settings: settings,
      servers: () => [(id: 'host', name: 'BeeServe', client: resumable)],
      storageRoot: () async => root,
    );
    addTearDown(() {
      resuming.dispose();
      resumable.close();
    });

    expect(await resuming.ensureAvailable(), isNull);
    expect(resuming.failure, contains('fort'));
    final path = await resuming.ensureAvailable();
    expect(path, isNotNull);
    expect(ranges, [null, 'bytes=${big.length ~/ 2}-']);
    await PhononModelStore.verifyIntegrity(path!);
  });

  test('a new model replaces the old one instead of piling up', () async {
    final models = Directory('${root.path}/phonon-models')..createSync();
    final old = Directory('${models.path}/model-old')..createSync();
    File('${old.path}/model.q8.gguf').writeAsBytesSync(List.filled(4096, 1));
    final shared = Directory('${models.path}/model-shared')..createSync();
    File('${shared.path}/model.q8.gguf').writeAsBytesSync(List.filled(16, 1));
    Directory('${models.path}/.import-123').createSync();
    // Offered to paired devices from here: still in use.
    await settings.setPhononServerModelDirectory(shared.path);

    final installed = await controller.ensureAvailable();
    expect(installed, isNotNull);
    expect(Directory(old.path).existsSync(), isFalse);
    expect(shared.existsSync(), isTrue);
    expect(Directory('${models.path}/.import-123').existsSync(), isFalse);
    expect(await controller.unusedModels(), isEmpty);
  });
}
