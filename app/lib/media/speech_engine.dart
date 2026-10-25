import 'package:fundus_core/fundus_core.dart';
import 'dart:typed_data';

/// Audio generated on this device. Synthesis alone never advances reading
/// progress; the shared player confirms completion first.
final class PhononAudio {
  const PhononAudio({required this.wav, required this.duration});

  final Uint8List wav;
  final Duration duration;
}

abstract interface class TextSpeechEngine {
  Future<List<SpeechLanguage>> availableLanguages();

  Future<List<String>> availableVoices(SpeechLanguage language);

  Future<PhononAudio> synthesize(
    SpeechTextSegment segment, {
    required SpeechLanguage language,
    String? voice,
  });

  Future<void> dispose();
}
