import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';

/// An album, and one picture out of it.
///
/// Two states rather than two screens: the grid is where an album is, and a
/// picture opens over it. Leaving the picture goes back to the grid, leaving
/// the grid goes back to the library — what a person expects from every
/// gallery they have ever used, and worth matching exactly.
class PhotoScreen extends StatelessWidget {
  const PhotoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final photos = scope.photos;
    final tokens = context.fundus;

    return ColoredBox(
      color: tokens.background,
      child: SafeArea(
        child: Column(
          children: [
            if (photos.index == null || photos.showsChrome)
              _Header(
                title: photos.index == null
                    ? photos.work?.title ?? 'Fotos'
                    : photos.pictures[photos.index!].title,
                subtitle: photos.index == null
                    ? '${photos.pictures.length} Bilder'
                    : '${photos.index! + 1} von ${photos.pictures.length}',
                onBack: photos.index == null
                    ? scope.leavePhotos
                    : photos.closePicture,
              ),
            Expanded(
              child: photos.failure != null
                  ? Center(
                      child: Text(
                        photos.failure!,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : photos.index == null
                  ? const _Grid()
                  : const _Single(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onBack,
  });

  final String title;
  final String subtitle;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);

    return Container(
      height: FundusShellMetrics.headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x3),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.divider)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: Icon(FundusIcons.back, size: FundusIcons.sizeMd),
            tooltip: 'Zurück',
          ),
          const SizedBox(width: FundusSpace.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: tokens.textFaint,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: FundusScope.of(context).toggleFullscreen,
            icon: Icon(FundusIcons.fullscreen, size: FundusIcons.sizeMd),
            tooltip: 'Vollbild',
          ),
        ],
      ),
    );
  }
}

/// The album.
class _Grid extends StatelessWidget {
  const _Grid();

  @override
  Widget build(BuildContext context) {
    final photos = FundusScope.of(context).photos;
    final tokens = context.fundus;

    return GridView.builder(
      padding: const EdgeInsets.all(FundusSpace.x3),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: FundusSpace.x2,
        crossAxisSpacing: FundusSpace.x2,
      ),
      itemCount: photos.pictures.length,
      itemBuilder: (context, index) {
        final picture = photos.pictures[index];
        // Fetched as it scrolls into view: an album on another machine comes
        // over picture by picture, not all at once.
        photos.ensure(picture);
        final path = photos.pathFor(picture);
        return InkWell(
          onTap: () => photos.show(index),
          child: ClipRRect(
            borderRadius: FundusRadius.smAll,
            child: ColoredBox(
              color: tokens.surfaceRaised,
              child: path == null
                  ? Center(
                      child: Icon(
                        FundusIcons.photo,
                        size: FundusIcons.sizeLg,
                        color: tokens.textFaint,
                      ),
                    )
                  : Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      cacheWidth: 320,
                      errorBuilder: (context, error, stack) => Icon(
                        FundusIcons.warning,
                        size: FundusIcons.sizeMd,
                        color: tokens.textFaint,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// One picture, as large as the window allows.
class _Single extends StatefulWidget {
  const _Single();

  @override
  State<_Single> createState() => _SingleState();
}

class _SingleState extends State<_Single> {
  late final PageController _controller = PageController(
    initialPage: FundusScope.of(context).photos.index ?? 0,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photos = FundusScope.of(context).photos;
    final tokens = context.fundus;

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
            event.logicalKey == LogicalKeyboardKey.space) {
          photos.next();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          photos.previous();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          photos.closePicture();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: photos.toggleChrome,
        child: PageView.builder(
          controller: _controller,
          onPageChanged: photos.show,
          itemCount: photos.pictures.length,
          itemBuilder: (context, index) {
            final path = photos.pathFor(photos.pictures[index]);
            if (path == null) {
              return const Center(child: CircularProgressIndicator());
            }
            // Zoom and pan on the picture itself; the page still swipes when
            // it is not zoomed in.
            return InteractiveViewer(
              maxScale: 6,
              child: Center(
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) => Text(
                    'Dieses Bild lässt sich nicht anzeigen.',
                    style: TextStyle(color: tokens.textMuted),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
