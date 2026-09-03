import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../data/library_controller.dart';
import '../data/work_filter.dart';
import '../data/media_type.dart';
import '../data/work_view.dart';
import '../media/capture.dart';
import '../media/playback_controller.dart';
import '../media/reader_controller.dart';
import '../media/text_reader_controller.dart';
import 'app_navigation.dart';
import 'fullscreen.dart';
import 'storage_access.dart';
import 'app_settings.dart';

/// The app's shared state, handed down once instead of threaded through every
/// constructor.
class FundusScope extends StatefulWidget {
  const FundusScope({
    super.key,
    required this.settings,
    required this.library,
    required this.child,
    this.player,
    this.reader,
    this.textReader,
    this.fullscreen,
    this.captureSink = const FileCaptureSink(),
    this.storage = const PlatformStorageAccess(),
  });

  final AppSettings settings;
  final LibraryController library;

  /// Supplied by tests with a stand-in engine; the app builds its own.
  final PlaybackController? player;

  /// Same for the page reader.
  final ReaderController? reader;

  /// And for the text reader.
  final TextReaderController? textReader;

  /// And for the window: a test must not ask the window manager for anything.
  final FullscreenController? fullscreen;

  /// Where a saved page or frame goes. The default opens a system dialog.
  final CaptureSink captureSink;

  /// Whether the device lets the app read its files. Only Android asks.
  final StorageAccess storage;
  final Widget child;

  static FundusScopeState of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_FundusScopeMarker>();
    assert(scope != null, 'FundusScope fehlt über diesem Widget.');
    return scope!.state;
  }

  @override
  State<FundusScope> createState() => FundusScopeState();
}

class FundusScopeState extends State<FundusScope> {
  final navigation = AppNavigation();
  late final PlaybackController player =
      widget.player ?? PlaybackController(deviceId: widget.settings.deviceKey);
  late final ReaderController reader =
      widget.reader ?? ReaderController(deviceId: widget.settings.deviceKey);
  late final TextReaderController textReader =
      widget.textReader ??
      TextReaderController(deviceId: widget.settings.deviceKey);
  late final FullscreenController fullscreen =
      widget.fullscreen ?? FullscreenController();
  WorkFilter _filter = const WorkFilter();
  int _revision = 0;

  AppSettings get settings => widget.settings;
  CaptureSink get captureSink => widget.captureSink;
  StorageAccess get storage => widget.storage;
  LibraryController get library => widget.library;
  WorkFilter get filter => _filter;

  @override
  void initState() {
    super.initState();
    navigation.addListener(_bump);
    settings.addListener(_bump);
    library.addListener(_bump);
    player.addListener(_bump);
    reader.addListener(_bump);
    textReader.addListener(_bump);
    fullscreen.addListener(_bump);
  }

  @override
  void dispose() {
    navigation.removeListener(_bump);
    settings.removeListener(_bump);
    library.removeListener(_bump);
    player.removeListener(_bump);
    reader.removeListener(_bump);
    textReader.removeListener(_bump);
    fullscreen.removeListener(_bump);
    // A controller handed in from outside is the caller's to dispose.
    if (widget.player == null) player.dispose();
    if (widget.reader == null) reader.dispose();
    if (widget.textReader == null) textReader.dispose();
    if (widget.fullscreen == null) fullscreen.dispose();
    navigation.dispose();
    super.dispose();
  }

  void _bump() => setState(() => _revision++);

  void setFilter(WorkFilter value) => setState(() => _filter = value);

  /// Starts or resumes a work. One entry point, whatever the media type — a
  /// screen never decides between a player and a reader, and neither asks
  /// where the bytes come from.
  Future<void> play(WorkView work) async {
    final vault = library.library;
    if (vault == null) return;
    if (ReaderController.handles(work)) {
      // A comic in the audio player is silence with a progress bar: pages and
      // seconds are different units, so they get different controllers.
      await player.close();
      await reader.open(vault, work);
      if (reader.failure == null) library.refresh();
      return;
    }
    if (TextReaderController.handles(work)) {
      await player.close();
      await textReader.open(vault, work);
      if (textReader.failure == null) library.refresh();
      return;
    }
    final unsupported = _missingReaderFor(work);
    if (unsupported != null) {
      player.reject(work, unsupported);
      return;
    }
    await player.open(vault, work);
    if (player.failure == null) library.refresh();
  }

  /// The media types whose viewer is still missing. Naming them is the honest
  /// answer; handing the file to the audio engine is not.
  ///
  /// Only photos are left: a gallery is not a player, and an album of
  /// pictures handed to libmpv would be a slideshow nobody asked for.
  String? _missingReaderFor(WorkView work) =>
      work.mediaType?.progressKind == ProgressKind.none
      ? 'Die Fotoansicht fehlt noch — dieses Werk lässt sich noch nicht öffnen.'
      : null;

  /// Opens a media type. The filter follows the place, so switching areas
  /// never leaves a stale filter behind that would explain an empty screen.
  void openMediaType(String? mediaTypeId) {
    setState(() {
      _filter = _filter.copyWith(
        mediaTypeId: mediaTypeId,
        clearMediaType: mediaTypeId == null,
        text: '',
      );
    });
    navigation.go(LibraryRoute(mediaTypeId: mediaTypeId));
  }

  /// Shell settings are device-bound but portable: they live in the vault so
  /// a reinstall does not cost them, keyed by this device.
  static const shellProfileKind = 'shell';

  Future<void> setThemeMode(ThemeMode mode) async {
    await settings.setThemeMode(mode);
    await _writeShellProfile();
  }

  /// Fullscreen means the whole screen: the window fills it and the chrome
  /// of whatever is open steps out of the way. Leaving brings it back — a
  /// player without controls and without a way to find them is a trap.
  Future<void> toggleFullscreen() async {
    final entering = !fullscreen.isActive;
    await fullscreen.toggle();
    if (entering) {
      if (player.isExpanded && player.showsChrome) player.toggleChrome();
      if (reader.isOpen && reader.showsChrome) reader.toggleChrome();
      if (textReader.isOpen && textReader.showsChrome) {
        textReader.toggleChrome();
      }
      return;
    }
    player.showChrome();
    reader.showChrome();
    textReader.showChrome();
  }

  /// Leaves fullscreen and puts the chrome back, whatever is open.
  Future<void> leaveFullscreen() async {
    await fullscreen.leave();
    player.showChrome();
    reader.showChrome();
    textReader.showChrome();
  }

  /// Shows or hides the list beside the player. It is a device setting like
  /// the theme, so it travels in the vault and survives a reinstall.
  Future<void> setPlayerPanelVisible(bool value) async {
    await settings.setPlayerPanelVisible(value);
    await _writeShellProfile();
  }

  Future<void> setDensity(FundusDensity density) async {
    await settings.setDensity(density);
    await _writeShellProfile();
  }

  /// Takes another device's settings over onto this one.
  ///
  /// Only the settings travel — the key stays this device's, so adopting can
  /// never make two installations claim the same identity.
  Future<void> adoptDeviceProfile(DeviceProfile other) async {
    final shell = other.settingsFor(shellProfileKind);
    final theme = shell['theme_mode'];
    if (theme is String) {
      await settings.setThemeMode(
        ThemeMode.values.firstWhere(
          (mode) => mode.name == theme,
          orElse: () => settings.themeMode,
        ),
      );
    }
    final panel = shell['player_panel_visible'];
    if (panel is bool) await settings.setPlayerPanelVisible(panel);
    final density = shell['density'];
    if (density is String) {
      await settings.setDensity(
        density == 'compact'
            ? FundusDensity.compact
            : FundusDensity.comfortable,
      );
    }
    final library = this.library.library;
    if (library == null || library.isReadOnly) return;
    final mine =
        await library.loadDeviceProfile(settings.deviceKey) ??
        DeviceProfile(
          key: settings.deviceKey,
          displayName: settings.deviceName,
          platform: defaultTargetPlatform.name,
        );
    var merged = mine;
    for (final entry in other.settings.entries) {
      final values = other.settingsFor(entry.key);
      if (values.isNotEmpty) merged = merged.withSettings(entry.key, values);
    }
    await library.saveDeviceProfile(merged);
  }

  /// Reads this device's stored settings back after a reinstall.
  Future<void> restoreShellProfile() async {
    final library = this.library.library;
    if (library == null) return;
    final profile = await library.loadDeviceProfile(settings.deviceKey);
    if (profile == null) {
      await _writeShellProfile();
      return;
    }
    await adoptDeviceProfile(profile);
  }

  Future<void> _writeShellProfile() async {
    final library = this.library.library;
    if (library == null || library.isReadOnly) return;
    final existing = await library.loadDeviceProfile(settings.deviceKey);
    final profile =
        (existing ??
                DeviceProfile(
                  key: settings.deviceKey,
                  displayName: settings.deviceName,
                  platform: defaultTargetPlatform.name,
                ))
            .withSettings(shellProfileKind, {
              'theme_mode': settings.themeMode.name,
              'density': settings.density.name,
              'player_panel_visible': settings.playerPanelVisible,
            });
    await library.saveDeviceProfile(profile);
  }

  @override
  Widget build(BuildContext context) =>
      _FundusScopeMarker(state: this, revision: _revision, child: widget.child);
}

class _FundusScopeMarker extends InheritedWidget {
  const _FundusScopeMarker({
    required this.state,
    required this.revision,
    required super.child,
  });

  final FundusScopeState state;
  final int revision;

  @override
  bool updateShouldNotify(_FundusScopeMarker oldWidget) =>
      revision != oldWidget.revision;
}
