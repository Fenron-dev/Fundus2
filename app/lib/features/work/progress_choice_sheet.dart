import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../data/work_view.dart';

/// What the sheet came back with.
final class ProgressChoiceAnswer {
  const ProgressChoiceAnswer({required this.takeOther, required this.always});

  /// Whether to continue from the other device's place.
  final bool takeOther;

  /// Whether to stop asking and always take whichever is furthest along.
  final bool always;
}

/// „Wo weitermachen?"
///
/// A sheet rather than a dialog: it is a decision about the thing that is
/// about to start, so it comes up from the bottom, over the work, within
/// thumb's reach. Both sides are named by the device they came from and shown
/// in the terms the work is measured in — „3:26:41 · vor 12 Min" is something
/// to weigh up, `12401.0` is not — and the one that is furthest along says so,
/// because that is the answer most of the time.
Future<ProgressChoiceAnswer?> showProgressChoiceSheet(
  BuildContext context, {
  required WorkView work,
  required LibraryProgressChoice other,
  LibraryPlaybackProgress? mine,
  required String thisDevice,
  List<LibraryPlaybackTrack> tracks = const [],
}) => showModalBottomSheet<ProgressChoiceAnswer>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: context.fundus.surface,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
  ),
  builder: (context) => _ProgressChoiceSheet(
    work: work,
    other: other,
    mine: mine,
    thisDevice: thisDevice,
    tracks: tracks,
  ),
);

class _ProgressChoiceSheet extends StatefulWidget {
  const _ProgressChoiceSheet({
    required this.work,
    required this.other,
    required this.mine,
    required this.thisDevice,
    required this.tracks,
  });

  final WorkView work;
  final LibraryProgressChoice other;
  final LibraryPlaybackProgress? mine;
  final String thisDevice;

  /// The work's files in reading order. Two things need them: saying which
  /// chapter a page belongs to, and knowing which of two pages is further —
  /// „Seite 1" of chapter two is ahead of „Seite 12" of chapter one.
  final List<LibraryPlaybackTrack> tracks;

  @override
  State<_ProgressChoiceSheet> createState() => _ProgressChoiceSheetState();
}

class _ProgressChoiceSheetState extends State<_ProgressChoiceSheet> {
  late bool _takeOther = _otherIsFurther;
  bool _always = false;

  List<String> get _order => [for (final track in widget.tracks) track.fileId];

  bool get _otherIsFurther {
    final mine = widget.mine?.position;
    if (mine == null) return true;
    return comparePositions(widget.other.position, mine, fileOrder: _order) > 0;
  }

  /// „Kapitel 2 · Seite 1" rather than „Seite 1", where the work is made of
  /// files: a page number on its own says nothing about where it lies.
  String _describe(MediaPosition? position) {
    if (position == null) return 'Noch nicht geöffnet';
    if (widget.tracks.length < 2) return position.displayValue;
    final file = widget.tracks
        .where((track) => track.fileId == position.fileId)
        .firstOrNull;
    if (file == null) return position.displayValue;
    return '${file.title} · ${position.displayValue}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final chosen = _takeOther
        ? _describe(widget.other.position)
        : widget.mine == null
        ? 'Anfang'
        : _describe(widget.mine!.position);

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
            Row(
              children: [
                Icon(
                  FundusIcons.devices,
                  size: FundusIcons.sizeLg,
                  color: tokens.accentRamp.s300,
                ),
                const SizedBox(width: FundusSpace.x3),
                Expanded(
                  child: Text(
                    'Wo weitermachen?',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: FundusSpace.x1),
            Text(
              [widget.work.title, ?widget.other.position.label].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: tokens.textMuted,
              ),
            ),
            const SizedBox(height: FundusSpace.x4),
            Text(
              'Zwei Geräte haben unterschiedliche Stände für dieses Werk.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: FundusSpace.x4),
            _Side(
              where: widget.other.origin,
              label: _describe(widget.other.position),
              at: widget.other.updatedAt,
              furthest: _otherIsFurther,
              selected: _takeOther,
              onTap: () => setState(() => _takeOther = true),
            ),
            const SizedBox(height: FundusSpace.x2),
            _Side(
              where: 'Dieses Gerät · ${widget.thisDevice}',
              label: _describe(widget.mine?.position),
              at: widget.mine?.updatedAt,
              furthest: !_otherIsFurther && widget.mine != null,
              selected: !_takeOther,
              onTap: () => setState(() => _takeOther = false),
            ),
            const SizedBox(height: FundusSpace.x2),
            CheckboxListTile(
              value: _always,
              onChanged: (value) => setState(() => _always = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                'Künftig immer die weiteste Stelle',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: FundusSpace.x2),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Abbrechen'),
                  ),
                ),
                const SizedBox(width: FundusSpace.x3),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(
                      ProgressChoiceAnswer(
                        takeOther: _takeOther,
                        always: _always,
                      ),
                    ),
                    icon: Icon(FundusIcons.play, size: FundusIcons.sizeSm),
                    label: Text('Ab $chosen'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One device's place, as a card that can be picked.
class _Side extends StatelessWidget {
  const _Side({
    required this.where,
    required this.label,
    required this.at,
    required this.furthest,
    required this.selected,
    required this.onTap,
  });

  final String where;
  final String label;
  final DateTime? at;
  final bool furthest;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final line = [label, if (at case final moment?) _ago(moment)].join(' · ');

    return Material(
      color: selected ? tokens.accentTint(0.12) : tokens.surfaceRaised,
      borderRadius: FundusRadius.lgAll,
      child: InkWell(
        onTap: onTap,
        borderRadius: FundusRadius.lgAll,
        child: Container(
          padding: const EdgeInsets.all(FundusSpace.x4),
          decoration: BoxDecoration(
            borderRadius: FundusRadius.lgAll,
            border: Border.fromBorderSide(
              BorderSide(
                color: selected ? tokens.accent : tokens.divider,
                width: selected ? 1.5 : 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                FundusIcons.devices,
                size: FundusIcons.sizeMd,
                color: selected ? tokens.accentRamp.s300 : tokens.textFaint,
              ),
              const SizedBox(width: FundusSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      where,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tokens.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (furthest) ...[
                const SizedBox(width: FundusSpace.x2),
                const FundusTag('weiteste'),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// „vor 12 Min" says more here than a date does — the question is which of
  /// these two happened last.
  static String _ago(DateTime value) {
    final span = DateTime.now().difference(value.toLocal());
    if (span.inMinutes < 1) return 'gerade eben';
    if (span.inMinutes < 60) return 'vor ${span.inMinutes} Min';
    if (span.inHours < 24) return 'vor ${span.inHours} Std';
    if (span.inDays == 1) return 'gestern';
    if (span.inDays < 7) return 'vor ${span.inDays} Tagen';
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year}';
  }
}
