import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

LibraryPlaybackProgress checkpoint({
  int revision = 1,
  bool stopped = true,
  String device = 'phone',
  double at = 12,
}) => LibraryPlaybackProgress(
  workId: 'work',
  fileId: '2',
  position: MediaPosition(
    kind: MediaPositionKind.time,
    numericValue: at,
    fileId: '2',
  ),
  finished: false,
  revision: revision,
  updatedAt: DateTime.utc(2026, 10, 24),
  deviceId: device,
  checkpoint: stopped,
);

void main() {
  test('cleanup remains off when reading old policy formats', () {
    final old = const OfflinePolicy().toJson()..remove('remove_consumed');
    expect(OfflinePolicy.fromJson(old).removeConsumed, isFalse);
    expect(
      () => OfflinePolicy.fromJson(old..['remove_consumed'] = 'yes'),
      throwsFormatException,
    );
  });
  test('receipt is bound to the exact local checkpoint and device', () {
    final progress = checkpoint();
    final receipt = OfflineCheckpointReceipt(
      vaultId: 'vault',
      sourceId: 'source',
      peerServerId: 'server',
      peerLibraryId: 'library',
      deviceId: 'phone',
      workId: 'work',
      fingerprint: OfflineCheckpointReceipt.fingerprintOf(progress),
      confirmedAt: DateTime.utc(2026, 10, 24),
    );
    final restored = OfflineCheckpointReceipt.fromJson(receipt.toJson());
    expect(restored.matches(progress, currentDeviceId: 'phone'), isTrue);
    expect(restored.matches(progress, currentDeviceId: 'tablet'), isFalse);
    expect(
      restored.matches(checkpoint(revision: 2), currentDeviceId: 'phone'),
      isFalse,
    );
    expect(
      restored.matches(checkpoint(stopped: false), currentDeviceId: 'phone'),
      isFalse,
    );
    expect(
      restored.matches(checkpoint(at: 13), currentDeviceId: 'phone'),
      isFalse,
    );
    expect(
      () => OfflineCheckpointReceipt.fromJson(
        receipt.toJson()..['format_version'] = 2,
      ),
      throwsFormatException,
    );
    expect(
      () => OfflineCheckpointReceipt.fromJson(
        receipt.toJson()..['fingerprint'] = 'bad',
      ),
      throwsFormatException,
    );
  });
  final tracks = [
    for (var i = 1; i <= 5; i++)
      LibraryPlaybackTrack(
        fileId: '$i',
        relativePath: '',
        absolutePath: '',
        title: '$i.epub',
        index: i,
        sourceId: 'peer',
      ),
  ];
  Set<String> select({
    bool confirmed = true,
    String? current = '2',
    bool finished = false,
    Set<String> done = const {'1', '4'},
    Set<String> used = const {},
  }) => OfflineCleanup.candidates(
    checkpointConfirmed: confirmed,
    tracks: tracks,
    finishedFileIds: done,
    offlineFileIds: {'1', '2', '3', '4', '5'},
    currentFileId: current,
    currentFileFinished: finished,
    nextFiles: 2,
    inUse: used,
  );
  test(
    'skipped files do not count as consumed; upcoming unread files stay',
    () {
      expect(select(), {'1', '4'});
      expect(select(done: {}), isEmpty);
    },
  );
  test('missing confirmation or unknown anchor never authorizes cleanup', () {
    expect(select(confirmed: false), isEmpty);
    expect(select(current: null), isEmpty);
    expect(select(current: 'removed'), isEmpty);
  });
  test(
    'active and currently re-read files remain even with old done flags',
    () {
      expect(select(done: {'1', '2', '4'}, used: {'1'}), {'4'});
      expect(select(finished: true, done: {'1', '2', '4'}), {'1', '2', '4'});
    },
  );
  test('look-ahead does not redownload previously consumed future files', () {
    final plan = OfflinePlan.preview(
      policy: const OfflinePolicy(enabled: true, nextFiles: 2),
      conditions: const OfflineConditions(wifi: true),
      targets: [
        OfflineTarget(
          workId: 'work',
          tracks: [
            for (final track in tracks)
              LibraryPlaybackTrack(
                fileId: track.fileId,
                relativePath: '',
                absolutePath: '',
                title: track.title,
                index: track.index,
                sourceId: 'peer',
                sizeBytes: 1,
              ),
          ],
          startFileId: '2',
          finishedFileIds: {'1', '4'},
        ),
      ],
      alreadyHere: {},
      alreadyQueued: {},
      storedBytes: 0,
    );
    expect(plan.files.map((file) => file.track.fileId), ['2', '3']);
  });
}
