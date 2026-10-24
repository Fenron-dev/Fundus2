import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

LibraryPlaybackTrack track(
  String id, {
  int size = 100,
  bool local = false,
  String? title,
}) => LibraryPlaybackTrack(
  fileId: id,
  relativePath: '',
  absolutePath: '',
  title: title ?? '$id.mp4',
  sourceId: local ? 'local' : 'peer-host',
  index: 0,
  sizeBytes: size,
);

void main() {
  OfflinePlan plan({
    OfflinePolicy policy = const OfflinePolicy(
      enabled: true,
      nextFiles: 2,
      storageBudgetBytes: 500,
    ),
    OfflineConditions conditions = const OfflineConditions(wifi: true),
    List<OfflineTarget>? targets,
    Set<String> here = const {},
    Set<String> queued = const {},
    int stored = 0,
    int reserved = 0,
  }) => OfflinePlan.preview(
    policy: policy,
    conditions: conditions,
    targets:
        targets ??
        [
          OfflineTarget(
            workId: 'w',
            tracks: [track('1'), track('2'), track('3')],
          ),
        ],
    alreadyHere: here,
    alreadyQueued: queued,
    storedBytes: stored,
    reservedBytes: reserved,
  );

  test('rules opt in and survive a strictly versioned round trip', () {
    expect(const OfflinePolicy().enabled, isFalse);
    final policy = OfflinePolicy.fromJson(const OfflinePolicy().toJson());
    expect(policy.nextFiles, 3);
    expect(policy.wifiOnly, isTrue);
    expect(plan(policy: policy).deferred['w'], OfflineDeferral.disabled);
    expect(
      () => OfflinePolicy.fromJson(policy.toJson()..['format_version'] = 2),
      throwsFormatException,
    );
    expect(
      () => OfflinePolicy.fromJson(policy.toJson()..['next_files'] = 0),
      throwsFormatException,
    );
  });

  test('unknown wifi/charging never silently allows a transfer', () {
    expect(
      plan(conditions: const OfflineConditions()).deferred['w'],
      OfflineDeferral.wifiRequired,
    );
    expect(
      plan(
        policy: const OfflinePolicy(enabled: true, chargingOnly: true),
      ).deferred['w'],
      OfflineDeferral.chargingRequired,
    );
    expect(
      plan(
        conditions: const OfflineConditions(wifi: true, foreground: false),
      ).deferred['w'],
      OfflineDeferral.background,
    );
  });

  test('starts at the chosen personal file, not the newest file', () {
    final result = plan(
      targets: [
        OfflineTarget(
          workId: 'w',
          tracks: [track('1'), track('2'), track('3')],
          startFileId: '2',
        ),
      ],
    );
    expect(result.files.map((file) => file.track.fileId), ['2', '3']);
    expect(result.bytesToDownload, 200);
  });

  test(
    'a finished selected file is excluded, a missing anchor is not guessed',
    () {
      expect(
        plan(
          targets: [
            OfflineTarget(
              workId: 'w',
              tracks: [track('1'), track('2')],
              startFileId: '1',
              startFileFinished: true,
            ),
          ],
        ).files.single.track.fileId,
        '2',
      );
      final result = plan(
        targets: [
          OfflineTarget(
            workId: 'w',
            tracks: [track('1')],
            startFileId: 'removed',
          ),
        ],
      );
      expect(result.files, isEmpty);
      expect(result.deferred['w'], OfflineDeferral.positionUnavailable);
    },
  );

  test(
    'EPUB/CBZ count as whole physical files, not advertised chapter downloads',
    () {
      final result = plan(
        targets: [
          OfflineTarget(
            workId: 'w',
            tracks: [
              track('book', title: 'Novel.EPUB'),
              track('comic', title: 'Manga.CBZ'),
            ],
          ),
        ],
      );
      expect(result.files, hasLength(2));
      expect(result.files.every((file) => file.isContainer), isTrue);
    },
  );

  test(
    'copies and queued files occupy the look-ahead window without refilling forever',
    () {
      final result = plan(
        here: {'1'},
        queued: {'2'},
        stored: 100,
        reserved: 100,
      );
      expect(result.files, isEmpty);
      expect(result.deferred, isEmpty);
    },
  );

  test(
    'hidden copies and reserved downloads still consume the global budget',
    () {
      final result = plan(stored: 350, reserved: 100);
      expect(result.files, isEmpty);
      expect(result.deferred['w'], OfflineDeferral.budgetExceeded);
    },
  );

  test(
    'an oversized first file is not skipped in favour of a later episode',
    () {
      final result = plan(
        targets: [
          OfflineTarget(
            workId: 'w',
            tracks: [track('1', size: 600), track('2')],
          ),
        ],
      );
      expect(result.files, isEmpty);
      expect(result.deferred['w'], OfflineDeferral.budgetExceeded);
    },
  );

  test('unknown sizes are not treated as zero-cost media', () {
    final result = plan(
      targets: [
        OfflineTarget(workId: 'w', tracks: [track('1', size: 0), track('2')]),
      ],
    );
    expect(result.files, isEmpty);
    expect(result.deferred['w'], OfflineDeferral.sizeUnknown);
  });

  test(
    'explicit priority is deterministic across works without duplicate files',
    () {
      final targets = [
        OfflineTarget(
          workId: 'a',
          tracks: [track('1'), track('1'), track('2')],
        ),
        OfflineTarget(workId: 'b', tracks: [track('2'), track('3')]),
      ];
      final first = plan(targets: targets, stored: 250);
      final again = plan(targets: targets, stored: 250);
      expect(first.files.map((file) => file.track.fileId), ['1', '2']);
      expect(first.bytesToDownload, again.bytesToDownload);
      expect(first.deferred['b'], OfflineDeferral.budgetExceeded);
    },
  );

  test('local originals are never selected for download', () {
    final result = plan(
      targets: [
        OfflineTarget(workId: 'w', tracks: [track('1', local: true)]),
      ],
    );
    expect(result.files, isEmpty);
  });

  test('negative storage accounting cannot grant a larger budget', () {
    expect(() => plan(stored: -1), throwsArgumentError);
    expect(() => plan(reserved: -1), throwsArgumentError);
  });
}
