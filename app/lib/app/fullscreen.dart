import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Making the window itself go fullscreen.
///
/// Behind an interface because it is the one thing in the reader and the
/// player that talks to the operating system: a test must be able to watch it
/// without a window manager underneath.
abstract interface class FullscreenMode {
  Future<void> enter();
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
  Future<void> enter() async {
    if (_isMobile) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: const [],
      );
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

  Future<void> toggle() => _active ? leave() : enter();

  Future<void> enter() async {
    if (_active) return;
    _active = true;
    notifyListeners();
    await _mode.enter();
  }

  Future<void> leave() async {
    if (!_active) return;
    _active = false;
    notifyListeners();
    await _mode.exit();
  }
}
