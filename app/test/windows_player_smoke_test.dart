import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/phonon_wave.dart';
import 'package:fundus/media/playback_engine.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test(
    'normal media plays after a speech demuxer was active',
    () async {
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('fundus-windows-mpv-');
      final player = Player();
      final engine = MediaKitEngine(player: player, attachVideo: false);
      try {
        final tone = PhononWaveBuilder()
          ..append(Float32List.fromList(List<double>.filled(48000, 0.1)));
        final file = File('${root.path}/Film später.wav');
        await file.writeAsBytes(tone.finish());
        final native = player.platform;
        expect(native, isA<NativePlayer>());
        await (native as NativePlayer).setProperty('ao', 'null');
        await native.setProperty('demuxer', 'rawaudio');

        await engine.open(file.uri);
        expect(await native.getProperty('demuxer'), isEmpty);
        await engine.play();
        final position = await engine.positionStream
            .firstWhere((position) => position > Duration.zero)
            .timeout(const Duration(seconds: 10));
        expect(position, greaterThan(Duration.zero));
      } finally {
        await engine.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
