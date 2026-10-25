import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path_provider/path_provider.dart';

import '../data/work_view.dart';
import 'phonon_native.dart';
import 'phonon_model_store.dart';
import 'playback_controller.dart';
import 'speech_engine.dart';
import 'speech_text_transform.dart';
import 'text_reader_controller.dart';

enum TextSpeechState { idle, preparing, synthesizing, playing, paused, failed }

typedef TextSpeechEngineFactory =
    Future<TextSpeechEngine> Function(
      String modelDirectory,
      SpeechLanguage language,
    );

/// Reads the current book through the same audio player used by music and
/// audiobooks. Reader progress advances only after a segment reaches EOF.
final class TextSpeechController extends ChangeNotifier {
  TextSpeechController({
    required this.reader,
    required this.player,
    TextSpeechEngineFactory? engineFactory,
    Future<Directory> Function()? tempDirectory,
  }) : _engineFactory = engineFactory ?? _openPhonon,
       _tempDirectory = tempDirectory ?? getTemporaryDirectory {
    reader.addListener(_readerChanged);
    player.addListener(_playerChanged);
  }

  final TextReaderController reader;
  final PlaybackController player;
  final TextSpeechEngineFactory _engineFactory;
  final Future<Directory> Function() _tempDirectory;

  static Future<TextSpeechEngine> _openPhonon(
    String directory,
    SpeechLanguage language,
  ) => PhononNativeEngine.open(modelDirectory: directory, language: language);

  TextSpeechEngine? _engine;
  String? _engineKey;
  final Set<String> _verifiedModelDirectories = {};
  TextSpeechState _state = TextSpeechState.idle;
  String? _failure;
  int _runId = 0;
  String? _runningWorkId;
  bool _pauseRequested = false;
  Completer<void>? _resumeGate;

  TextSpeechState get state => _state;
  String? get failure => _failure;
  bool get isActive =>
      _state != TextSpeechState.idle && _state != TextSpeechState.failed;
  bool get isSpeaking => _state == TextSpeechState.playing && player.isPlaying;

  Future<List<SpeechLanguage>> availableLanguages({
    required String modelDirectory,
    required SpeechLanguage language,
  }) async {
    await _ensureEngine(modelDirectory, language);
    return _engine!.availableLanguages();
  }

  Future<List<String>> availableVoices({
    required String modelDirectory,
    required SpeechLanguage language,
  }) async {
    await _ensureEngine(modelDirectory, language);
    return _engine!.availableVoices(language);
  }

  void _readerChanged() {
    if (isActive && (!reader.isOpen || reader.work?.id != _runningWorkId)) {
      unawaited(stop());
    } else if (reader.isOpen && _state == TextSpeechState.failed) {
      _state = TextSpeechState.idle;
      _failure = null;
      notifyListeners();
    }
  }

  void _playerChanged() {
    if ((_state == TextSpeechState.playing ||
            _state == TextSpeechState.preparing ||
            _state == TextSpeechState.paused) &&
        player.isPlayingSpeech) {
      _state = switch ((player.isPlaybackRequested, player.isPlaying)) {
        (true, true) => TextSpeechState.playing,
        (true, false) => TextSpeechState.preparing,
        (false, _) when player.isLoadingTrack => TextSpeechState.preparing,
        _ => TextSpeechState.paused,
      };
      notifyListeners();
    }
  }

  Future<void> start({
    required String modelDirectory,
    String? workOverride,
    String? globalDefault,
    String? voice,
    double rate = 1,
    Map<String, String> pronunciations = const {},
  }) async {
    if (isActive) return;
    final work = reader.work;
    final selection = reader.resolveSpeechLanguage(
      workOverride: workOverride,
      globalDefault: globalDefault,
    );
    if (work == null || !reader.isOpen || selection == null) {
      _setFailure('Für dieses Werk ist keine Vorlesesprache festgelegt.');
      return;
    }
    final token = ++_runId;
    _runningWorkId = work.id;
    _failure = null;
    _state = TextSpeechState.preparing;
    notifyListeners();
    try {
      await _ensureEngine(modelDirectory, selection.language);
      await _read(token, work, selection.language, voice, rate, pronunciations);
      if (token == _runId) {
        _state = TextSpeechState.idle;
        _runningWorkId = null;
      }
    } on Object catch (error) {
      if (token == _runId) {
        final intentionallyStopped = error is SpeechPlaybackInterrupted;
        _failure = intentionallyStopped ? null : _diagnostic(error);
        _state = intentionallyStopped
            ? TextSpeechState.idle
            : TextSpeechState.failed;
        _runningWorkId = null;
        reader.checkpointSpeech();
        if (!intentionallyStopped && player.isSpeechFileLoaded) {
          try {
            await player.close();
          } on Object {
            // Preserve the original synthesis/player diagnostic.
          }
        }
      }
    } finally {
      if (token == _runId) notifyListeners();
    }
  }

  /// Plays a short, fixed phrase through the same local voice and player as
  /// reading. It deliberately does not move the book position or write a
  /// reading checkpoint.
  Future<void> preview({
    required String modelDirectory,
    required SpeechLanguage language,
    String? voice,
    double rate = 1,
  }) async {
    final work = reader.work;
    if (!reader.isOpen || work == null) return;
    if (isActive) await stop();
    final token = ++_runId;
    _runningWorkId = work.id;
    _failure = null;
    _state = TextSpeechState.preparing;
    notifyListeners();
    File? file;
    try {
      await _ensureEngine(modelDirectory, language);
      if (token != _runId) return;
      _state = TextSpeechState.synthesizing;
      notifyListeners();
      final text = switch (language) {
        SpeechLanguage.english =>
          'This is a short voice sample. Your English novel will be read aloud from your current position.',
        SpeechLanguage.german =>
          'Dies ist eine kurze Hörprobe. Dein Buch wird an deiner aktuellen Lesestelle vorgelesen.',
        SpeechLanguage.french =>
          'Ceci est un court échantillon vocal. Votre livre sera lu à partir de votre position actuelle.',
        SpeechLanguage.spanish =>
          'Esta es una breve muestra de voz. Tu libro se leerá desde tu posición actual.',
        SpeechLanguage.portuguese =>
          'Esta é uma pequena amostra de voz. O livro será lido a partir da sua posição atual.',
      };
      final position = MediaPosition(
        kind: MediaPositionKind.epubCfi,
        numericValue: 0,
        label: 'Hörprobe',
      );
      final segment = SpeechTextSegment(
        text: text,
        start: 0,
        end: text.length,
        paragraphIndex: 0,
        startPosition: position,
        endPosition: position,
      );
      final audio = await _engine!.synthesize(
        segment,
        language: language,
        voice: voice,
      );
      if (token != _runId) return;
      final temp = await _tempDirectory();
      file = File('${temp.path}/fundus-speech-preview-${++_runIdCounter}.wav');
      await file.writeAsBytes(audio.wav, flush: true);
      _state = TextSpeechState.playing;
      notifyListeners();
      await player.playSpeechFile(
        work: work,
        fileId: 'preview:${SpeechLanguageResolver.code(language)}',
        title: 'Phonon-Hörprobe · ${_languageName(language)}',
        path: file.path,
        rate: rate,
      );
    } on Object catch (error) {
      if (token == _runId && error is! SpeechPlaybackInterrupted) {
        _failure = _diagnostic(error);
        if (player.isSpeechFileLoaded) {
          try {
            await player.close();
          } on Object {
            // Preserve the original preview diagnostic.
          }
        }
      }
    } finally {
      try {
        if (file != null && await file.exists()) await file.delete();
      } on FileSystemException {
        // A stale temporary WAV can be removed by the next app cleanup.
      }
      if (token == _runId) {
        _state = _failure == null
            ? TextSpeechState.idle
            : TextSpeechState.failed;
        _runningWorkId = null;
        notifyListeners();
      }
    }
  }

  static String _languageName(SpeechLanguage language) => switch (language) {
    SpeechLanguage.english => 'English',
    SpeechLanguage.german => 'Deutsch',
    SpeechLanguage.french => 'Französisch',
    SpeechLanguage.spanish => 'Spanisch',
    SpeechLanguage.portuguese => 'Portugiesisch',
  };

  Future<void> _ensureEngine(String directory, SpeechLanguage language) async {
    final key = '$directory|${SpeechLanguageResolver.code(language)}';
    if (_engine != null && _engineKey == key) return;
    if (PhononModelStore.isFundusImportedModel(directory) &&
        !_verifiedModelDirectories.contains(directory)) {
      await PhononModelStore.verifyIntegrity(directory);
      _verifiedModelDirectories.add(directory);
    }
    await _engine?.dispose();
    _engine = await _engineFactory(directory, language);
    _engineKey = key;
  }

  Future<void> _read(
    int token,
    WorkView work,
    SpeechLanguage language,
    String? voice,
    double rate,
    Map<String, String> pronunciations,
  ) async {
    while (token == _runId && reader.isOpen) {
      await _waitUntilResumed(token);
      if (token != _runId || !reader.isOpen) return;
      final plan = reader.speechPlan();
      if (plan == null) return;
      final segments = plan.segments;
      final segment = segments.isEmpty ? null : segments.first;
      if (segment == null) {
        final volume = reader.volumeIndex;
        final chapter = reader.chapterIndex;
        await reader.nextChapter();
        if (volume == reader.volumeIndex && chapter == reader.chapterIndex) {
          reader.checkpointSpeech();
          return;
        }
        continue;
      }

      _state = TextSpeechState.synthesizing;
      notifyListeners();
      final speechSegment = SpeechTextTransform.apply(segment, pronunciations);
      final audio = await _engine!.synthesize(
        speechSegment,
        language: language,
        voice: voice,
      );
      if (token != _runId || !reader.isOpen) return;
      await _waitUntilResumed(token);
      if (token != _runId || !reader.isOpen) return;

      final temp = await _tempDirectory();
      final path = '${temp.path}/fundus-speech-${++_runIdCounter}.wav';
      final file = File(path);
      try {
        await file.writeAsBytes(audio.wav, flush: true);
        _state = TextSpeechState.playing;
        notifyListeners();
        final currentChapter = reader.currentChapter;
        await player.playSpeechFile(
          work: work,
          fileId: '${reader.currentVolume?.fileId ?? work.id}:${segment.start}',
          title: currentChapter == null
              ? work.title
              : '${work.title} · ${currentChapter.title}',
          path: path,
          rate: rate,
        );
      } finally {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // A stale temporary WAV can be removed by the next app cleanup.
        }
      }
      if (token != _runId || !reader.isOpen) return;
      if (!reader.completeSpokenSegment(segment)) {
        // Someone moved the reading position while this sentence was playing.
        // Stop rather than speaking stale text or moving the position back.
        return;
      }
    }
  }

  static int _runIdCounter = 0;

  Future<void> _waitUntilResumed(int token) async {
    if (!_pauseRequested) return;
    _state = TextSpeechState.paused;
    notifyListeners();
    final gate = _resumeGate ??= Completer<void>();
    await gate.future;
    if (token == _runId) _state = TextSpeechState.preparing;
  }

  Future<void> pause() async {
    if (!isActive || _pauseRequested) return;
    _pauseRequested = true;
    if (player.isPlaying || player.isPlaybackRequested) await player.pause();
    reader.checkpointSpeech();
    _state = TextSpeechState.paused;
    notifyListeners();
  }

  Future<void> resume() async {
    if (!_pauseRequested &&
        !(_state == TextSpeechState.paused && player.isPlayingSpeech)) {
      return;
    }
    _pauseRequested = false;
    final gate = _resumeGate;
    _resumeGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
    if (player.isPlayingSpeech && !player.isPlaybackRequested) {
      await player.playOrPause();
    }
    if (_state == TextSpeechState.paused) {
      _state = player.isPlaying
          ? TextSpeechState.playing
          : TextSpeechState.preparing;
    }
    notifyListeners();
  }

  Future<void> toggle({
    required String modelDirectory,
    String? workOverride,
    String? globalDefault,
    String? voice,
    double rate = 1,
    Map<String, String> pronunciations = const {},
  }) async {
    if (!isActive) {
      return start(
        modelDirectory: modelDirectory,
        workOverride: workOverride,
        globalDefault: globalDefault,
        voice: voice,
        rate: rate,
        pronunciations: pronunciations,
      );
    }
    if (_pauseRequested ||
        _state == TextSpeechState.paused && player.isPlayingSpeech) {
      return resume();
    }
    return pause();
  }

  Future<void> stop() async {
    if (!isActive && _engine == null) return;
    _runId++;
    _runningWorkId = null;
    _pauseRequested = false;
    final gate = _resumeGate;
    _resumeGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
    reader.checkpointSpeech();
    await player.close();
    _state = TextSpeechState.idle;
    _runningWorkId = null;
    notifyListeners();
  }

  void _setFailure(String message) {
    _failure = message;
    _state = TextSpeechState.failed;
    notifyListeners();
  }

  String _diagnostic(Object error) {
    if (error is StateError || error is FormatException) {
      return error.toString().replaceFirst(
        RegExp(r'^(Bad state: |FormatException: )'),
        '',
      );
    }
    return 'Vorlesen ist auf diesem Gerät nicht verfügbar.';
  }

  @override
  void dispose() {
    reader.removeListener(_readerChanged);
    player.removeListener(_playerChanged);
    _runId++;
    _pauseRequested = false;
    _resumeGate?.complete();
    _resumeGate = null;
    reader.checkpointSpeech();
    unawaited(player.close());
    unawaited(_engine?.dispose());
    super.dispose();
  }
}
