import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/phonon_wave.dart';

void main() {
  test('Phonon float PCM wird zu begrenztem 24-kHz-Mono-WAV', () {
    final builder = PhononWaveBuilder(maxSeconds: 1);
    expect(builder.append(Float32List.fromList([-1, 0, 1])), isTrue);
    final wav = builder.finish();
    final header = ByteData.sublistView(wav);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
    expect(ascii.decode(wav.sublist(36, 40)), 'data');
    expect(header.getUint32(4, Endian.little), 42);
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 24000);
    expect(header.getUint16(34, Endian.little), 16);
    expect(header.getUint32(40, Endian.little), 6);
    expect(header.getInt16(44, Endian.little), -32768);
    expect(header.getInt16(46, Endian.little), 0);
    expect(header.getInt16(48, Endian.little), 32767);
    expect(builder.duration.inMicroseconds, 125);
  });

  test('zu lange Abschnitte werden vor dem Anfügen abgewiesen', () {
    final builder = PhononWaveBuilder(maxSeconds: 1);
    expect(builder.append(Float32List(24000)), isTrue);
    expect(builder.append(Float32List(1)), isFalse);
    expect(builder.sampleCount, 24000);
    expect(builder.finish().length, 44 + 48000);
  });

  test('leeres Audio gilt nicht als abgespielt', () {
    expect(() => PhononWaveBuilder().finish(), throwsFormatException);
  });
}
