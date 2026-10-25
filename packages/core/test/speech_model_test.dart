import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'speech model paths reject traversal, executables and unrelated files',
    () {
      for (final path in [
        '../model.q8.gguf',
        '/model.q8.gguf',
        r'C:\model.q8.gguf',
        'voices/../../token.json',
        'voices/a.dll',
        'ptts_ffi.dll',
        'device.json',
        'voices//a.safetensors',
      ]) {
        expect(
          () => SpeechModelFile(path: path, bytes: 1, sha256: 'a' * 64),
          throwsFormatException,
          reason: path,
        );
      }
      expect(
        SpeechModelFile.isAllowedPath('voices/en/english-female.safetensors'),
        isTrue,
      );
      expect(
        () => SpeechModelFile(
          path: 'model.q8.gguf',
          bytes: SpeechModelManifest.maxBytes + 1,
          sha256: 'a' * 64,
        ),
        throwsFormatException,
      );
    },
  );
  test('speech model offers require voices, weights and bounded files', () {
    SpeechModelFile file(String path) =>
        SpeechModelFile(path: path, bytes: 10, sha256: 'a' * 64);
    final files = [
      file('config.json'),
      file('tokenizer.json'),
      file('model.q8.gguf'),
    ];
    expect(
      () => SpeechModelManifest(id: 'a' * 64, languages: ['en'], files: files),
      throwsFormatException,
    );
    files.add(file('default-voice.safetensors'));
    expect(
      SpeechModelManifest(
        id: 'a' * 64,
        languages: ['en'],
        files: files,
      ).totalBytes,
      40,
    );
    expect(
      () => SpeechModelManifest(
        id: 'a' * 64,
        languages: ['en'],
        files: [...files, files.first],
      ),
      throwsFormatException,
    );
  });
}
