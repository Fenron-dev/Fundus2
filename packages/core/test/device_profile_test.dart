import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-devices-');
  });

  tearDown(() => root.delete(recursive: true));

  test(
    'device settings survive a reinstall because they live in the vault',
    () async {
      final library = await FundusLibrary.create(root);
      await library.saveDeviceProfile(
        const DeviceProfile(
          key: 'device-a',
          displayName: 'S21 FE',
          platform: 'android',
        ).withSettings('manga', {
          'reading_direction': 'rtl',
          'double_page': true,
        }),
      );
      library.close();

      // A reinstall: new app storage, same vault.
      final reopened = await FundusLibrary.open(root);
      addTearDown(reopened.close);

      final profile = await reopened.loadDeviceProfile('device-a');
      expect(profile, isNotNull);
      expect(profile!.displayName, 'S21 FE');
      expect(profile.platform, 'android');
      expect(profile.settingsFor('manga')['reading_direction'], 'rtl');
      expect(profile.settingsFor('manga')['double_page'], isTrue);
      expect(profile.settingsFor('epub'), isEmpty);
    },
  );

  test('profiles of other devices are offered for adoption', () async {
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);

    await library.saveDeviceProfile(
      const DeviceProfile(key: 'a', displayName: 'Studio-Mac'),
    );
    await library.saveDeviceProfile(
      const DeviceProfile(key: 'b', displayName: 'Tab S6 lite'),
    );

    final profiles = await library.listDeviceProfiles();
    expect(profiles.map((p) => p.displayName), ['Studio-Mac', 'Tab S6 lite']);
  });

  test('a device key cannot escape the profile directory', () async {
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);

    await library.saveDeviceProfile(
      const DeviceProfile(key: '../../escape', displayName: 'Böse'),
    );

    final outside = File('${root.parent.path}/escape.yaml');
    expect(await outside.exists(), isFalse);
    expect(Directory('${root.path}/_fundus/devices').listSync(), hasLength(1));
  });

  test('a deleted profile is gone', () async {
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);

    await library.saveDeviceProfile(
      const DeviceProfile(key: 'a', displayName: 'Studio-Mac'),
    );
    await library.deleteDeviceProfile('a');

    expect(await library.loadDeviceProfile('a'), isNull);
    expect(await library.listDeviceProfiles(), isEmpty);
  });

  test('an unreadable profile does not break the list', () async {
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);

    await library.saveDeviceProfile(
      const DeviceProfile(key: 'a', displayName: 'Studio-Mac'),
    );
    await File(
      '${root.path}/_fundus/devices/broken.yaml',
    ).writeAsString('{ this is not: [valid');

    final profiles = await library.listDeviceProfiles();
    expect(profiles.map((p) => p.key), ['a']);
  });
}
