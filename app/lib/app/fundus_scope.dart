import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/library_controller.dart';
import '../data/server_host.dart';
import '../data/peer_connection.dart';
import '../data/peer_library.dart';
import '../data/sync_controller.dart';
import '../data/work_filter.dart';
import '../data/media_type.dart';
import '../data/work_view.dart';
import '../media/capture.dart';
import '../media/peer_file_cache.dart';
import '../media/playback_controller.dart';
import '../media/reader_controller.dart';
import '../media/text_reader_controller.dart';
import 'app_navigation.dart';
import 'fullscreen.dart';
import 'pairing_scanner.dart';
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
    this.sync,
    this.host,
    this.peerLibrary,
    this.captureSink = const FileCaptureSink(),
    this.storage = const PlatformStorageAccess(),
    this.scanner = const CameraPairingScanner(),
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

  /// And for the sync, so a test never reaches for the network.
  final SyncController? sync;

  /// And for the served side, so a test never opens a port.
  final ServerHostController? host;

  /// And for a paired library, so a test never reaches for one.
  final PeerLibraryController? peerLibrary;

  /// Where a saved page or frame goes. The default opens a system dialog.
  final CaptureSink captureSink;

  /// Whether the device lets the app read its files. Only Android asks.
  final StorageAccess storage;

  /// How a pairing code is read off the other screen. The default opens the
  /// camera, which a test has none of.
  final PairingScanner scanner;
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
  late final SyncController sync =
      widget.sync ??
      SyncController(settings: widget.settings, library: widget.library);
  late final ServerHostController host =
      widget.host ??
      ServerHostController(settings: widget.settings, library: widget.library);
  late final PeerLibraryController peerLibrary =
      widget.peerLibrary ??
      PeerLibraryController(settings: widget.settings, library: widget.library);
  WorkFilter _filter = const WorkFilter();
  int _revision = 0;

  AppSettings get settings => widget.settings;
  CaptureSink get captureSink => widget.captureSink;
  StorageAccess get storage => widget.storage;
  PairingScanner get scanner => widget.scanner;
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
    sync.addListener(_bump);
    host.addListener(_bump);
    peerLibrary.addListener(_bump);
    peerLibrary.addListener(_handOverProxy);
  }

  /// Keeps the players pointed at the peer that is open.
  ///
  /// The player and the readers never learn who the peer is; they are handed
  /// the one thing they need — a door to fetch bytes through — and it is null
  /// when there is no peer, which is exactly what "this is a local library"
  /// means to them.
  Future<void> _handOverProxy() async {
    final proxy = peerLibrary.proxy;
    player.proxy = proxy;
    if (proxy == null) {
      reader.cache = null;
      textReader.cache = null;
      return;
    }
    final support = await getApplicationSupportDirectory();
    final cache = PeerFileCache(
      proxy: proxy,
      directory: Directory(
        p.join(support.path, 'peer-cache', peerLibrary.peer?.serverId ?? 'x'),
      ),
    );
    reader.cache = cache;
    textReader.cache = cache;
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
    sync.removeListener(_bump);
    host.removeListener(_bump);
    peerLibrary.removeListener(_bump);
    peerLibrary.removeListener(_handOverProxy);
    // A controller handed in from outside is the caller's to dispose.
    if (widget.player == null) player.dispose();
    if (widget.reader == null) reader.dispose();
    if (widget.textReader == null) textReader.dispose();
    if (widget.fullscreen == null) fullscreen.dispose();
    if (widget.sync == null) sync.dispose();
    if (widget.host == null) host.dispose();
    if (widget.peerLibrary == null) peerLibrary.dispose();
    navigation.dispose();
    super.dispose();
  }

  void _bump() => setState(() => _revision++);

  void setFilter(WorkFilter value) => setState(() => _filter = value);

  /// Opens the library of a paired Fundus.
  ///
  /// The index is written here, the files stay there. Afterwards nothing in
  /// the app is aware of the difference except the origin mark on a tile.
  Future<void> openPeerLibrary(PeerConnection peer) async {
    final opened = await peerLibrary.open(peer);
    if (!opened) return;
    await _handOverProxy();
    navigation.reset(const DashboardRoute());
  }

  /// Lets go of a paired library and returns to the vault chooser.
  Future<void> closePeerLibrary() async {
    await peerLibrary.close();
    await _handOverProxy();
    library.close();
    navigation.reset(const VaultRoute());
  }

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
