import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app/app_settings.dart';
import 'app/fundus_app.dart';
import 'data/library_controller.dart';
import 'media/background_playback.dart';
import 'media/playback_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The playback engine has to be up before any player is built.
  MediaKit.ensureInitialized();
  // And pdfium before the first PDF is opened. The reader calls this too, but
  // doing it here means the first page does not wait for it.
  pdfrxFlutterInitialize();
  final settings = await AppSettings.load();
  // Der Player entsteht hier, nicht erst in der Shell: die Medien-Sitzung für
  // die Hintergrundwiedergabe muss ihn vor dem ersten Bild kennen.
  final player = PlaybackController(
    deviceId: settings.deviceKey,
    deviceName: settings.deviceName,
  );
  await FundusAudioHandler.attach(player);
  runApp(
    FundusApp(settings: settings, library: LibraryController(), player: player),
  );
}
