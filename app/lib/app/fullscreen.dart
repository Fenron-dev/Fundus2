import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'fundus_log.dart';

/// Making the window itself go fullscreen.
///
/// Behind an interface because it is the one thing in the reader and the
/// player that talks to the operating system: a test must be able to watch it
/// without a window manager underneath.
abstract interface class FullscreenMode {
  /// [landscape] asks the device to turn, which is right for a film and
  /// wrong for a manga page — so it is the caller's decision, not this
  /// class's.
  Future<void> enter({bool landscape = false});
  Future<void> exit();
}

/// The real thing.
///
/// On the desktop this is media_kit's own window call — the plugin is already
/// in the app and its helper is public. On the phone it is deliberately *not*
/// that helper: it locks the screen to landscape, which is right for a film
/// and wrong for a manga page.
final class NativeFullscreenMode implements FullscreenMode {
  const NativeFullscreenMode();

  @override
  Future<void> enter({bool landscape = false}) async {
    if (_isMobile) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: const [],
      );
      if (landscape) {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
      return;
    }
    await defaultEnterNativeFullscreen();
  }

  @override
  Future<void> exit() async {
    if (_isMobile) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
        overlays: SystemUiOverlay.values,
      );
      // Video fullscreen deliberately locks to landscape. Leaving it must
      // return to the information layout instead of leaving the phone in an
      // arbitrary orientation chosen by the last sensor event.
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      return;
    }
    await defaultExitNativeFullscreen();
  }

  static bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);
}

/// Whether a player currently owns the whole screen.
///
/// One controller for every player: the video, the reader and whatever comes
/// after them ask the same object, so leaving one player can never leave the
/// window stuck in fullscreen.
class FullscreenController extends ChangeNotifier {
  FullscreenController({FullscreenMode mode = const NativeFullscreenMode()})
    : _mode = mode;

  final FullscreenMode _mode;
  bool _active = false;

  bool get isActive => _active;

  Future<void> toggle({bool landscape = false}) =>
      _active ? leave() : enter(landscape: landscape);

  Future<void> enter({bool landscape = false}) async {
    if (_active) return;
    _active = true;
    notifyListeners();
    // A window that refuses to grow is a blemish, never a reason for the
    // work not to open: on a platform without the channel this throws, and
    // the film behind it plays perfectly well either way.
    try {
      await _mode.enter(landscape: landscape);
    } on Object catch (failure) {
      FundusLog.instance.warn('fullscreen.enter', {'error': '$failure'});
    }
  }

  Future<void> leave() async {
    if (!_active) return;
    _active = false;
    notifyListeners();
    try {
      await _mode.exit();
    } on Object catch (failure) {
      FundusLog.instance.warn('fullscreen.exit', {'error': '$failure'});
    }
  }
}
