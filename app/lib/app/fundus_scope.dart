import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../data/library_controller.dart';
import '../data/work_filter.dart';
import '../data/work_view.dart';
import '../media/playback_controller.dart';
import 'app_navigation.dart';
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
  });

  final AppSettings settings;
  final LibraryController library;

  /// Supplied by tests with a stand-in engine; the app builds its own.
  final PlaybackController? player;
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
  WorkFilter _filter = const WorkFilter();
  int _revision = 0;

  AppSettings get settings => widget.settings;
  LibraryController get library => widget.library;
  WorkFilter get filter => _filter;

  @override
  void initState() {
    super.initState();
    navigation.addListener(_bump);
    settings.addListener(_bump);
    library.addListener(_bump);
    player.addListener(_bump);
  }

  @override
  void dispose() {
    navigation.removeListener(_bump);
    settings.removeListener(_bump);
    library.removeListener(_bump);
    player.removeListener(_bump);
    // A player handed in from outside is the caller's to dispose.
    if (widget.player == null) player.dispose();
    navigation.dispose();
    super.dispose();
  }

  void _bump() => setState(() => _revision++);

  void setFilter(WorkFilter value) => setState(() => _filter = value);

  /// Starts or resumes a work. One entry point, whatever the media type — the
  /// controller picks its byte source, the screens do not.
  Future<void> play(WorkView work) async {
    final vault = library.library;
    if (vault == null) return;
    await player.open(vault, work);
    if (player.failure == null) library.refresh();
  }

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
