import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../media/playback_preference.dart';
import '../../media/playback_controller.dart';
import '../../media/playback_engine.dart';
import '../../data/work_view.dart';
import '../library/work_poster.dart';

/// The full player, laid over the shell.
///
/// Secondary material — tracks and chapters — sits beside the transport rather
/// than under it, so nothing has to slide up from the bottom edge where the
/// system gestures live.
class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final player = scope.player;
    final work = player.work;
    if (work == null) return const SizedBox.shrink();

    final tokens = context.fundus;
    final isCompact =
        MediaQuery.sizeOf(context).width < FundusShellMetrics.compactBreakpoint;

    // Bei einem Film gehört der Bildschirm dem Bild: die Leiste blendet sich
    // auf Klick weg und mit dem nächsten wieder ein — wie im Leser. Bei einem
    // Hörbuch bleibt sie, dort gibt es nichts zu verdecken.
    final hidesChrome = player.showsVideo && !player.showsChrome;

    return _PlayerKeys(
      child: ColoredBox(
        color: tokens.background,
        child: SafeArea(
          top: !hidesChrome,
          child: Column(
            children: [
              if (!hidesChrome)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FundusSpace.x4,
                    vertical: FundusSpace.x2,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () {
                          scope.leaveFullscreen();
                          player.collapse();
                        },
                        icon: Icon(
                          FundusIcons.collapse,
                          size: FundusIcons.sizeLg,
                        ),
                        tooltip: 'Minimieren',
                      ),
                      const Spacer(),
                      // Zweisprachige Anime sind der Normalfall, nicht die
                      // Ausnahme: ohne diese beiden Menüs sind die deutsche
                      // Tonspur und die Untertitel schlicht unerreichbar.
                      if (player.tracks.audio.length > 1)
                        _TrackMenu(
                          icon: FundusIcons.audioTrack,
                          tooltip: 'Tonspur',
                          options: player.tracks.audio,
                          selectedId: player.tracks.selectedAudioId,
                          onSelected: player.selectAudioTrack,
                        ),
                      if (player.tracks.subtitles.length > 1)
                        _TrackMenu(
                          icon: FundusIcons.subtitles,
                          tooltip: 'Untertitel',
                          options: player.tracks.subtitles,
                          selectedId: player.tracks.selectedSubtitleId,
                          onSelected: player.selectSubtitleTrack,
                        ),
                      // Die Liste daneben ist ein Gast, kein Möbelstück: sie
                      // kommt auf Wunsch und bleibt sonst weg.
                      if (!isCompact)
                        IconButton(
                          onPressed: () => scope.setPlayerPanelVisible(
                            !scope.settings.playerPanelVisible,
                          ),
                          icon: Icon(
                            FundusIcons.lists,
                            size: FundusIcons.sizeLg,
                          ),
                          isSelected: scope.settings.playerPanelVisible,
                          tooltip: scope.settings.playerPanelVisible
                              ? 'Liste ausblenden'
                              : 'Liste einblenden',
                        ),
                      // Nur wo es ein Bild gibt: ein Hörbuch hat keins, und das
                      // Cover ist nicht gemeint.
                      if (player.showsVideo)
                        IconButton(
                          onPressed: () => _saveFrame(context),
                          icon: Icon(
                            FundusIcons.camera,
                            size: FundusIcons.sizeLg,
                          ),
                          tooltip: 'Bild speichern',
                        ),
                      IconButton(
                        onPressed: scope.toggleFullscreen,
                        icon: Icon(
                          FundusIcons.fullscreen,
                          size: FundusIcons.sizeLg,
                        ),
                        tooltip: scope.fullscreen.isActive
                            ? 'Vollbild beenden'
                            : 'Vollbild',
                      ),
                      FundusOriginMark(work.origin, showLabel: true),
                    ],
                  ),
                ),
              Expanded(
                child: isCompact
                    ? _Transport(compact: true, bare: hidesChrome)
                    : Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: _Transport(bare: hidesChrome),
                          ),
                          if (scope.settings.playerPanelVisible && !hidesChrome)
                            SizedBox(
                              width: 320,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border(
                                    left: BorderSide(color: tokens.divider),
                                  ),
                                ),
                                child: const _ContextPanel(),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The keys that belong to a running player, wherever the focus sits inside
/// it: space pauses, F is fullscreen, Escape steps back out.
class _PlayerKeys extends StatelessWidget {
  const _PlayerKeys({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final player = scope.player;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        switch (event.logicalKey) {
          case LogicalKeyboardKey.space:
            player.playOrPause();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowLeft:
            player.skipBackward();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowRight:
            player.skipForward();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.keyF:
            scope.toggleFullscreen();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.escape:
            if (scope.fullscreen.isActive) {
              scope.leaveFullscreen();
            } else if (!player.showsChrome) {
              player.showChrome();
            } else {
              player.collapse();
            }
            return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

/// Saves the frame on screen where the user wants it.
Future<void> _saveFrame(BuildContext context) async {
  final scope = FundusScope.of(context);
  final player = scope.player;
  final messenger = ScaffoldMessenger.of(context);
  final bytes = await player.captureFrame();
  if (bytes == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Von dieser Wiedergabe gibt es kein Bild.')),
    );
    return;
  }
  try {
    final path = await scope.captureSink.save(
      bytes,
      suggestedName: player.captureName(),
    );
    if (path == null) return;
    messenger.showSnackBar(SnackBar(content: Text('Bild gespeichert: $path')));
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('Speichern fehlgeschlagen: $error')),
    );
  }
}

class _TrackMenu extends StatelessWidget {
  const _TrackMenu({
    required this.icon,
    required this.tooltip,
    required this.options,
    required this.selectedId,
    required this.onSelected,
  });

  final IconData icon;
  final String tooltip;
  final List<MediaTrackOption> options;
  final String? selectedId;
  final void Function(String id) onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return PopupMenuButton<String>(
      tooltip: tooltip,
      icon: Icon(icon, size: FundusIcons.sizeLg),
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem(
            value: option.id,
            child: Text(
              option.label,
              style: option.id == selectedId
                  ? TextStyle(color: tokens.accentRamp.s200)
                  : null,
            ),
          ),
      ],
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({this.compact = false, this.bare = false});

  final bool compact;

  /// Nothing but the picture: the controls have been tapped away.
  final bool bare;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final player = scope.player;
    final work = player.work!;

    // A film shows its picture where an audiobook shows its cover — and it
    // gets the room: a picture squeezed into a padded box on a large window
    // is the one thing a video player must not do.
    final video = player.videoSurface();
    if (video != null) {
      // Ein Klick aufs Bild nimmt die Bedienung weg und der nächste bringt
      // sie zurück — dieselbe Geste wie im Leser.
      final picture = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: player.toggleChrome,
        onDoubleTap: FundusScope.of(context).toggleFullscreen,
        child: ColoredBox(
          color: const Color(0xFF000000),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(child: video),
              if (player.isBetweenEpisodes)
                const Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: EdgeInsets.all(FundusSpace.x8),
                    child: _NextEpisode(),
                  ),
                ),
            ],
          ),
        ),
      );
      if (bare) return picture;
      final landscapeVideo =
          compact && MediaQuery.orientationOf(context) == Orientation.landscape;
      final caption = Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FundusSpace.x6,
          vertical: FundusSpace.x4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              player.currentSource?.title ?? work.title,
              maxLines: 1,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: FundusSpace.x3),
            // Sideways over a running film the bar carries what a film needs
            // and nothing else. Speed, sleep timer and shuffle belong to a
            // long listen, not to the two taps somebody makes with a thumb
            // over the picture.
            _Controls(minimal: landscapeVideo),
            // Auf dem Telefon gibt es keine zweite Spalte, in der die Folgen
            // stehen könnten — sie gehören dann unter die Bedienung. Über dem
            // Bild aber nicht: dort verdeckt eine Liste genau das, weswegen
            // man hinsieht.
            if (compact && !landscapeVideo) ...[
              const SizedBox(height: FundusSpace.x6),
              const _ContextPanel(shrinkWrap: true),
            ],
          ],
        ),
      );

      if (compact) {
        // Turned sideways, the picture is what the phone is for: it takes the
        // screen and the controls lie over it, the way every video player on
        // a phone behaves. Upright it keeps a box of its own shape — the
        // file's, not a guessed 16:9 — with the controls below it.
        if (landscapeVideo) {
          return Stack(
            fit: StackFit.expand,
            children: [
              picture,
              if (player.showsChrome)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0xCC000000)],
                      ),
                    ),
                    child: SafeArea(top: false, child: caption),
                  ),
                ),
            ],
          );
        }
        return Column(
          children: [
            ValueListenableBuilder<double?>(
              valueListenable: player.videoAspectRatio,
              builder: (context, ratio, child) =>
                  AspectRatio(aspectRatio: ratio ?? 16 / 9, child: child),
              child: picture,
            ),
            Expanded(child: SingleChildScrollView(child: caption)),
          ],
        );
      }
      return Column(
        children: [
          Expanded(child: picture),
          caption,
        ],
      );
    }

    final theme = Theme.of(context);
    final tokens = context.fundus;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(FundusSpace.x10),
      child: Column(
        children: [
          SizedBox(
            width: compact ? 220 : 260,
            child: _NowShowing(work: work, imagePath: player.chapterImagePath),
          ),
          const SizedBox(height: FundusSpace.x8),
          Text(
            work.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.displayMedium,
          ),
          const SizedBox(height: FundusSpace.x2),
          Text(
            player.currentSource?.title ?? work.subtitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          if (player.chapterTitle case final chapter?) ...[
            const SizedBox(height: FundusSpace.x2),
            Text(
              chapter,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.accent,
              ),
            ),
          ],
          const SizedBox(height: FundusSpace.x8),
          const _Controls(),
          if (compact) ...[
            const SizedBox(height: FundusSpace.x8),
            const _ContextPanel(shrinkWrap: true),
          ],
        ],
      ),
    );
  }
}

/// The seek bar and the buttons — the same set whether a cover or a picture
/// sits above them.
class _Controls extends StatelessWidget {
  const _Controls({this.minimal = false});

  /// Only what a film needs: back, play, forward. Everything else is for a
  /// long listen and gets in the way over a picture.
  final bool minimal;

  @override
  Widget build(BuildContext context) {
    final player = FundusScope.of(context).player;
    final tokens = context.fundus;
    final theme = Theme.of(context);

    return Column(
      children: [
        Row(
          children: [
            Text(
              formatPlaybackTime(player.position),
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textFaint,
              ),
            ),
            Expanded(
              child: Slider(
                value: player.progressFraction,
                onChanged: (value) {
                  final total = player.duration;
                  if (total == null) return;
                  player.seek(total * value);
                },
              ),
            ),
            Text(
              player.duration == null
                  ? '--:--'
                  : formatPlaybackTime(player.duration!),
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textFaint,
              ),
            ),
          ],
        ),
        const SizedBox(height: FundusSpace.x4),
        Wrap(
          spacing: FundusSpace.x3,
          runSpacing: FundusSpace.x3,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.center,
          children: [
            TextButton(
              onPressed: player.skipBackward,
              child: Text('−${player.habits.skipBack.inSeconds} s'),
            ),
            IconButton(
              onPressed: player.previous,
              icon: Icon(FundusIcons.skipBack, size: FundusIcons.sizeLg),
              tooltip: 'Vorheriger Titel',
            ),
            IconButton.filled(
              onPressed: player.playOrPause,
              iconSize: FundusIcons.sizeLg,
              icon: Icon(
                player.isPlaying ? FundusIcons.pause : FundusIcons.play,
              ),
              tooltip: player.isPlaying ? 'Pause' : 'Wiedergabe',
            ),
            IconButton(
              onPressed: player.next,
              icon: Icon(FundusIcons.skipForward, size: FundusIcons.sizeLg),
              tooltip: 'Nächster Titel',
            ),
            TextButton(
              onPressed: player.skipForward,
              child: Text('+${player.habits.skipForward.inSeconds} s'),
            ),
            if (!minimal) const PlaybackRateButton(),
            if (!minimal && player.hasQueueControls) ...[
              IconButton(
                onPressed: () => player.setShuffle(!player.isShuffling),
                isSelected: player.isShuffling,
                icon: Icon(FundusIcons.shuffle, size: FundusIcons.sizeLg),
                tooltip: player.isShuffling
                    ? 'Zufällige Reihenfolge — aus'
                    : 'Zufällige Reihenfolge',
              ),
              IconButton(
                onPressed: player.cycleRepeat,
                isSelected: player.repeatMode != RepeatMode.none,
                icon: Icon(
                  player.repeatMode == RepeatMode.one
                      ? FundusIcons.repeatOne
                      : FundusIcons.repeat,
                  size: FundusIcons.sizeLg,
                ),
                tooltip: player.repeatMode.label,
              ),
            ],
            if (!minimal) const _SleepButton(),
          ],
        ),
      ],
    );
  }
}

/// What else is in this work: chapters, episodes, files.
///
/// Where it sits under the controls rather than in a column of its own, it
/// starts folded away. A list of episodes across the bottom of the phone is
/// in the way of the thing somebody opened — it is offered by name, and
/// unfolds when it is wanted, the way chapters do in the reader.
/// Die Abspielgeschwindigkeit, zum Auswählen.
///
/// Vorher klickte ein Knopf sich durch neun Stufen und fing dann wieder von
/// vorn an — wer von 1× auf 1,5× wollte, tippte viermal und lief einmal
/// durch das ganze Feld, wenn er sich vertippte. Ein Menü zeigt, was es
/// gibt, und was gerade gilt.
class PlaybackRateButton extends StatelessWidget {
  const PlaybackRateButton({super.key, this.compact = false});

  /// In der Randleiste ist Platz für eine Zahl, nicht für einen Knopf.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final player = FundusScope.of(context).player;
    final tokens = context.fundus;
    final label = '${formatPlaybackRate(player.rate)}×';

    return MenuAnchor(
      menuChildren: [
        for (final rate in PlaybackPreference.rates)
          MenuItemButton(
            onPressed: () => unawaited(player.setRate(rate)),
            leadingIcon: Icon(
              rate == player.rate
                  ? FundusIcons.finished
                  : FundusIcons.unfinished,
              size: FundusIcons.sizeSm,
              color: rate == player.rate ? tokens.accent : tokens.textFaint,
            ),
            child: Text('${formatPlaybackRate(rate)}×'),
          ),
      ],
      builder: (context, controller, _) => compact
          ? TextButton(
              onPressed: controller.isOpen ? controller.close : controller.open,
              child: Text(label),
            )
          : OutlinedButton(
              onPressed: controller.isOpen ? controller.close : controller.open,
              child: Text(label),
            ),
    );
  }
}

/// „1,5" statt „1.5", und „1" statt „1.0".
String formatPlaybackRate(double value) {
  final rounded = value.round();
  return value == rounded ? '$rounded' : '$value'.replaceAll('.', ',');
}

class _ContextPanel extends StatefulWidget {
  const _ContextPanel({this.shrinkWrap = false});

  final bool shrinkWrap;

  @override
  State<_ContextPanel> createState() => _ContextPanelState();
}

class _ContextPanelState extends State<_ContextPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final player = scope.player;
    final tokens = context.fundus;
    // Die Marken *innerhalb* der laufenden Datei. Bei einer Podcast-Folge
    // ist das der Weg zu den Stellen, um die es geht — die Werkkapitel sind
    // dort nur die Folgen selbst.
    final inside = player.trackChapters;
    final chapters = inside.length > 1 ? inside : player.chapters;
    final tracks = player.sources;
    // Chapters only when they really are marks inside a file. A work made of
    // several files also yields one "chapter" per file, all sitting at
    // 00:00 — as a list of twelve episodes that is worse than useless, so
    // those are shown as what they are, with their length.
    final useChapters =
        chapters.length > 1 &&
        chapters.any((chapter) => chapter.position > Duration.zero);
    // A film is one file with no marks in it: a list of one is furniture, and
    // in a video player it is furniture in front of the picture.
    if (!useChapters && tracks.length <= 1) return const SizedBox.shrink();
    final heading = useChapters
        ? 'KAPITEL'
        : player.showsVideo
        ? 'FOLGEN'
        : 'DATEIEN';
    // Läuft eine Folge mit eigenen Marken, stehen die Folgen darunter — beides
    // wird gebraucht: springen innerhalb, wechseln zwischen.
    final alsoTracks = inside.length > 1 && tracks.length > 1;
    final count = useChapters ? chapters.length : tracks.length;
    final foldable = widget.shrinkWrap;

    final entries = <Widget>[
      if (useChapters)
        for (final chapter in chapters)
          _Entry(
            label: chapter.title,
            trailing: formatPlaybackTime(chapter.position),
            active:
                chapter.fileId == player.currentSource?.fileId &&
                chapter.position <= player.position,
            onTap: () => player.jumpToChapter(chapter),
          )
      else
        for (var index = 0; index < tracks.length; index++)
          _Entry(
            label: tracks[index].title,
            trailing: tracks[index].duration == null
                ? null
                : formatPlaybackTime(tracks[index].duration!),
            active: index == player.trackIndex,
            onTap: () => player.jumpToTrack(index),
          ),
      if (alsoTracks) ...[
        const SizedBox(height: FundusSpace.x3),
        Text(
          '${player.showsVideo ? 'FOLGEN' : 'DATEIEN'} · ${tracks.length}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        for (var index = 0; index < tracks.length; index++)
          _Entry(
            label: tracks[index].title,
            trailing: tracks[index].duration == null
                ? null
                : formatPlaybackTime(tracks[index].duration!),
            active: index == player.trackIndex,
            onTap: () => player.jumpToTrack(index),
          ),
      ],
      if (tracks.isEmpty && chapters.isEmpty)
        Text(
          'Keine Titelliste vorhanden.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: tokens.textFaint),
        ),
    ];

    return ListView(
      shrinkWrap: widget.shrinkWrap,
      physics: widget.shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.all(FundusSpace.x4),
      children: [
        if (foldable)
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: FundusRadius.mdAll,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: FundusSpace.x2),
              child: Row(
                children: [
                  Text(
                    '$heading · $count',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const Spacer(),
                  Icon(
                    _open ? FundusIcons.collapse : FundusIcons.expand,
                    size: FundusIcons.sizeSm,
                    color: tokens.textFaint,
                  ),
                ],
              ),
            ),
          )
        else
          Text(heading, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: FundusSpace.x3),
        if (!foldable || _open) ...entries,
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.label,
    required this.active,
    required this.onTap,
    this.trailing,
  });

  final String label;
  final String? trailing;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return InkWell(
      onTap: onTap,
      borderRadius: FundusRadius.mdAll,
      hoverColor: tokens.hover,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FundusSpace.x3,
          vertical: FundusSpace.x2,
        ),
        decoration: BoxDecoration(
          color: active ? tokens.surfaceRaised : null,
          borderRadius: FundusRadius.mdAll,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: active ? tokens.accentRamp.s200 : tokens.text,
                ),
              ),
            ),
            if (trailing != null)
              Text(
                trailing!,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
              ),
          ],
        ),
      ),
    );
  }
}

/// Stopping after a while.
///
/// It shows what is left rather than that it is on: „noch 12 min" is the
/// thing a person wants to know, and „Timer läuft" is not.
class _SleepButton extends StatelessWidget {
  const _SleepButton();

  @override
  Widget build(BuildContext context) {
    final player = FundusScope.of(context).player;
    final tokens = context.fundus;
    final left = player.sleepRemaining;

    if (player.isSleepingAtChapterEnd) {
      return OutlinedButton.icon(
        onPressed: player.cancelSleepTimer,
        icon: Icon(FundusIcons.sleepTimer, size: FundusIcons.sizeSm),
        label: const Text('Bis Kapitelende'),
      );
    }

    if (left != null) {
      return OutlinedButton.icon(
        onPressed: player.cancelSleepTimer,
        icon: Icon(
          FundusIcons.sleepTimer,
          size: FundusIcons.sizeSm,
          color: tokens.accent,
        ),
        label: Text('noch ${_short(left)}'),
      );
    }

    return MenuAnchor(
      menuChildren: [
        for (final minutes in PlaybackPreference.sleepChoices)
          MenuItemButton(
            onPressed: () => player.startSleepTimer(Duration(minutes: minutes)),
            child: Text('$minutes Minuten'),
          ),
      ],
      builder: (context, controller, child) => OutlinedButton.icon(
        onPressed: controller.isOpen ? controller.close : controller.open,
        icon: Icon(FundusIcons.sleepTimer, size: FundusIcons.sizeSm),
        label: const Text('Sleep'),
      ),
    );
  }

  static String _short(Duration value) {
    if (value.inMinutes >= 1) return '${value.inMinutes} min';
    return '${value.inSeconds} s';
  }
}

/// „Nächste Folge in 8" — the card at the end of an episode.
///
/// A series is watched one after another, so the next one starts by itself.
/// What makes that bearable rather than pushy is that it says so first, and
/// that stopping it is one tap on the same card.
class _NextEpisode extends StatelessWidget {
  const _NextEpisode();

  @override
  Widget build(BuildContext context) {
    final player = FundusScope.of(context).player;
    final theme = Theme.of(context);
    final left = player.nextEpisodeIn;

    return Container(
      padding: const EdgeInsets.all(FundusSpace.x6),
      constraints: const BoxConstraints(maxWidth: 360),
      decoration: BoxDecoration(
        color: const Color(0xEE101014),
        borderRadius: FundusRadius.mdAll,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            left == null
                ? 'Nächste Folge'
                : 'Nächste Folge in ${left.inSeconds}',
            style: theme.textTheme.labelMedium?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: FundusSpace.x1),
          Text(
            player.nextEpisodeTitle ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
          ),
          const SizedBox(height: FundusSpace.x4),
          Row(
            children: [
              FilledButton.icon(
                onPressed: player.playNextNow,
                icon: Icon(FundusIcons.play, size: FundusIcons.sizeSm),
                label: const Text('Abspielen'),
              ),
              const SizedBox(width: FundusSpace.x3),
              TextButton(
                onPressed: player.stayHere,
                child: const Text('Nicht jetzt'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The square above the transport: the work's cover, or the picture that
/// belongs to the chapter running now.
///
/// Some podcasts put a picture on every chapter — the screen of the game
/// being discussed, the sleeve of the record. Showing the show's logo instead
/// throws that away, so the chapter's own picture wins while it lasts.
class _NowShowing extends StatelessWidget {
  const _NowShowing({required this.work, required this.imagePath});

  final WorkView work;
  final String? imagePath;

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    if (path == null) return WorkArtwork(work: work, showProgress: false);
    return ClipRRect(
      borderRadius: FundusArtwork.cardRadius,
      child: AspectRatio(
        aspectRatio: 1,
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (context, _, _) =>
              WorkArtwork(work: work, showProgress: false),
        ),
      ),
    );
  }
}
