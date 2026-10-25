import 'dart:collection';
import 'dart:typed_data';

/// Builds a bounded 24 kHz mono WAV from the float samples emitted by Phonon.
/// No text, model or voice is persisted in the resulting audio bytes.
final class PhononWaveBuilder {
  PhononWaveBuilder({this.maxSeconds = 120}) {
    if (maxSeconds < 1 || maxSeconds > 300) {
      throw ArgumentError.value(maxSeconds, 'maxSeconds');
    }
  }

  static const sampleRate = 24000;
  final int maxSeconds;
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _sampleCount = 0;

  int get sampleCount => _sampleCount;
  Duration get duration => Duration(
    microseconds: (_sampleCount * Duration.microsecondsPerSecond) ~/ sampleRate,
  );

  /// Returns false before accepting a chunk that exceeds the output limit.
  bool append(Float32List samples) {
    if (_sampleCount + samples.length > maxSeconds * sampleRate) return false;
    final bytes = Uint8List(samples.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var index = 0; index < samples.length; index++) {
      final sample = samples[index];
      final clamped = sample.isNaN ? 0.0 : sample.clamp(-1.0, 1.0);
      final signed = clamped < 0
          ? (clamped * 32768).round()
          : (clamped * 32767).round();
      data.setInt16(index * 2, signed, Endian.little);
    }
    _chunks.add(bytes);
    _sampleCount += samples.length;
    return true;
  }

  Uint8List finish() {
    if (_sampleCount == 0) throw const FormatException('Leeres Phonon-Audio.');
    final pcmBytes = _sampleCount * 2;
    final wav = Uint8List(44 + pcmBytes);
    final header = ByteData.sublistView(wav);
    void ascii(int offset, String value) {
      for (var index = 0; index < value.length; index++) {
        wav[offset + index] = value.codeUnitAt(index);
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + pcmBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // mono
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, pcmBytes, Endian.little);
    var offset = 44;
    for (final chunk in _chunks) {
      wav.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return wav;
  }
}
