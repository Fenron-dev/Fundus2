import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/speech_audio_buffer.dart';
import 'package:fundus/media/phonon_wave.dart';
import 'package:fundus/media/speech_engine.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  SpeechTextSegment sentence(int index) => SpeechTextSegment(
    text: 'Sentence $index.',
    start: index * 20,
    end: index * 20 + 12,
    paragraphIndex: 0,
    startPosition: MediaPosition(
      kind: MediaPositionKind.epubCfi,
      numericValue: index / 10,
    ),
    endPosition: MediaPosition(
      kind: MediaPositionKind.epubCfi,
      numericValue: (index + 1) / 10,
    ),
  );
  PhononAudio audio() {
    final wave = PhononWaveBuilder()
      ..append(Float32List.fromList(List.filled(24000, .25)));
    return PhononAudio(wav: wave.finish(), duration: wave.duration);
  }

  test(
    'continuous raw PCM stream bounds ahead data and commits only heard sentences',
    () async {
      final buffer = await SpeechAudioBuffer.open();
      addTearDown(buffer.dispose);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final head = await (await client.headUrl(buffer.uri)).close();
      expect(head.statusCode, 200);
      await head.drain<void>();
      final wrong = await (await client.getUrl(
        buffer.uri.replace(path: '/unknown/speech.pcm'),
      )).close();
      expect(wrong.statusCode, 404);
      await wrong.drain<void>();

      for (var i = 0; i < 4; i++) {
        await buffer.add(audio(), sentence(i));
      }
      await buffer.ready.future;
      var fifthAdded = false;
      final fifth = buffer
          .add(audio(), sentence(4))
          .then((_) => fifthAdded = true);
      await Future<void>.delayed(Duration.zero);
      expect(fifthAdded, isFalse);
      expect(buffer.heardUntil(const Duration(milliseconds: 500)), isEmpty);
      final heard = buffer.heardUntil(const Duration(milliseconds: 1200));
      expect(heard.map((s) => s.text), ['Sentence 0.']);
      await fifth;
      expect(buffer.bufferedSegments, 4);

      final response = await (await client.getUrl(buffer.uri)).close();
      final bytesFuture = response.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      buffer.finish();
      final bytes = await bytesFuture;
      expect(bytes.length, speechPcm(audio().wav).length * 5);
      expect(bytes.sublist(0, 4), isNot(equals([82, 73, 70, 70])));
      expect(buffer.complete().map((s) => s.text), [
        'Sentence 1.',
        'Sentence 2.',
        'Sentence 3.',
        'Sentence 4.',
      ]);
    },
  );

  test(
    'stop releases a producer waiting for space without advancing progress',
    () async {
      final buffer = await SpeechAudioBuffer.open();
      for (var i = 0; i < 4; i++) {
        await buffer.add(audio(), sentence(i));
      }
      final waiting = buffer.add(audio(), sentence(4));
      await buffer.dispose();
      await waiting.timeout(const Duration(seconds: 1));
      expect(buffer.heardUntil(Duration.zero), isEmpty);
    },
  );

  test(
    'Phonon silence is trimmed but audible speech and bounded natural pause remain',
    () {
      final wave = PhononWaveBuilder()
        ..append(
          Float32List.fromList([
            ...List.filled(24000, 0.0),
            ...List.filled(24000, .25),
            ...List.filled(48000, 0.0),
          ]),
        );
      final pcm = speechPcm(wave.finish());
      expect(pcm.length / 48000, closeTo(1.24, .01));
      final data = ByteData.sublistView(pcm);
      expect(data.getInt16(2400 * 2, Endian.little), greaterThan(7000));
    },
  );
}
