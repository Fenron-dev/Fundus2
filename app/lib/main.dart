import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app_settings.dart';
import 'app/fundus_app.dart';
import 'data/library_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The playback engine has to be up before any player is built.
  MediaKit.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(FundusApp(settings: settings, library: LibraryController()));
}
