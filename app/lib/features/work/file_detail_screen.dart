import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/work_view.dart';

/// Details belonging to one file inside a work: an episode, volume, track,
/// or document. The parent work remains the series/container; this screen is
/// where the individual part gets its own title, text, date, progress, and
/// rating.
class FileDetailScreen extends StatefulWidget {
  const FileDetailScreen({
    super.key,
    required this.workId,
    required this.fileId,
  });

  final String workId;
  final String fileId;

  @override
  State<FileDetailScreen> createState() => _FileDetailScreenState();
}

class _FileDetailScreenState extends State<FileDetailScreen> {
  LibraryPlaybackTrack? _track;
  FileDetail? _detail;
  List<LibraryPlaybackChapter> _chapters = const [];
  ({double position, double? total, DateTime updatedAt})? _standing;
  bool _finished = false;
  int? _rating;
  bool _loaded = false;
  String? _failure;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final library = FundusScope.of(context).library.library;
    if (library == null) return;
    try {
      final track = library
          .playbackTracks(widget.workId)
          .where((entry) => entry.fileId == widget.fileId)
          .firstOrNull;
      if (track == null) throw StateError('Dieser Teil existiert nicht mehr.');
      List<LibraryPlaybackChapter> chapters = const [];
      if (!track.isRemote) {
        try {
          chapters = await library.trackChapters(widget.workId, widget.fileId);
        } on Object {
          chapters = const [];
        }
      }
      final rating = library
          .loadAnnotations(widget.workId)
          .ratings
          .where((entry) => entry.fileId == widget.fileId)
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _track = track;
        _detail = library.fileDetails(widget.workId)[widget.fileId];
        _chapters = chapters;
        _standing = library.filePositions(widget.workId)[widget.fileId];
        _finished = library
            .finishedFiles(widget.workId)
            .contains(widget.fileId);
        _rating = rating?.value;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _failure = '$error');
    }
  }

  Future<void> _edit() async {
    final detail = _detail;
    final title = TextEditingController(text: detail?.title ?? _track?.title);
    final description = TextEditingController(text: detail?.description ?? '');
    final date = TextEditingController(
      text: detail?.publishedAt == null ? '' : _isoDate(detail!.publishedAt!),
    );
    final result = await showDialog<({String title, String text, String date})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Teil bearbeiten'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Titel'),
                ),
                const SizedBox(height: FundusSpace.x3),
                TextField(
                  controller: date,
                  decoration: const InputDecoration(
                    labelText: 'Veröffentlichung',
                    hintText: 'JJJJ-MM-TT',
                  ),
                ),
                const SizedBox(height: FundusSpace.x3),
                TextField(
                  controller: description,
                  minLines: 5,
                  maxLines: 12,
                  decoration: const InputDecoration(labelText: 'Beschreibung'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop((
              title: title.text.trim(),
              text: description.text.trim(),
              date: date.text.trim(),
            )),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    title.dispose();
    description.dispose();
    date.dispose();
    if (result == null || !mounted) return;
    final library = FundusScope.of(context).library.library;
    if (library == null || library.isReadOnly) return;
    DateTime? published;
    if (result.date.isNotEmpty) {
      published = DateTime.tryParse(result.date)?.toUtc();
    }
    library.setFileDetail(
      workId: widget.workId,
      fileId: widget.fileId,
      title: result.title.isEmpty ? null : result.title,
      description: result.text.isEmpty ? null : result.text,
      publishedAt: published,
    );
    setState(() {
      _detail = FileDetail(
        title: result.title.isEmpty ? null : result.title,
        description: result.text.isEmpty ? null : result.text,
        publishedAt: published,
      );
    });
  }

  Future<void> _setRating(int value) async {
    final library = FundusScope.of(context).library.library;
    if (library == null || library.isReadOnly) return;
    if (_rating == value) {
      await library.deleteRating(workId: widget.workId, fileId: widget.fileId);
      if (mounted) setState(() => _rating = null);
    } else {
      await library.setRating(
        workId: widget.workId,
        fileId: widget.fileId,
        value: value,
      );
      if (mounted) setState(() => _rating = value);
    }
  }

  void _toggleFinished() {
    final library = FundusScope.of(context).library.library;
    if (library == null || library.isReadOnly) return;
    library.setFileFinished(
      workId: widget.workId,
      fileId: widget.fileId,
      finished: !_finished,
    );
    setState(() => _finished = !_finished);
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final work = scope.library.workById(widget.workId);
    if (_failure != null || work == null) {
      return FundusEmptyState(
        title: 'Teil nicht gefunden',
        reason: _failure ?? 'Das übergeordnete Werk existiert nicht mehr.',
      );
    }
    final track = _track;
    if (track == null) return const Center(child: CircularProgressIndicator());
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final stage = FundusStageSize.of(context);
    final title = _detail?.title ?? track.title;
    final episode = episodeNumberOf(track.relativePath);

    return ListView(
      padding: EdgeInsets.all(stage.gutter),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PartArtwork(work: work),
            const SizedBox(width: FundusSpace.x6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.displaySmall),
                  const SizedBox(height: FundusSpace.x2),
                  Text(
                    [
                      if (episode.season != null) 'Staffel ${episode.season}',
                      if (episode.episode != null) 'Folge ${episode.episode}',
                      if (_detail?.publishedAt case final value?) _date(value),
                      if (track.duration case final value?) _duration(value),
                    ].join(' · '),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.textMuted,
                    ),
                  ),
                  const SizedBox(height: FundusSpace.x4),
                  Wrap(
                    spacing: FundusSpace.x2,
                    runSpacing: FundusSpace.x2,
                    children: [
                      FilledButton.icon(
                        onPressed: () => scope.play(
                          work,
                          startAt: track.fileId,
                          at: _resumePosition,
                        ),
                        icon: Icon(FundusIcons.play),
                        label: Text(
                          _standing == null ? 'Öffnen' : 'Fortsetzen',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _toggleFinished,
                        icon: Icon(
                          _finished
                              ? FundusIcons.finished
                              : FundusIcons.unfinished,
                        ),
                        label: Text(_finished ? 'Abgeschlossen' : 'Als fertig'),
                      ),
                      IconButton(
                        onPressed: () => _setRating(1),
                        isSelected: _rating == 1,
                        tooltip: 'Daumen hoch',
                        icon: const Icon(Icons.thumb_up_outlined),
                        selectedIcon: const Icon(Icons.thumb_up),
                      ),
                      IconButton(
                        onPressed: () => _setRating(-1),
                        isSelected: _rating == -1,
                        tooltip: 'Daumen runter',
                        icon: const Icon(Icons.thumb_down_outlined),
                        selectedIcon: const Icon(Icons.thumb_down),
                      ),
                      OutlinedButton.icon(
                        onPressed: scope.library.library?.isReadOnly == false
                            ? _edit
                            : null,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Bearbeiten'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_progress case final value?) ...[
          const SizedBox(height: FundusSpace.x6),
          LinearProgressIndicator(value: value),
        ],
        const SizedBox(height: FundusSpace.x8),
        Text('BESCHREIBUNG', style: theme.textTheme.labelSmall),
        const SizedBox(height: FundusSpace.x2),
        Text(
          _detail?.description?.trim().isNotEmpty == true
              ? _detail!.description!.trim()
              : 'Für diesen Teil ist noch keine Beschreibung hinterlegt.',
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
        ),
        const SizedBox(height: FundusSpace.x8),
        Text('DATEI', style: theme.textTheme.labelSmall),
        const SizedBox(height: FundusSpace.x2),
        _InfoLine(label: 'Name', value: track.title),
        _InfoLine(label: 'Pfad', value: track.relativePath),
        _InfoLine(
          label: 'Quelle',
          value: track.isRemote ? 'Netzwerkbibliothek' : 'Dieses Gerät',
        ),
        if (_chapters.isNotEmpty) ...[
          const SizedBox(height: FundusSpace.x8),
          Text(
            'KAPITEL · ${_chapters.length}',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: FundusSpace.x2),
          for (final chapter in _chapters)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: chapter.imagePath == null
                  ? const Icon(Icons.bookmark_border)
                  : ClipRRect(
                      borderRadius: FundusRadius.smAll,
                      child: Image.file(
                        File(chapter.imagePath!),
                        width: 64,
                        height: 40,
                        fit: BoxFit.cover,
                      ),
                    ),
              title: Text(chapter.title),
              subtitle: Text(_duration(chapter.position)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => scope.navigation.go(
                ChapterRoute(
                  workId: widget.workId,
                  fileId: widget.fileId,
                  trackIndex: chapter.trackIndex,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Duration? get _resumePosition {
    final value = _standing?.position;
    return value == null
        ? null
        : Duration(milliseconds: (value * 1000).round());
  }

  double? get _progress {
    final standing = _standing;
    if (standing == null || standing.position <= 0) return null;
    final total =
        standing.total ??
        (_track?.duration == null
            ? null
            : _track!.duration!.inMilliseconds / 1000);
    if (total == null || total <= 0) return null;
    return (standing.position / total).clamp(0, 1);
  }
}

class ChapterDetailScreen extends StatefulWidget {
  const ChapterDetailScreen({
    super.key,
    required this.workId,
    required this.fileId,
    required this.trackIndex,
  });

  final String workId;
  final String fileId;
  final int trackIndex;

  @override
  State<ChapterDetailScreen> createState() => _ChapterDetailScreenState();
}

class _ChapterDetailScreenState extends State<ChapterDetailScreen> {
  LibraryPlaybackChapter? _chapter;
  bool _loaded = false;
  bool _finishedLoading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final library = FundusScope.of(context).library.library;
    if (library == null) {
      setState(() => _finishedLoading = true);
      return;
    }
    try {
      final chapters = await library.trackChapters(
        widget.workId,
        widget.fileId,
      );
      final chapter = chapters
          .where((entry) => entry.trackIndex == widget.trackIndex)
          .firstOrNull;
      if (mounted) {
        setState(() {
          _chapter = chapter;
          _finishedLoading = true;
        });
      }
    } on Object {
      if (mounted) setState(() => _finishedLoading = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final work = scope.library.workById(widget.workId);
    final chapter = _chapter;
    if (work == null) {
      return const FundusEmptyState(
        title: 'Kapitel nicht gefunden',
        reason: 'Das übergeordnete Werk existiert nicht mehr.',
      );
    }
    if (!_finishedLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (chapter == null) {
      return const FundusEmptyState(
        title: 'Kapitel nicht gefunden',
        reason: 'Dieses Kapitel ist in der Datei nicht mehr vorhanden.',
      );
    }
    final stage = FundusStageSize.of(context);
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.all(stage.gutter),
      children: [
        if (chapter.imagePath case final path?)
          ClipRRect(
            borderRadius: FundusRadius.mdAll,
            child: Image.file(File(path), height: 280, fit: BoxFit.cover),
          ),
        const SizedBox(height: FundusSpace.x6),
        Text(chapter.title, style: theme.textTheme.displaySmall),
        const SizedBox(height: FundusSpace.x2),
        Text(
          [
            'Start ${_duration(chapter.position)}',
            if (chapter.duration != null)
              'Dauer ${_duration(chapter.duration!)}',
          ].join(' · '),
        ),
        const SizedBox(height: FundusSpace.x6),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () =>
                scope.play(work, startAt: widget.fileId, at: chapter.position),
            icon: Icon(FundusIcons.play),
            label: const Text('Ab hier abspielen'),
          ),
        ),
      ],
    );
  }
}

class _PartArtwork extends StatelessWidget {
  const _PartArtwork({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final path = work.coverPath;
    return ClipRRect(
      borderRadius: FundusRadius.mdAll,
      child: SizedBox(
        width: 120,
        height: 170,
        child: path == null
            ? ColoredBox(
                color: context.fundus.surface,
                child: Icon(FundusIcons.play, size: 36),
              )
            : Image.file(File(path), fit: BoxFit.cover),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: FundusSpace.x1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(label, style: TextStyle(color: context.fundus.textFaint)),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}

String _duration(Duration value) {
  final hours = value.inHours;
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

String _date(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}.'
    '${value.month.toString().padLeft(2, '0')}.${value.year}';

String _isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
