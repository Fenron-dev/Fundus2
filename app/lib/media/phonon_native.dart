import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fundus_core/fundus_core.dart';

import 'phonon_wave.dart';
import 'speech_engine.dart';

/// A long-lived, serial worker for the official Phonon C interface. Neither
/// model loading nor synthesis is allowed on Flutter's UI isolate.
///
/// The native library and model are optional. A missing installation produces
/// a visible error; it never falls back to cloud TTS or a different language.
final class PhononNativeEngine implements TextSpeechEngine {
  PhononNativeEngine._();

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _responses;
  ReceivePort? _errors;
  ReceivePort? _exits;
  StreamSubscription<dynamic>? _responseSubscription;
  StreamSubscription<dynamic>? _errorSubscription;
  StreamSubscription<dynamic>? _exitSubscription;
  final Map<int, Completer<Map<Object?, Object?>>> _pending = {};
  int _nextId = 0;
  bool _disposed = false;
  List<SpeechLanguage> _languages = const [];

  static Future<PhononNativeEngine> open({
    required String modelDirectory,
    required SpeechLanguage language,
  }) async {
    final engine = PhononNativeEngine._();
    try {
      await engine._start();
      final reply = await engine._request({
        'command': 'open',
        'directory': modelDirectory,
        'language': SpeechLanguageResolver.code(language),
      });
      final rawLanguages = reply['languages'];
      if (rawLanguages is List) {
        engine._languages = rawLanguages
            .whereType<String>()
            .map(SpeechLanguageResolver.parse)
            .whereType<SpeechLanguage>()
            .toSet()
            .toList(growable: false);
      }
      return engine;
    } on Object {
      await engine.dispose();
      rethrow;
    }
  }

  Future<void> _start() async {
    final responses = _responses = ReceivePort();
    final errors = _errors = ReceivePort();
    final exits = _exits = ReceivePort();
    final ready = Completer<SendPort>();
    _responseSubscription = responses.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is! Map) return;
      final reply = Map<Object?, Object?>.from(message);
      final id = reply['id'];
      if (id is int) _pending.remove(id)?.complete(reply);
    });
    void failPending(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
      for (final completer in _pending.values) {
        if (!completer.isCompleted) completer.completeError(error);
      }
      _pending.clear();
    }

    _errorSubscription = errors.listen(
      (_) => failPending(StateError('Phonon-Worker ist abgestürzt.')),
    );
    _exitSubscription = exits.listen(
      (_) => failPending(StateError('Phonon-Worker wurde beendet.')),
    );
    _isolate = await Isolate.spawn(
      _phononWorker,
      responses.sendPort,
      onError: errors.sendPort,
      onExit: exits.sendPort,
    );
    _commands = await ready.future.timeout(const Duration(seconds: 10));
  }

  Future<Map<Object?, Object?>> _request(Map<String, Object?> request) async {
    if (_disposed || _commands == null) {
      throw StateError('Phonon-Worker ist nicht geöffnet.');
    }
    final id = ++_nextId;
    final answer = Completer<Map<Object?, Object?>>();
    _pending[id] = answer;
    _commands!.send({...request, 'id': id});
    late final Map<Object?, Object?> reply;
    try {
      // A broken native call must never leave the reader waiting indefinitely.
      // Model compilation on Apple can be slow; synthesis remains bounded too.
      final timeout = request['command'] == 'open'
          ? const Duration(minutes: 3)
          : request['command'] == 'synthesize'
          ? const Duration(minutes: 5)
          : const Duration(seconds: 10);
      reply = await answer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      _isolate?.kill(priority: Isolate.immediate);
      _commands = null;
      for (final pending in _pending.values) {
        if (!pending.isCompleted) {
          pending.completeError(StateError('Phonon-Worker antwortet nicht.'));
        }
      }
      _pending.clear();
      throw StateError('Phonon-Worker antwortet nicht.');
    }
    if (reply['error'] case final String error) {
      throw StateError(error);
    }
    return reply;
  }

  /// Synthesizes exactly one bounded original-text segment. The return of this
  /// call means audio was generated, *not* that the user heard it.
  @override
  Future<List<SpeechLanguage>> availableLanguages() async => _languages;

  @override
  Future<List<String>> availableVoices(SpeechLanguage language) async {
    final reply = await _request({
      'command': 'catalogue_voices',
      'language': SpeechLanguageResolver.code(language),
    });
    final rawVoices = reply['voices'];
    if (rawVoices is! List) return const [];
    return rawVoices.whereType<String>().toList(growable: false);
  }

  @override
  Future<PhononAudio> synthesize(
    SpeechTextSegment segment, {
    required SpeechLanguage language,
    String? voice,
  }) async {
    if (segment.text.isEmpty || segment.text.length > 1000) {
      throw ArgumentError.value(segment.text.length, 'segment.text.length');
    }
    final reply = await _request({
      'command': 'synthesize',
      'text': segment.text,
      'language': SpeechLanguageResolver.code(language),
      'voice': voice,
    });
    final bytes = reply['wav'];
    final micros = reply['duration_us'];
    if (bytes is! Uint8List || micros is! int || micros <= 0) {
      throw const FormatException('Ungültige Phonon-Antwort.');
    }
    return PhononAudio(
      wav: bytes,
      duration: Duration(microseconds: micros),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    if (_commands != null) {
      try {
        await _request({
          'command': 'close',
        }).timeout(const Duration(seconds: 10));
      } on Object {
        // A stuck native call must not keep the UI waiting forever.
      }
    }
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Phonon-Worker wurde geschlossen.'));
      }
    }
    _pending.clear();
    await _responseSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _exitSubscription?.cancel();
    _responses?.close();
    _errors?.close();
    _exits?.close();
  }
}

typedef _FrameNative = Uint8 Function(Pointer<Float>, Size, Pointer<Void>);
typedef _NewNative =
    Pointer<Void> Function(Pointer<Utf8>, Uint32, Pointer<Utf8>);
typedef _NewDart = Pointer<Void> Function(Pointer<Utf8>, int, Pointer<Utf8>);
typedef _SpeakNative =
    Uint8 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<NativeFunction<_FrameNative>>,
      Pointer<Void>,
      Pointer<_PttsResult>,
    );
typedef _SpeakDart =
    int Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<NativeFunction<_FrameNative>>,
      Pointer<Void>,
      Pointer<_PttsResult>,
    );
typedef _SetNative = Uint8 Function(Pointer<Void>, Pointer<Utf8>);
typedef _SetDart = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _NamesNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

final class _PttsResult extends Struct {
  @Uint32()
  external int frames;

  @Size()
  external int samples;

  @Double()
  external double ttfaMs;

  @Double()
  external double totalMs;
}

final class _Bindings {
  _Bindings(DynamicLibrary library)
    : create = library.lookupFunction<_NewNative, _NewDart>('ptts_new'),
      speak = library.lookupFunction<_SpeakNative, _SpeakDart>('ptts_speak'),
      setVoice = library.lookupFunction<_SetNative, _SetDart>('ptts_set_voice'),
      setLanguage = library.lookupFunction<_SetNative, _SetDart>(
        'ptts_set_language',
      ),
      languages = library.lookupFunction<_NamesNative, _NamesNative>(
        'ptts_languages',
      ),
      voices = library.lookupFunction<_NamesNative, _NamesNative>(
        'ptts_voices',
      ),
      lastError = library.lookupFunction<_NamesNative, _NamesNative>(
        'ptts_last_error',
      ),
      free = library.lookupFunction<_FreeNative, _FreeDart>('ptts_free');

  final _NewDart create;
  final _SpeakDart speak;
  final _SetDart setVoice;
  final _SetDart setLanguage;
  final _NamesNative languages;
  final _NamesNative voices;
  final _NamesNative lastError;
  final _FreeDart free;
}

List<String> _nulNames(Pointer<Utf8> pointer) {
  if (pointer == nullptr) return const [];
  final bytes = pointer.cast<Uint8>();
  final names = <String>[];
  var start = 0;
  // The native contract ends with two NUL bytes; the cap protects against
  // malformed output from a mismatched library ABI.
  for (var index = 0; index < 4096; index++) {
    if (bytes[index] != 0) continue;
    if (index == start) return names;
    names.add((bytes + start).cast<Utf8>().toDartString());
    start = index + 1;
  }
  throw const FormatException('Ungültige Phonon-Namensliste.');
}

void _phononWorker(SendPort host) async {
  final inbox = ReceivePort();
  host.send(inbox.sendPort);
  _Bindings? bindings;
  Pointer<Void> handle = nullptr;
  try {
    await for (final message in inbox) {
      if (message is! Map) continue;
      final id = message['id'];
      if (id is! int) continue;
      try {
        switch (message['command']) {
          case 'open':
            final directory = message['directory'] as String;
            final language = message['language'] as String;
            if (!Directory(directory).existsSync()) {
              throw const FormatException('Phonon-Modellordner fehlt.');
            }
            if (!Platform.isMacOS) {
              final config = File('$directory/config.json');
              final tokenizer = File('$directory/tokenizer.json');
              final q8 = File('$directory/model.q8.gguf');
              final full = File('$directory/model.safetensors');
              if (!config.existsSync() ||
                  !tokenizer.existsSync() ||
                  !(q8.existsSync() || full.existsSync())) {
                throw const FormatException('Phonon-Modell ist unvollständig.');
              }
            }
            final libraryName = Platform.isAndroid
                ? 'libptts_ffi.so'
                : Platform.isWindows
                ? 'ptts_ffi.dll'
                : Platform.isMacOS
                ? 'libptts_ffi.dylib'
                : 'libptts_ffi.so';
            final libraryPath = Platform.isAndroid
                ? libraryName
                : '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$libraryName';
            late final _Bindings api;
            try {
              api = bindings = _Bindings(DynamicLibrary.open(libraryPath));
            } on ArgumentError {
              throw StateError(
                'Die Phonon-Sprachengine fehlt im Fundus-App-Paket.',
              );
            }
            final path = directory.toNativeUtf8();
            final lang = language.toNativeUtf8();
            try {
              handle = api.create(path, Platform.isMacOS ? 2 : 0, lang);
            } finally {
              calloc.free(path);
              calloc.free(lang);
            }
            if (handle == nullptr) {
              final message = api.lastError(nullptr);
              final detail = message == nullptr
                  ? null
                  : message.toDartString().trim();
              throw StateError(
                detail == null || detail.isEmpty
                    ? 'Phonon konnte das Modell nicht laden.'
                    : detail,
              );
            }
            host.send({
              'id': id,
              'languages': _nulNames(api.languages(handle)),
            });
          case 'catalogue_voices':
            final api = bindings;
            if (api == null || handle == nullptr) {
              throw StateError('Phonon-Modell ist nicht geladen.');
            }
            final language = (message['language'] as String).toNativeUtf8();
            try {
              if (api.setLanguage(handle, language) == 0) {
                throw StateError(
                  _nativeError(
                    api,
                    handle,
                    'Phonon konnte die Sprache nicht setzen.',
                  ),
                );
              }
            } finally {
              calloc.free(language);
            }
            host.send({'id': id, 'voices': _nulNames(api.voices(handle))});
          case 'synthesize':
            final api = bindings;
            if (api == null || handle == nullptr) {
              throw StateError('Phonon-Modell ist nicht geladen.');
            }
            final language = message['language'] as String;
            if (!_nulNames(api.languages(handle)).contains(language)) {
              throw StateError('Phonon-Modell unterstützt $language nicht.');
            }
            final lang = language.toNativeUtf8();
            try {
              if (api.setLanguage(handle, lang) == 0) {
                throw StateError(
                  _nativeError(
                    api,
                    handle,
                    'Phonon konnte die Sprache nicht setzen.',
                  ),
                );
              }
            } finally {
              calloc.free(lang);
            }
            final installedVoices = _nulNames(api.voices(handle));
            if (installedVoices.isEmpty) {
              throw StateError('Das Phonon-Modell hat keine Stimme.');
            }
            final requestedVoice = (message['voice'] as String?)?.trim();
            final voice = requestedVoice != null && requestedVoice.isNotEmpty
                ? requestedVoice
                : installedVoices.contains('default')
                ? 'default'
                : installedVoices.first;
            if (!installedVoices.contains(voice)) {
              throw StateError('Phonon-Stimme ist nicht installiert.');
            }
            final name = voice.toNativeUtf8();
            try {
              if (api.setVoice(handle, name) == 0) {
                throw StateError(
                  _nativeError(
                    api,
                    handle,
                    'Phonon konnte die Stimme nicht setzen.',
                  ),
                );
              }
            } finally {
              calloc.free(name);
            }
            final text = (message['text'] as String).toNativeUtf8();
            final result = calloc<_PttsResult>();
            final wave = PhononWaveBuilder();
            var truncated = false;
            final callback = NativeCallable<_FrameNative>.isolateLocal((
              Pointer<Float> pcm,
              int count,
              Pointer<Void> _,
            ) {
              if (count < 0 || count > PhononWaveBuilder.sampleRate * 120) {
                truncated = true;
                return 0;
              }
              if (!wave.append(pcm.asTypedList(count))) {
                truncated = true;
                return 0;
              }
              return 1;
            }, exceptionalReturn: 0);
            try {
              final ok = api.speak(
                handle,
                text,
                callback.nativeFunction,
                nullptr,
                result,
              );
              if (truncated) {
                throw const FormatException('Phonon-Audio ist zu lang.');
              }
              if (ok == 0 || result.ref.samples != wave.sampleCount) {
                throw StateError(
                  _nativeError(
                    api,
                    handle,
                    'Phonon konnte den Abschnitt nicht sprechen.',
                  ),
                );
              }
              host.send({
                'id': id,
                'wav': wave.finish(),
                'duration_us': wave.duration.inMicroseconds,
              });
            } finally {
              callback.close();
              calloc.free(result);
              calloc.free(text);
            }
          case 'close':
            if (bindings != null && handle != nullptr) bindings.free(handle);
            handle = nullptr;
            host.send({'id': id});
            inbox.close();
        }
      } on Object catch (error) {
        // Native errors can contain private model paths. The interface uses
        // bounded, non-path diagnostics and does not write book text to logs.
        final reason = error is FormatException
            ? error.message
            : error is StateError
            ? error.message
            : 'Phonon ist auf diesem Gerät nicht verfügbar.';
        host.send({'id': id, 'error': reason});
      }
    }
  } finally {
    if (bindings != null && handle != nullptr) bindings.free(handle);
    inbox.close();
  }
}

String _nativeError(_Bindings bindings, Pointer<Void> handle, String fallback) {
  final message = bindings.lastError(handle);
  if (message == nullptr) return fallback;
  final detail = message.toDartString().trim();
  return detail.isEmpty ? fallback : detail;
}
