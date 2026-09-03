import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';

/// The page reader, laid over the shell.
///
/// A page fills the window; everything else steps back. The controls sit at
/// the top, never at the bottom edge, which on Android belongs to the system
/// gesture — the same rule the player follows.
class ReaderScreen extends StatelessWidget {
  const ReaderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    final work = reader.work;
    if (work == null) return const SizedBox.shrink();

    final tokens = context.fundus;
    final theme = Theme.of(context);

    return ColoredBox(
      color: tokens.background,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FundusSpace.x4,
                vertical: FundusSpace.x2,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: reader.close,
                    icon: Icon(FundusIcons.collapse, size: FundusIcons.sizeLg),
                    tooltip: 'Schließen',
                  ),
                  const SizedBox(width: FundusSpace.x2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          work.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          reader.positionLabel,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: tokens.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (reader.volumes.length > 1)
                    _VolumeMenu(count: reader.volumes.length),
                  FundusOriginMark(work.origin, showLabel: true),
                ],
              ),
            ),
            const Expanded(child: _Page()),
          ],
        ),
      ),
    );
  }
}

class _VolumeMenu extends StatelessWidget {
  const _VolumeMenu({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    return PopupMenuButton<int>(
      tooltip: 'Band wählen',
      icon: Icon(FundusIcons.lists, size: FundusIcons.sizeLg),
      onSelected: reader.openVolume,
      itemBuilder: (context) => [
        for (var index = 0; index < count; index++)
          PopupMenuItem(
            value: index,
            child: Text(
              reader.volumes[index].title,
              style: index == reader.volumeIndex
                  ? TextStyle(color: context.fundus.accentRamp.s200)
                  : null,
            ),
          ),
      ],
    );
  }
}

class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    final tokens = context.fundus;
    final failure = reader.failure;

    if (failure != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(FundusSpace.x10),
          child: FundusEmptyState(
            icon: FundusIcons.warning,
            title: 'Diese Datei lässt sich nicht öffnen',
            reason: failure,
          ),
        ),
      );
    }

    final file = reader.currentPageFile;
    if (file == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // The whole page area turns: the left third goes back, the rest forward.
    // Keyboard and mouse do the same thing, because on a desktop nobody taps.
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        switch (event.logicalKey) {
          case LogicalKeyboardKey.arrowRight:
          case LogicalKeyboardKey.space:
          case LogicalKeyboardKey.pageDown:
            reader.nextPage();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowLeft:
          case LogicalKeyboardKey.pageUp:
            reader.previousPage();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.escape:
            reader.close();
            return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 4,
                child: Image.file(
                  File(file),
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (context, error, stack) => Center(
                    child: Text(
                      'Diese Seite lässt sich nicht anzeigen.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: tokens.textFaint),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: constraints.maxWidth / 3,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: reader.previousPage,
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: constraints.maxWidth * 2 / 3,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: reader.nextPage,
              ),
            ),
            if (reader.isBusy)
              const Positioned(
                top: FundusSpace.x4,
                right: FundusSpace.x4,
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
