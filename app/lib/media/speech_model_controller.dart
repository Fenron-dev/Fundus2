import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app_settings.dart';
import 'phonon_model_store.dart';

typedef SpeechModelServer = ({
  String id,
  String name,
  FundusRemoteClient client,
});

/// What a paired server offers, before anything is downloaded.
typedef SpeechModelOffer = ({
  SpeechModelServer server,
  SpeechModelManifest model,
});

/// One installation-local CPU model, provisioned over the existing paired
/// connection. Native code remains part of the app, never a network download.
///
/// Nothing is fetched on its own: a model is several dozen to a few hundred
/// megabytes, and whether that happens now, over this network and on this
/// phone's storage is the person's decision. [findOffer] only asks what is
/// there; [install] is what the confirmation button calls.
final class SpeechModelController extends ChangeNotifier {
  SpeechModelController({
    required this.settings,
    required this.servers,
    Future<Directory> Function()? storageRoot,
  }) : _storageRoot = storageRoot ?? getApplicationSupportDirectory;

  final AppSettings settings;
  final List<SpeechModelServer> Function() servers;
  final Future<Directory> Function() _storageRoot;
  Future<String?>? _operation;
  bool _disposed = false;
  String? _failure;
  String? _serverName;
  int _received = 0;
  int _total = 0;
  bool get isBusy => _operation != null;
  String? get failure => _failure;
  String? get serverName => _serverName;
  double? get progress => _total > 0 ? _received / _total : null;

  /// The model already set up on this installation, if its folder exists.
  String? get installed {
    final configured = settings.phononModelDirectory;
    return configured != null && Directory(configured).existsSync()
        ? configured
        : null;
  }

  /// Asks the paired servers what they offer, without transferring weights.
  Future<SpeechModelOffer?> findOffer() async {
    _failure = null;
    String? failure;
    for (final server in servers()) {
      if (_disposed) return null;
      try {
        final model = await server.client.speechModel();
        if (model != null) return (server: server, model: model);
      } on Object catch (error) {
        failure = _describe(server, error);
      }
    }
    _failure =
        failure ??
        'Kein gekoppelter Server bietet ein CPU-Sprachmodell an. Bitte am Server unter Geräte & Abgleich einrichten und erneut laden.';
    _notify();
    return null;
  }

  /// Downloads [offer], continuing an earlier interrupted attempt, and makes
  /// it this installation's model once every file is verified.
  Future<String?> install(SpeechModelOffer offer) {
    if (_disposed) return Future.value(null);
    if (_operation != null) return _operation!;
    final operation = _install(offer);
    _operation = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_operation, operation)) _operation = null;
        _notify();
      }),
    );
    _notify();
    return operation;
  }

  /// The installed model, or the first offer installed right away.
  ///
  /// Only for callers that have already asked — the reader and the settings
  /// go through [findOffer] and a confirmation first.
  Future<String?> ensureAvailable() {
    final present = installed;
    if (present != null) return Future.value(present);
    if (_operation != null) return _operation!;
    return _ensuring ??= () async {
      try {
        final offer = await findOffer();
        if (offer == null) return null;
        return await install(offer);
      } finally {
        _ensuring = null;
      }
    }();
  }

  Future<String?>? _ensuring;

  Future<String?> _install(SpeechModelOffer offer) async {
    final originalSetting = settings.phononModelDirectory;
    final server = offer.server;
    final model = offer.model;
    _failure = null;
    _serverName = server.name;
    _received = 0;
    _total = model.totalBytes;
    _notify();
    try {
      final support = await _storageRoot();
      final root = Directory(p.join(support.path, 'phonon-models'));
      await root.create(recursive: true);
      // A stable name per model: the next attempt continues where this one
      // stopped instead of starting again from zero.
      final staging = Directory(p.join(root.path, '.download-${model.id}'));
      await staging.create(recursive: true);
      await _removeOtherDownloads(root, keep: staging);
      var completed = 0;
      var lastNotification = DateTime.fromMillisecondsSinceEpoch(0);
      for (var index = 0; index < model.files.length; index++) {
        if (_disposed) {
          throw const FormatException('Modellübertragung beendet.');
        }
        final entry = model.files[index];
        final file = File(p.joinAll([staging.path, ...entry.path.split('/')]));
        await file.parent.create(recursive: true);
        if (await _alreadyComplete(file, entry)) {
          completed += entry.bytes;
          _received = completed;
          _notify();
          continue;
        }
        await server.client.downloadSpeechModelFile(
          model: model,
          index: index,
          destination: file,
          resume: true,
          onProgress: (received) {
            if (_disposed) {
              throw const FormatException('Modellübertragung beendet.');
            }
            _received = completed + received;
            final now = DateTime.now();
            if (now.difference(lastNotification) >=
                    const Duration(milliseconds: 100) ||
                _received == _total) {
              lastNotification = now;
              _notify();
            }
          },
        );
        completed += entry.bytes;
      }
      await File(
        p.join(staging.path, PhononModelStore.integrityFileName),
      ).writeAsString(
        jsonEncode({
          'schema_version': 1,
          'files': {for (final file in model.files) file.path: file.sha256},
        }),
        flush: true,
      );
      await PhononModelStore.verifyIntegrity(staging.path);
      if (_disposed) return null;
      if (settings.phononModelDirectory != originalSetting) {
        return settings.phononModelDirectory;
      }
      final installed = await staging.rename(
        p.join(
          root.path,
          'model-${model.id}-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await settings.setPhononModelDirectory(installed.path);
      _failure = null;
      // The model this one replaces is not needed any more.
      await pruneUnused();
      return installed.path;
    } on Object catch (error) {
      _failure = _describe(server, error);
      return null;
    }
  }

  /// Whether a file left by an earlier attempt is already the right one.
  static Future<bool> _alreadyComplete(File file, SpeechModelFile entry) async {
    if (!await file.exists() || await file.length() != entry.bytes) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() == entry.sha256) return true;
    await file.delete();
    return false;
  }

  /// Unfinished downloads of a model the server no longer offers.
  static Future<void> _removeOtherDownloads(
    Directory root, {
    required Directory keep,
  }) async {
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          !p.basename(entity.path).startsWith('.download-') ||
          p.equals(entity.path, keep.path)) {
        continue;
      }
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        // Tried again with the next download.
      }
    }
  }

  /// Every folder this installation still refers to.
  Set<String> get _referencedFolders => {
    ?settings.phononModelDirectory,
    ?settings.phononServerModelDirectory,
    for (final profile in settings.speechProfiles) ...{
      profile.modelDirectory,
      ?profile.voicesDirectory,
    },
  };

  /// Fundus-managed models nothing refers to any more.
  Future<List<({String path, int bytes})>> unusedModels() async {
    final support = await _storageRoot();
    return PhononModelStore.unusedModels(
      applicationSupportPath: support.path,
      keep: _referencedFolders,
    );
  }

  /// Removes them, and leftovers of interrupted imports. Returns bytes freed.
  Future<int> pruneUnused() async {
    final support = await _storageRoot();
    final freed = await PhononModelStore.pruneUnusedModels(
      applicationSupportPath: support.path,
      keep: _referencedFolders,
    );
    _notify();
    return freed;
  }

  static String _describe(SpeechModelServer server, Object error) {
    if (error is FundusRemoteException && error.statusCode == 409) {
      return 'Bei „${server.name}“ fehlt ein vollständiges CPU-Sprachmodell mit Stimme. Bitte dort unter Geräte & Abgleich einrichten.';
    }
    if (error is FormatException) {
      return 'Sprachmodell von „${server.name}“: ${error.message} Ein erneuter Versuch setzt den Download fort.';
    }
    return 'Sprachmodell von „${server.name}“ konnte nicht geladen werden. Ein erneuter Versuch setzt den Download fort.';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
