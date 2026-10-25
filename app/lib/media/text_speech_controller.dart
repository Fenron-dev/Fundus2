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
import 'speech_audio_buffer.dart';
import 'phonon_wave.dart';
import 'speech_text_transform.dart';
import 'text_reader_controller.dart';

enum TextSpeechState { idle, preparing, synthesizing, playing, paused, failed }

typedef _SpeechPreparation = ({PhononAudio? audio, Object? error});

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
    player.stopSpeechForSleepTimer = stop;
    player.resumeSpeechFromMediaControl = resume;
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
  SpeechAudioBuffer? _buffer;
  ({
    String directory,
    String? workOverride,
    String? globalDefault,
    String? voice,
    double rate,
    Map<String, String> pronunciations,
    String? voicesDirectory,
    Set<String> textRules,
    int maxCharacters,
    int sentencePauseMs,
    int paragraphPauseMs,
    int chapterPauseMs,
  })?
  _lastOptions;

  int get bufferedSegments => _buffer?.bufferedSegments ?? 0;

  void updatePronunciations(Map<String, String> value) {
    final previous = _lastOptions;
    if (previous != null) {
      _lastOptions = (
        directory: previous.directory,
        workOverride: previous.workOverride,
        globalDefault: previous.globalDefault,
        voice: previous.voice,
        rate: previous.rate,
        pronunciations: value,
        voicesDirectory: previous.voicesDirectory,
        textRules: previous.textRules,
        maxCharacters: previous.maxCharacters,
        sentencePauseMs: previous.sentencePauseMs,
        paragraphPauseMs: previous.paragraphPauseMs,
        chapterPauseMs: previous.chapterPauseMs,
      );
    }
  }

  Future<void> setRate(double rate) async {
    final previous = _lastOptions;
    if (previous != null) {
      _lastOptions = (
        directory: previous.directory,
        workOverride: previous.workOverride,
        globalDefault: previous.globalDefault,
        voice: previous.voice,
        rate: rate,
        pronunciations: previous.pronunciations,
        voicesDirectory: previous.voicesDirectory,
        textRules: previous.textRules,
        maxCharacters: previous.maxCharacters,
        sentencePauseMs: previous.sentencePauseMs,
        paragraphPauseMs: previous.paragraphPauseMs,
        chapterPauseMs: previous.chapterPauseMs,
      );
    }
    if (isActive) await player.setSpeechRate(rate);
  }

  /// Re-anchor to an original sentence, including the previous paragraph.
  /// Stop invalidates queued audio before moving the shared reading position.
  Future<void> skipSentences(int count) async {
    final options = _lastOptions;
    final wasActive = isActive;
    final paused = _pauseRequested;
    if (wasActive) await stop();
    reader.skipSpeechSentences(count);
    if (wasActive && options != null) {
      unawaited(
        start(
          modelDirectory: options.directory,
          workOverride: options.workOverride,
          globalDefault: options.globalDefault,
          voice: options.voice,
          rate: options.rate,
          pronunciations: options.pronunciations,
          voicesDirectory: options.voicesDirectory,
          textRules: options.textRules,
          maxCharacters: options.maxCharacters,
          sentencePauseMs: options.sentencePauseMs,
          paragraphPauseMs: options.paragraphPauseMs,
          chapterPauseMs: options.chapterPauseMs,
        ),
      );
      if (paused) await pause();
    }
  }

  TextSpeechState get state => _state;
  String? get failure => _failure;
  bool get isActive =>
      _state != TextSpeechState.idle && _state != TextSpeechState.failed;
  bool get isSpeaking => _state == TextSpeechState.playing && player.isPlaying;

  Future<List<SpeechLanguage>> availableLanguages({
    required String modelDirectory,
    required SpeechLanguage language,
    String? voicesDirectory,
  }) async {
    await _ensureEngine(
      modelDirectory,
      language,
      voicesDirectory: voicesDirectory,
    );
    return _engine!.availableLanguages();
  }

  Future<List<String>> availableVoices({
    required String modelDirectory,
    required SpeechLanguage language,
    String? voicesDirectory,
  }) async {
    await _ensureEngine(
      modelDirectory,
      language,
      voicesDirectory: voicesDirectory,
    );
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
    var mediaPauseObserved = false;
    // Lock-screen controls call the shared player directly. Remember a pause
    // even if it happened during Phonon's synthesis gap (there is then no WAV
    // loaded); the next sentence must wait for an explicit resume.
    if (player.isSpeechSessionActive &&
        !player.isPlaybackRequested &&
        !_pauseRequested &&
        _state != TextSpeechState.idle &&
        _state != TextSpeechState.failed) {
      _pauseRequested = true;
      _state = TextSpeechState.paused;
      mediaPauseObserved = true;
      reader.checkpointSpeech();
    }
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
    } else if (mediaPauseObserved) {
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
    String? voicesDirectory,
    Set<String> textRules = const {},
    int maxCharacters = 400,
    int sentencePauseMs = 120,
    int paragraphPauseMs = 600,
    int chapterPauseMs = 1500,
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
    _lastOptions = (
      directory: modelDirectory,
      workOverride: workOverride,
      globalDefault: globalDefault,
      voice: voice,
      rate: rate,
      pronunciations: pronunciations,
      voicesDirectory: voicesDirectory,
      textRules: textRules,
      maxCharacters: maxCharacters,
      sentencePauseMs: sentencePauseMs,
      paragraphPauseMs: paragraphPauseMs,
      chapterPauseMs: chapterPauseMs,
    );
    _pauseRequested = false;
    _runningWorkId = work.id;
    _failure = null;
    _state = TextSpeechState.preparing;
    notifyListeners();
    int? speechSessionId;
    try {
      speechSessionId = await player.beginSpeechSession(work);
      await _ensureEngine(
        modelDirectory,
        selection.language,
        voicesDirectory: voicesDirectory,
      );
      if (token != _runId) return;
      await _read(
        token,
        speechSessionId,
        work,
        selection.language,
        voice,
        rate,
        pronunciations,
        textRules,
        maxCharacters,
        sentencePauseMs,
        paragraphPauseMs,
        chapterPauseMs,
      );
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
      if (speechSessionId case final sessionId?) {
        try {
          await player.endSpeechSession(sessionId);
        } on Object {
          // Preserve the original synthesis/player result.
        }
      }
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
    String? voicesDirectory,
    Set<String> rules = const {},
  }) async {
    final work =
        reader.work ??
        WorkView.fromSummary(
          LibraryWorkSummary(
            id: 'speech-preview',
            kind: 'book',
            title: 'Phonon-Hörprobe',
            author: '',
            fileCount: 0,
            addedAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
    if (isActive) await stop();
    final token = ++_runId;
    _runningWorkId = work.id;
    _failure = null;
    _state = TextSpeechState.preparing;
    notifyListeners();
    File? file;
    try {
      await _ensureEngine(
        modelDirectory,
        language,
        voicesDirectory: voicesDirectory,
      );
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
        SpeechTextTransform.apply(
          segment,
          const {},
          rules: rules,
          language: SpeechLanguageResolver.code(language),
        ),
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
      if (token == _runId && player.isSpeechFileLoaded) {
        // A settings preview must not leave a mini-player pointing at a WAV
        // that is about to be deleted, or close another playback started later.
        await player.close();
      }
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

  Future<void> _ensureEngine(
    String directory,
    SpeechLanguage language, {
    String? voicesDirectory,
  }) async {
    final key =
        '$directory|${SpeechLanguageResolver.code(language)}|$voicesDirectory';
    if (_engine != null && _engineKey == key) return;
    if (isActive &&
        _engineKey != null &&
        _engineKey != key &&
        _state != TextSpeechState.preparing) {
      throw StateError(
        'Bitte das Vorlesen vor dem Laden eines anderen Profils beenden.',
      );
    }
    if (PhononModelStore.isFundusImportedModel(directory) &&
        !_verifiedModelDirectories.contains(directory)) {
      await PhononModelStore.verifyIntegrity(directory);
      _verifiedModelDirectories.add(directory);
    }
    await _engine?.dispose();
    _engine = voicesDirectory == null
        ? await _engineFactory(directory, language)
        : await PhononNativeEngine.open(
            modelDirectory: directory,
            language: language,
            voicesDirectory: voicesDirectory,
          );
    _engineKey = key;
  }

  Future<void> _read(
    int token,
    int speechSessionId,
    WorkView work,
    SpeechLanguage language,
    String? voice,
    double rate,
    Map<String, String> pronunciations,
    Set<String> textRules,
    int maxCharacters,
    int sentencePauseMs,
    int paragraphPauseMs,
    int chapterPauseMs,
  ) async {
    while (token == _runId && reader.isOpen) {
      await _waitUntilResumed(token);
      if (token != _runId || !reader.isOpen) return;
      final plan = reader.speechPlan(maxCharacters: maxCharacters);
      if (plan == null) return;
      final segments = plan.segments;
      final segment = segments.isEmpty ? null : segments.first;
      if (segment == null) {
        if (await player.completeSpeechChapter()) {
          reader.checkpointSpeech();
          return;
        }
        final volume = reader.volumeIndex;
        final chapter = reader.chapterIndex;
        await reader.nextChapter();
        if (volume == reader.volumeIndex && chapter == reader.chapterIndex) {
          reader.checkpointSpeech();
          return;
        }
        continue;
      }

      final buffer = await SpeechAudioBuffer.open();
      _buffer = buffer;
      _state = TextSpeechState.synthesizing;
      notifyListeners();
      // Synthesis runs ahead on the serial native worker, but never more than
      // four unplayed speech segments. One audio sink remains open per chapter.
      Future<void> produce() async {
        try {
          final iterator = segments.iterator;
          if (!iterator.moveNext()) {
            buffer.finish();
            return;
          }
          var current = iterator.current;
          while (token == _runId && reader.isOpen) {
            await _waitUntilResumed(token);
            if (token != _runId) break;
            final hasNext = iterator.moveNext();
            final next = hasNext ? iterator.current : null;
            final prepared = await _synthesizeWithPauses(
              SpeechTextTransform.apply(
                current,
                _lastOptions?.pronunciations ?? pronunciations,
                rules: textRules,
                language: SpeechLanguageResolver.code(language),
              ),
              language: language,
              voice: voice,
            );
            if (prepared.error case final error?) throw error;
            if (token != _runId) break;
            await buffer.add(
              prepared.audio!,
              current,
              paragraphEnd:
                  next == null || next.paragraphIndex != current.paragraphIndex,
              chapterEnd: next == null,
              sentencePause: Duration(milliseconds: sentencePauseMs),
              paragraphPause: Duration(milliseconds: paragraphPauseMs),
              chapterPause: Duration(milliseconds: chapterPauseMs),
            );
            notifyListeners();
            if (next == null) break;
            current = next;
          }
          buffer.finish();
        } on Object catch (error) {
          buffer.finish(error);
        }
      }

      final producer = produce();
      void commit(List<SpeechTextSegment> heard) {
        for (final sentence in heard) {
          if (token != _runId) return;
          if (!reader.completeSpokenSegment(sentence)) {
            unawaited(stop());
            return;
          }
        }
      }

      void progress() {
        if (token == _runId && player.isPlayingSpeech) {
          commit(buffer.heardUntil(player.position));
        }
      }

      try {
        await buffer.ready.future;
        if (token != _runId || !reader.isOpen) return;
        if (buffer.failure case final error?) throw error;
        await _waitUntilResumed(token);
        if (token != _runId) return;
        _state = TextSpeechState.playing;
        notifyListeners();
        final currentChapter = reader.currentChapter;
        player.positionListenable.addListener(progress);
        await player.playSpeechFile(
          speechSessionId: speechSessionId,
          work: work,
          fileId: '${reader.currentVolume?.fileId ?? work.id}:${segment.start}',
          title: currentChapter == null
              ? work.title
              : '${work.title} · ${currentChapter.title}',
          path: '',
          streamUri: buffer.uri,
          rate: _lastOptions?.rate ?? rate,
        );
        if (token != _runId) return;
        await producer;
        if (buffer.failure case final error?) throw error;
        commit(buffer.complete());
      } finally {
        player.positionListenable.removeListener(progress);
        await buffer.dispose();
        if (identical(_buffer, buffer)) _buffer = null;
      }
      if (token != _runId || !reader.isOpen) return;
    }
  }

  Future<_SpeechPreparation> _synthesize(
    SpeechTextSegment segment, {
    required SpeechLanguage language,
    required String? voice,
  }) async {
    try {
      return (
        audio: await _engine!.synthesize(
          segment,
          language: language,
          voice: voice,
        ),
        error: null,
      );
    } on Object catch (error) {
      // Prefetch may be discarded if the reader moves or playback is stopped.
      // Resolve its failure as data so it cannot become an unhandled future.
      return (audio: null, error: error);
    }
  }

  Future<_SpeechPreparation> _synthesizeWithPauses(
    SpeechTextSegment segment, {
    required SpeechLanguage language,
    required String? voice,
  }) async {
    final pieces = SpeechTextTransform.splitPauses(segment.text);
    if (pieces.length == 1) {
      return _synthesize(
        _withText(segment, pieces.single.text),
        language: language,
        voice: voice,
      );
    }
    try {
      final wave = PhononWaveBuilder(maxSeconds: 300);
      for (var index = 0; index < pieces.length; index++) {
        final piece = pieces[index];
        final generated = await _synthesize(
          _withText(segment, piece.text),
          language: language,
          voice: voice,
        );
        if (generated.error != null) return generated;
        final wav = generated.audio!.wav;
        final source = ByteData.sublistView(wav, 44);
        final samples = Float32List(source.lengthInBytes ~/ 2);
        for (var sample = 0; sample < samples.length; sample++) {
          samples[sample] = source.getInt16(sample * 2, Endian.little) / 32768;
        }
        if (!wave.append(samples)) {
          throw const FormatException('Phonon-Abschnitt ist zu lang.');
        }
        if (index < pieces.length - 1 && piece.pauseAfter > Duration.zero) {
          final silence = Float32List(
            piece.pauseAfter.inMicroseconds *
                PhononWaveBuilder.sampleRate ~/
                Duration.microsecondsPerSecond,
          );
          if (!wave.append(silence)) {
            throw const FormatException('Phonon-Abschnitt ist zu lang.');
          }
        }
      }
      return (
        audio: PhononAudio(wav: wave.finish(), duration: wave.duration),
        error: null,
      );
    } on Object catch (error) {
      return (audio: null, error: error);
    }
  }

  static SpeechTextSegment _withText(SpeechTextSegment segment, String text) =>
      SpeechTextSegment(
        text: text,
        start: segment.start,
        end: segment.end,
        paragraphIndex: segment.paragraphIndex,
        startPosition: segment.startPosition,
        endPosition: segment.endPosition,
      );

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
    String? voicesDirectory,
    Set<String> textRules = const {},
    int maxCharacters = 400,
    int sentencePauseMs = 120,
    int paragraphPauseMs = 600,
    int chapterPauseMs = 1500,
  }) async {
    if (!isActive) {
      return start(
        modelDirectory: modelDirectory,
        workOverride: workOverride,
        globalDefault: globalDefault,
        voice: voice,
        rate: rate,
        pronunciations: pronunciations,
        voicesDirectory: voicesDirectory,
        textRules: textRules,
        maxCharacters: maxCharacters,
        sentencePauseMs: sentencePauseMs,
        paragraphPauseMs: paragraphPauseMs,
        chapterPauseMs: chapterPauseMs,
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
    await _buffer?.dispose();
    _buffer = null;
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
    player.stopSpeechForSleepTimer = null;
    player.resumeSpeechFromMediaControl = null;
    _runId++;
    unawaited(_buffer?.dispose());
    _pauseRequested = false;
    _resumeGate?.complete();
    _resumeGate = null;
    reader.checkpointSpeech();
    unawaited(player.close());
    unawaited(_engine?.dispose());
    super.dispose();
  }
}
