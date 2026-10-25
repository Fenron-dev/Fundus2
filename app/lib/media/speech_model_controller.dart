import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app_settings.dart';
import 'phonon_model_store.dart';

typedef SpeechModelServer = ({
  String id,
  String name,
  FundusRemoteClient client,
});

/// One installation-local CPU model, provisioned over the existing paired
/// connection. Native code remains part of the app, never a network download.
final class SpeechModelController extends ChangeNotifier {
  SpeechModelController({
    required this.settings,
    required this.servers,
    Future<Directory> Function()? storageRoot,
  }) : _storageRoot = storageRoot ?? getApplicationSupportDirectory;

  final AppSettings settings;
  final List<SpeechModelServer> Function() servers;
  final Future<Directory> Function() _storageRoot;
  final Set<String> _attempted = {};
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

  Future<String?> ensureAvailable({bool retry = false}) {
    if (_disposed) return Future.value(null);
    final configured = settings.phononModelDirectory;
    if (configured != null && Directory(configured).existsSync()) {
      return Future.value(configured);
    }
    if (_operation != null) return _operation!;
    if (!retry && servers().every((server) => _attempted.contains(server.id))) {
      return Future.value(null);
    }
    if (retry) _attempted.clear();
    final operation = _install();
    _operation = operation;
    unawaited(
      operation.then((_) {
        if (identical(_operation, operation)) _operation = null;
        _notify();
      }),
    );
    _notify();
    return operation;
  }

  Future<String?> _install() async {
    final originalSetting = settings.phononModelDirectory;
    _failure = null;
    for (final server in servers()) {
      if (!_attempted.add(server.id)) continue;
      _serverName = server.name;
      _received = 0;
      _total = 0;
      _notify();
      Directory? staging;
      try {
        final model = await server.client.speechModel();
        if (model == null) continue;
        if (_disposed) return null;
        _total = model.totalBytes;
        _notify();
        final support = await _storageRoot();
        final root = Directory(p.join(support.path, 'phonon-models'));
        await root.create(recursive: true);
        staging = await root.createTemp('.download-');
        var completed = 0;
        var lastNotification = DateTime.fromMillisecondsSinceEpoch(0);
        for (var index = 0; index < model.files.length; index++) {
          if (_disposed) {
            throw const FormatException('Modellübertragung beendet.');
          }
          final entry = model.files[index];
          final file = File(
            p.joinAll([staging.path, ...entry.path.split('/')]),
          );
          await file.parent.create(recursive: true);
          await server.client.downloadSpeechModelFile(
            model: model,
            index: index,
            destination: file,
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
        staging = null;
        await settings.setPhononModelDirectory(installed.path);
        _failure = null;
        return installed.path;
      } on Object catch (error) {
        if (error is FundusRemoteException && error.statusCode == 409) {
          _failure =
              'Bei „${server.name}“ fehlt ein vollständiges CPU-Sprachmodell mit Stimme. Bitte dort unter Geräte & Abgleich einrichten.';
        } else {
          _failure =
              'Sprachmodell von „${server.name}“ konnte nicht geladen werden: $error';
        }
      } finally {
        try {
          if (staging != null && await staging.exists()) {
            await staging.delete(recursive: true);
          }
        } on FileSystemException {
          // A locked, incomplete staging directory is never activated.
        }
      }
    }
    _failure ??=
        'Kein gekoppelter Server bietet ein CPU-Sprachmodell an. Bitte am Server unter Geräte & Abgleich einrichten und erneut laden.';
    return null;
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
