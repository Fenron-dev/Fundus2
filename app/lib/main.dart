import 'package:flutter/material.dart';

import 'app/app_settings.dart';
import 'app/fundus_app.dart';
import 'data/library_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(FundusApp(settings: settings, library: LibraryController()));
}
