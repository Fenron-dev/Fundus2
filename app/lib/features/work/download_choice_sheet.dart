import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// Which parts of a work to take along.
///
/// A film is one file and needs no question. A manga with four hundred
/// chapters does: taking all of it is rarely what somebody means, and picking
/// four hundred boxes by hand is not an answer either. So the usual wishes are
/// buttons — the next twenty, everything from here on, all of it — and the
/// exact range is there underneath for the case they do not cover.
///
/// What is already on the device is never offered again; it is simply left
/// out of the count.
Future<Set<String>?> showDownloadChoice(
  BuildContext context, {
  required String title,
  required List<LibraryPlaybackTrack> tracks,
  required Set<String> alreadyHere,
  int startAt = 0,
}) => showModalBottomSheet<Set<String>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: context.fundus.surface,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
  ),
  builder: (context) => _DownloadChoiceSheet(
    title: title,
    tracks: tracks,
    alreadyHere: alreadyHere,
    startAt: startAt,
  ),
);

/// The chapters between [from] and [to], counted from one and clamped to what
/// the work has. Reversed bounds are read the way they were meant.
Set<int> chapterRange({
  required int total,
  required int from,
  required int to,
}) {
  if (total <= 0) return const {};
  final first = (from < to ? from : to).clamp(1, total);
  final last = (from < to ? to : from).clamp(1, total);
  return {for (var index = first - 1; index <= last - 1; index++) index};
}

class _DownloadChoiceSheet extends StatefulWidget {
  const _DownloadChoiceSheet({
    required this.title,
    required this.tracks,
    required this.alreadyHere,
    required this.startAt,
  });

  final String title;
  final List<LibraryPlaybackTrack> tracks;
  final Set<String> alreadyHere;
  final int startAt;

  @override
  State<_DownloadChoiceSheet> createState() => _DownloadChoiceSheetState();
}

class _DownloadChoiceSheetState extends State<_DownloadChoiceSheet> {
  late int _from = widget.startAt + 1;
  late int _to = (widget.startAt + 20).clamp(1, widget.tracks.length);
  late final _fromField = TextEditingController(text: '$_from');
  late final _toField = TextEditingController(text: '$_to');

  @override
  void dispose() {
    _fromField.dispose();
    _toField.dispose();
    super.dispose();
  }

  void _select(int from, int to) {
    setState(() {
      _from = from.clamp(1, widget.tracks.length);
      _to = to.clamp(1, widget.tracks.length);
      _fromField.text = '$_from';
      _toField.text = '$_to';
    });
  }

  void _applyFields() {
    final from = int.tryParse(_fromField.text.trim());
    final to = int.tryParse(_toField.text.trim());
    if (from == null || to == null) return;
    _select(from, to);
  }

  Set<String> get _chosen {
    final indexes = chapterRange(
      total: widget.tracks.length,
      from: _from,
      to: _to,
    );
    return {
      for (final index in indexes)
        if (!widget.alreadyHere.contains(widget.tracks[index].fileId))
          widget.tracks[index].fileId,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final chosen = _chosen;
    final total = widget.tracks.length;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FundusSpace.x6,
          0,
          FundusSpace.x6,
          FundusSpace.x6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Mitnehmen', style: theme.textTheme.titleLarge),
            const SizedBox(height: FundusSpace.x1),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: tokens.textMuted,
              ),
            ),
            const SizedBox(height: FundusSpace.x4),
            Wrap(
              spacing: FundusSpace.x2,
              runSpacing: FundusSpace.x2,
              children: [
                ActionChip(
                  label: const Text('Nächste 20'),
                  onPressed: () =>
                      _select(widget.startAt + 1, widget.startAt + 20),
                ),
                ActionChip(
                  label: const Text('Nächste 50'),
                  onPressed: () =>
                      _select(widget.startAt + 1, widget.startAt + 50),
                ),
                ActionChip(
                  label: const Text('Ab hier'),
                  onPressed: () => _select(widget.startAt + 1, total),
                ),
                ActionChip(
                  label: const Text('Alles'),
                  onPressed: () => _select(1, total),
                ),
              ],
            ),
            const SizedBox(height: FundusSpace.x4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _fromField,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Von'),
                    onSubmitted: (_) => _applyFields(),
                    onTapOutside: (_) => _applyFields(),
                  ),
                ),
                const SizedBox(width: FundusSpace.x4),
                Expanded(
                  child: TextField(
                    controller: _toField,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(labelText: 'Bis (von $total)'),
                    onSubmitted: (_) => _applyFields(),
                    onTapOutside: (_) => _applyFields(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: FundusSpace.x4),
            Text(
              chosen.isEmpty
                  ? 'In diesem Bereich liegt schon alles hier.'
                  : '${chosen.length} von $total werden geholt.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: chosen.isEmpty ? tokens.textFaint : tokens.text,
              ),
            ),
            const SizedBox(height: FundusSpace.x4),
            FilledButton(
              onPressed: chosen.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(chosen),
              child: const Text('Mitnehmen'),
            ),
          ],
        ),
      ),
    );
  }
}
