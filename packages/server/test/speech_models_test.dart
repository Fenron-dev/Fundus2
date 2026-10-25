import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late FundusServerHandler server;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-shared-speech-');
    for (final entry in {
      'config.json': '{"languages":["en"]}',
      'tokenizer.json': '{}',
      'model.q8.gguf': 'q8 weights',
      'model.safetensors': 'unused weights',
      'default-voice.safetensors': 'voice',
      'private-token.json': 'do not share',
      'ptts_ffi.dll': 'do not share',
    }.entries) {
      await File('${root.path}/${entry.key}').writeAsString(entry.value);
    }
    server = FundusServerHandler(
      token: 'paired',
      serverId: 'host',
      speechModelDirectory: () => root.path,
    );
  });
  tearDown(() => root.delete(recursive: true));
  Future<Response> get(String path, {bool paired = true}) async =>
      server.handler(
        Request(
          'GET',
          Uri.parse('http://localhost$path'),
          headers: {if (paired) 'authorization': 'Bearer paired'},
        ),
      );
  Future<SpeechModelManifest> manifest() async => SpeechModelManifest.fromJson(
    Map<String, Object?>.from(
      jsonDecode(await (await get('/v1/tts/model')).readAsString()) as Map,
    ),
  );

  test(
    'only authenticated devices receive model data and Q8 is sent once',
    () async {
      expect((await get('/v1/tts/model', paired: false)).statusCode, 401);
      expect(
        (await get('/v1/tts/models/model/files/0', paired: false)).statusCode,
        401,
      );
      final model = await manifest();
      expect(model.languages, ['en']);
      expect(
        model.files.map((file) => file.path),
        unorderedEquals([
          'config.json',
          'tokenizer.json',
          'model.q8.gguf',
          'default-voice.safetensors',
        ]),
      );
      final index = model.files.indexWhere(
        (file) => file.path == 'model.q8.gguf',
      );
      final response = await get('/v1/tts/models/${model.id}/files/$index');
      final bytes = await response.read().expand((chunk) => chunk).toList();
      expect(response.statusCode, 200);
      expect(sha256.convert(bytes).toString(), model.files[index].sha256);
      expect(utf8.decode(bytes), 'q8 weights');
      expect(
        (await get('/v1/tts/models/${model.id}/files/-1')).statusCode,
        404,
      );
    },
  );

  test('a model change invalidates the old download offer', () async {
    final old = await manifest();
    await File('${root.path}/model.q8.gguf').writeAsString('new q8 weights');
    final next = await manifest();
    expect(next.id, isNot(old.id));
    expect((await get('/v1/tts/models/${old.id}/files/0')).statusCode, 404);
  });

  test('linked model data and incomplete CPU folders are not shared', () async {
    await File('${root.path}/default-voice.safetensors').delete();
    expect((await get('/v1/tts/model')).statusCode, 409);
    if (!Platform.isWindows) {
      await Link(
        '${root.path}/default-voice.safetensors',
      ).create('${root.path}/private-token.json');
      expect((await get('/v1/tts/model')).statusCode, 409);
    }
  });
}
