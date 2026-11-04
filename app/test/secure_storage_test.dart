import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/server_identity.dart';

class MemorySecureStorage extends FlutterSecureStorage {
  final values = <String, String>{};
  bool failWrites = false;
  bool ignoreWrites = false;
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrites) throw StateError('Unavailable');
    if (!ignoreWrites && value != null) values[key] = value;
  }
}

void main() {
  late Directory root;
  late File file;
  late MemorySecureStorage storage;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-secure-test-');
    file = File('${root.path}/device.json');
    await file.writeAsString(
      jsonEncode({'device_key': 'existing', 'tmdb_key': 'legacy-secret'}),
    );
    storage = MemorySecureStorage();
  });
  tearDown(() => root.delete(recursive: true));
  test('legacy credentials migrate without appearing in preferences', () async {
    final settings = await AppSettings.load(
      settingsFile: file,
      storage: storage,
    );
    expect(settings.tmdbKey, 'legacy-secret');
    expect(storage.values['tmdb_key'], jsonEncode('legacy-secret'));
    expect(await file.readAsString(), isNot(contains('legacy-secret')));
    await Future.wait([
      settings.setTmdbKey('new-secret'),
      settings.setNavigationCollapsed(true),
    ]);
    expect(storage.values['tmdb_key'], jsonEncode('new-secret'));
    expect(await file.readAsString(), isNot(contains('new-secret')));
  });
  test(
    'unavailable keychain never writes new plaintext or destroys legacy keys',
    () async {
      storage.failWrites = true;
      final before = await file.readAsString();
      final settings = await AppSettings.load(
        settingsFile: file,
        storage: storage,
      );
      await settings.setTmdbKey('session-only');
      expect(settings.secureStorageAvailable, isFalse);
      expect(settings.tmdbKey, 'session-only');
      expect(await file.readAsString(), before);
    },
  );
  test(
    'without the keychain ordinary settings are still saved, credentials not',
    () async {
      storage.failWrites = true;
      final settings = await AppSettings.load(
        settingsFile: file,
        storage: storage,
      );
      await settings.setTmdbKey('session-only');
      await settings.setNavigationCollapsed(true);
      expect(settings.secureStorageAvailable, isFalse);

      final saved = jsonDecode(await file.readAsString()) as Map;
      expect(saved['navigation_collapsed'], isTrue);
      // The legacy value stays where it was; the new one is never written.
      expect(saved['tmdb_key'], 'legacy-secret');
      expect(await file.readAsString(), isNot(contains('session-only')));

      // Once the keychain works again the credential moves there and the
      // plain-text copy disappears.
      storage.failWrites = false;
      await settings.setNavigationCollapsed(false);
      expect(storage.values['tmdb_key'], jsonEncode('session-only'));
      expect(await file.readAsString(), isNot(contains('legacy-secret')));
      expect(await file.readAsString(), isNot(contains('session-only')));
    },
  );
  test(
    'server key migration retains certificate and pairing identity',
    () async {
      final directory = Directory('${root.path}/server');
      final first = await ServerIdentityStore(directory).loadOrCreate();
      final again = await ServerIdentityStore(
        directory,
        secureStorage: storage,
      ).loadOrCreate();
      expect(again.serverId, first.serverId);
      expect(again.certificateFingerprint, first.certificateFingerprint);
      expect(again.privateKeyPem, first.privateKeyPem);
      expect(await File('${directory.path}/server-key.pem').exists(), isFalse);
    },
  );
  test('failed migration readback leaves the old private key intact', () async {
    final directory = Directory('${root.path}/server');
    final first = await ServerIdentityStore(directory).loadOrCreate();
    storage.ignoreWrites = true;
    await expectLater(
      ServerIdentityStore(directory, secureStorage: storage).loadOrCreate(),
      throwsStateError,
    );
    expect(
      await File('${directory.path}/server-key.pem').readAsString(),
      first.privateKeyPem,
    );
  });
}
