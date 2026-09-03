import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../data/library_controller.dart';
import 'app_settings.dart';
import '../media/playback_controller.dart';
import 'fundus_scope.dart';
import 'shell/fundus_shell.dart';

/// The application root: theme, density and the one shell.
class FundusApp extends StatelessWidget {
  const FundusApp({
    super.key,
    required this.settings,
    required this.library,
    this.player,
  });

  final AppSettings settings;
  final LibraryController library;

  /// Built before the app so the media session can hold it.
  final PlaybackController? player;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'Fundus',
        debugShowCheckedModeBanner: false,
        // Dark and light are equal citizens; the density rides along so tiles
        // and rows resize with the theme rather than through a second lookup.
        theme: FundusTheme.light(density: settings.density),
        darkTheme: FundusTheme.dark(density: settings.density),
        themeMode: settings.themeMode,
        home: FundusScope(
          settings: settings,
          library: library,
          player: player,
          child: const FundusShell(),
        ),
      ),
    );
  }
}
