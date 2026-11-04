import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/remote_player.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus_server/fundus_server.dart';

import 'playback_controller_test.dart' show FakeEngine, waitForPlayback;

/// The phone asks, this machine's player answers — only for the vault that
/// is open here.
void main() {
  late Directory root;
  late LibraryController library;
  late FakeEngine engine;
  late PlaybackController player;
  late PlayerRemoteControl remote;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-remote-player-');
    final book = Directory('${root.path}/Hörbücher/Karl May/Der Schacht')
      ..createSync(recursive: true);
    File('${book.path}/01.mp3').writeAsBytesSync(List.filled(64, 1));
    library = LibraryController();
    await library.open(root, createIfMissing: true);
    await library.scan();
    engine = FakeEngine();
    player = PlaybackController(engine: engine, deviceId: 'mac');
    remote = PlayerRemoteControl(
      player: player,
      library: library,
      play: (work) => player.open(library.library!, work),
    );
  });

  tearDown(() async {
    player.dispose();
    await library.library?.flushSidecarWrites();
    library.dispose();
    await root.delete(recursive: true);
  });

  test('a work of the open vault starts and can be paused', () async {
    expect(remote.state().isIdle, isTrue);
    final work = library.works.single;
    final libraryId = library.library!.manifest.libraryId;

    expect(await remote.playWork('another-library', work.id), isFalse);
    expect(await remote.playWork(libraryId, work.id), isTrue);
    await waitForPlayback(player, () => player.isPlaybackRequested);
    final state = remote.state();
    expect(state.workId, work.id);
    expect(state.libraryId, libraryId);
    expect(state.playing, isTrue);

    await remote.command(FundusRemoteAction.pause);
    expect(engine.playing, isFalse);
    await remote.command(
      FundusRemoteAction.seek,
      position: const Duration(minutes: 2),
    );
    expect(engine.seeks.last, const Duration(minutes: 2));
  });
}
