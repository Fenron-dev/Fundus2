import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/phonon_wave.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/speech_engine.dart';
import 'package:fundus/media/text_reader_controller.dart';
import 'package:fundus/media/text_speech_controller.dart';
import 'package:fundus_core/fundus_core.dart';
import 'playback_controller_test.dart' show FakeEngine;
import 'text_reader_test.dart' show FakeTextSource, writeEpub;

final class _SpeechEngine implements TextSpeechEngine {
  int calls = 0;
  @override
  Future<List<SpeechLanguage>> availableLanguages() async => [
    SpeechLanguage.english,
  ];
  @override
  Future<List<String>> availableVoices(SpeechLanguage language) async => [
    'default',
  ];
  @override
  Future<PhononAudio> synthesize(
    SpeechTextSegment segment, {
    required SpeechLanguage language,
    String? voice,
  }) async {
    calls++;
    final wave = PhononWaveBuilder()
      ..append(Float32List.fromList(List.filled(2400, .25)));
    return PhononAudio(wav: wave.finish(), duration: wave.duration);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  test(
    'one continuous sink plays all chapter sentences and checkpoints only audio position',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fundus-speech-stream-',
      );
      final folder = Directory('${root.path}/Light Novels/Test')
        ..createSync(recursive: true);
      writeEpub(folder, 'Book.epub', ['Chapter']);
      final library = LibraryController();
      final reader = TextReaderController(
        openSource: (path, name) => FakeTextSource(name, ['Chapter']),
      );
      final engine = FakeEngine();
      final player = PlaybackController(engine: engine);
      final tts = _SpeechEngine();
      final speech = TextSpeechController(
        reader: reader,
        player: player,
        engineFactory: (directory, language) async => tts,
        tempDirectory: () async => root,
      );
      final client = HttpClient();
      StreamSubscription<bool>? playing;
      StreamSubscription<List<int>>? incoming;
      addTearDown(() async {
        await speech.stop();
        await playing?.cancel();
        await incoming?.cancel();
        client.close(force: true);
        speech.dispose();
        reader.dispose();
        player.dispose();
        await library.library?.flushSidecarWrites();
        library.dispose();
        await root.delete(recursive: true);
      });
      await library.open(root, createIfMissing: true);
      await library.scan();
      await reader.open(library.library!, library.works.first);
      HttpClientResponse? response;
      engine.onOpen = () async {
        response = await (await client.getUrl(engine.opened.last)).close();
      };
      var listened = false;
      playing = engine.playingStream.listen((value) {
        if (!value || listened) return;
        listened = true;
        var bytes = 0;
        incoming = response!.listen((chunk) {
          bytes += chunk.length;
          engine.emitPosition(
            Duration(
              microseconds:
                  (bytes ~/ 2) * Duration.microsecondsPerSecond ~/ 24000,
            ),
          );
        }, onDone: engine.emitCompleted);
      });
      await speech
          .start(modelDirectory: root.path, workOverride: 'en')
          .timeout(const Duration(seconds: 10));
      expect(speech.failure, isNull);
      expect(engine.opened.length, 1);
      expect(tts.calls, greaterThan(4));
      expect(reader.paragraphIndex, reader.paragraphs.length - 1);
      expect(reader.innerOffset, 1);
      final progress = library.library!.loadProgress(library.works.first.id)!;
      expect(progress.position.kind, MediaPositionKind.epubCfi);
      expect(progress.position.chapterId, reader.currentChapter!.id);
      final beforePreview = progress.position.numericValue;
      engine.onOpen = () async {};
      final previewPlaying = engine.playingStream.listen((playing) {
        if (playing) engine.emitCompleted();
      });
      await speech.preview(
        modelDirectory: root.path,
        language: SpeechLanguage.english,
      );
      await previewPlaying.cancel();
      expect(player.work, isNull);
      expect(
        library.library!
            .loadProgress(library.works.first.id)!
            .position
            .numericValue,
        beforePreview,
      );
    },
  );
}
