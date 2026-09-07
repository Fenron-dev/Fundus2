import 'dart:async';

import '../model/media_position.dart';

enum PublicationRendererKind { reflow, fixedDocument, comic, plainText }

enum MediaEngineCapability {
  pageSeeking,
  chapterNavigation,
  tableOfContents,
  search,
  zoom,
  layout,
  readingDirection,
  continuousScroll,
  textSelection,
  annotations,
  forms,
  externalOpen,
}

enum MediaEngineCommand {
  previousPage,
  nextPage,
  previousChapter,
  nextChapter,
  toggleControls,
}

enum PublicationReaderLayout {
  singlePage,
  doublePage,
  continuousVertical,
  continuousHorizontal,
  webtoon,
}

enum PublicationReadingDirection { leftToRight, rightToLeft }

enum PublicationPageScale { fitScreen, fitWidth, fitHeight, original }

enum PublicationChapterTransition { confirm, automatic }

enum PublicationProgressPlacement { automatic, bottom, left, right }

/// What a tap in the side zones does.
///
/// Keeping this separate from the reading direction matters on phones: some
/// users want the physical left side to mean "back" even for RTL material,
/// while others want side taps disabled so a scroll never turns a page.
enum PublicationTapNavigation {
  automatic('Leserichtung'),
  leftPrevious('Links zurück · rechts vor'),
  leftNext('Links vor · rechts zurück'),
  disabled('Seitlich nicht blättern');

  const PublicationTapNavigation(this.label);

  final String label;
}

final class PublicationReaderProfile {
  const PublicationReaderProfile({
    this.layout = PublicationReaderLayout.singlePage,
    this.readingDirection = PublicationReadingDirection.leftToRight,
    this.pageScale = PublicationPageScale.fitScreen,
    this.firstPageIsCover = true,
    this.pageGap = 8,
    this.readerWidth = 1,
    this.tapZoneWidth = .3,
    this.invertTapZones = false,
    this.preloadCount = 2,
    this.chapterTransition = PublicationChapterTransition.confirm,
    this.progressPlacement = PublicationProgressPlacement.automatic,
    this.tapNavigation = PublicationTapNavigation.automatic,
  }) : assert(pageGap >= 0 && pageGap <= 64),
       assert(readerWidth >= .4 && readerWidth <= 1),
       assert(tapZoneWidth >= .15 && tapZoneWidth <= .45),
       assert(preloadCount >= 0 && preloadCount <= 8);

  static const schemaVersion = 5;

  final PublicationReaderLayout layout;
  final PublicationReadingDirection readingDirection;
  final PublicationPageScale pageScale;
  final bool firstPageIsCover;
  final double pageGap;
  final double readerWidth;
  final double tapZoneWidth;
  final bool invertTapZones;
  final int preloadCount;
  final PublicationChapterTransition chapterTransition;
  final PublicationProgressPlacement progressPlacement;
  final PublicationTapNavigation tapNavigation;

  PublicationReaderProfile copyWith({
    PublicationReaderLayout? layout,
    PublicationReadingDirection? readingDirection,
    PublicationPageScale? pageScale,
    bool? firstPageIsCover,
    double? pageGap,
    double? readerWidth,
    double? tapZoneWidth,
    bool? invertTapZones,
    int? preloadCount,
    PublicationChapterTransition? chapterTransition,
    PublicationProgressPlacement? progressPlacement,
    PublicationTapNavigation? tapNavigation,
  }) => PublicationReaderProfile(
    layout: layout ?? this.layout,
    readingDirection: readingDirection ?? this.readingDirection,
    pageScale: pageScale ?? this.pageScale,
    firstPageIsCover: firstPageIsCover ?? this.firstPageIsCover,
    pageGap: pageGap ?? this.pageGap,
    readerWidth: readerWidth ?? this.readerWidth,
    tapZoneWidth: tapZoneWidth ?? this.tapZoneWidth,
    invertTapZones: invertTapZones ?? this.invertTapZones,
    preloadCount: preloadCount ?? this.preloadCount,
    chapterTransition: chapterTransition ?? this.chapterTransition,
    progressPlacement: progressPlacement ?? this.progressPlacement,
    tapNavigation: tapNavigation ?? this.tapNavigation,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'layout': layout.name,
    'reading_direction': readingDirection.name,
    'page_scale': pageScale.name,
    'first_page_is_cover': firstPageIsCover,
    'page_gap': pageGap,
    'reader_width': readerWidth,
    'tap_zone_width': tapZoneWidth,
    'invert_tap_zones': invertTapZones,
    'preload_count': preloadCount,
    'chapter_transition': chapterTransition.name,
    'progress_placement': progressPlacement.name,
    'tap_navigation': tapNavigation.name,
  };

  factory PublicationReaderProfile.fromJson(Map<String, Object?> json) {
    final version = json['schema_version'];
    if (version != 1 &&
        version != 2 &&
        version != 3 &&
        version != 4 &&
        version != schemaVersion) {
      throw const FormatException('Nicht unterstütztes Reader-Profil.');
    }
    final pageGap = (json['page_gap'] as num?)?.toDouble();
    final readerWidth = version == 1
        ? 1.0
        : (json['reader_width'] as num?)?.toDouble();
    final tapZoneWidth = version == 1
        ? .3
        : (json['tap_zone_width'] as num?)?.toDouble() ?? .3;
    final invertTapZones = version == 1
        ? false
        : json['invert_tap_zones'] as bool? ?? false;
    final chapterTransition =
        version == 3 || version == 4 || version == schemaVersion
        ? PublicationChapterTransition.values.byName(
            json['chapter_transition'] as String,
          )
        : PublicationChapterTransition.confirm;
    final progressPlacement = version == 4 || version == schemaVersion
        ? PublicationProgressPlacement.values.byName(
            json['progress_placement'] as String,
          )
        : PublicationProgressPlacement.automatic;
    final tapNavigation = version == schemaVersion
        ? PublicationTapNavigation.values.byName(
            json['tap_navigation'] as String,
          )
        : PublicationTapNavigation.automatic;
    final preloadCount = json['preload_count'];
    if (pageGap == null ||
        !pageGap.isFinite ||
        pageGap < 0 ||
        pageGap > 64 ||
        readerWidth == null ||
        !readerWidth.isFinite ||
        readerWidth < .4 ||
        readerWidth > 1 ||
        !tapZoneWidth.isFinite ||
        tapZoneWidth < .15 ||
        tapZoneWidth > .45 ||
        preloadCount is! int ||
        preloadCount < 0 ||
        preloadCount > 8 ||
        json['first_page_is_cover'] is! bool) {
      throw const FormatException('Ungültige Reader-Profilwerte.');
    }
    return PublicationReaderProfile(
      layout: PublicationReaderLayout.values.byName(json['layout'] as String),
      readingDirection: PublicationReadingDirection.values.byName(
        json['reading_direction'] as String,
      ),
      pageScale: PublicationPageScale.values.byName(
        json['page_scale'] as String,
      ),
      firstPageIsCover: json['first_page_is_cover'] as bool,
      pageGap: pageGap,
      readerWidth: readerWidth,
      tapZoneWidth: tapZoneWidth,
      invertTapZones: invertTapZones,
      preloadCount: preloadCount,
      chapterTransition: chapterTransition,
      progressPlacement: progressPlacement,
      tapNavigation: tapNavigation,
    );
  }
}

enum ReflowFontFamily { system, serif, sansSerif, monospace }

enum ReflowTheme { followApp, paper, sepia, night }

/// Womit im Text die Leiste erscheint.
///
/// Ein einfacher Tipp geht im Text unter: die Auswahl greift zuerst, und
/// dann steht ein Wort markiert da statt eines Menüs offen. Zwei Finger sind
/// eindeutig — sie meinen nie eine Textstelle. Wer trotzdem lieber einmal
/// tippt, stellt es um.
enum ReaderMenuGesture {
  tap('Ein Tipp'),
  twoFingers('Tipp mit zwei Fingern');

  const ReaderMenuGesture(this.label);

  final String label;
}

/// How a text is set on the page.
///
/// Kept apart from [PublicationReaderProfile] because a novel and a comic
/// share nothing here: one is about type, the other about page geometry.
final class ReflowReaderProfile {
  const ReflowReaderProfile({
    this.fontFamily = ReflowFontFamily.system,
    this.fontSize = 19,
    this.lineHeight = 1.55,
    this.contentWidth = 760,
    this.paragraphSpacing = 18,
    this.theme = ReflowTheme.followApp,
    this.menuGesture = ReaderMenuGesture.twoFingers,
  });

  static const schemaVersion = 1;

  final ReflowFontFamily fontFamily;
  final double fontSize;
  final double lineHeight;

  /// The measure, in logical pixels. A line running the full width of a
  /// desktop window is unreadable however good the type is.
  final double contentWidth;
  final double paragraphSpacing;
  final ReflowTheme theme;

  /// Womit die Leiste kommt und geht.
  final ReaderMenuGesture menuGesture;

  ReflowReaderProfile copyWith({
    ReflowFontFamily? fontFamily,
    double? fontSize,
    double? lineHeight,
    double? contentWidth,
    double? paragraphSpacing,
    ReflowTheme? theme,
    ReaderMenuGesture? menuGesture,
  }) => ReflowReaderProfile(
    fontFamily: fontFamily ?? this.fontFamily,
    fontSize: (fontSize ?? this.fontSize).clamp(12, 40),
    lineHeight: (lineHeight ?? this.lineHeight).clamp(1.1, 2.4),
    contentWidth: (contentWidth ?? this.contentWidth).clamp(320, 1400),
    paragraphSpacing: (paragraphSpacing ?? this.paragraphSpacing).clamp(0, 48),
    theme: theme ?? this.theme,
    menuGesture: menuGesture ?? this.menuGesture,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'font_family': fontFamily.name,
    'font_size': fontSize,
    'line_height': lineHeight,
    'content_width': contentWidth,
    'paragraph_spacing': paragraphSpacing,
    'theme': theme.name,
    'menu_gesture': menuGesture.name,
  };

  factory ReflowReaderProfile.fromJson(Map<String, Object?> json) {
    final version = json['schema_version'];
    if (version != null && version != schemaVersion) {
      throw const FormatException('Nicht unterstütztes Textprofil.');
    }
    return const ReflowReaderProfile().copyWith(
      fontFamily: ReflowFontFamily.values
          .where((value) => value.name == json['font_family'])
          .firstOrNull,
      fontSize: (json['font_size'] as num?)?.toDouble(),
      lineHeight: (json['line_height'] as num?)?.toDouble(),
      contentWidth: (json['content_width'] as num?)?.toDouble(),
      paragraphSpacing: (json['paragraph_spacing'] as num?)?.toDouble(),
      theme: ReflowTheme.values
          .where((value) => value.name == json['theme'])
          .firstOrNull,
      menuGesture: ReaderMenuGesture.values
          .where((value) => value.name == json['menu_gesture'])
          .firstOrNull,
    );
  }
}

final class PublicationFormatDescriptor {
  const PublicationFormatDescriptor({
    required this.format,
    required this.renderer,
    required this.positionKind,
    required this.capabilities,
  });

  final String format;
  final PublicationRendererKind renderer;
  final MediaPositionKind positionKind;
  final Set<MediaEngineCapability> capabilities;

  bool supports(MediaEngineCapability capability) =>
      capabilities.contains(capability);
}

abstract interface class PublicationEngine {
  PublicationFormatDescriptor? probe(String sourcePath);

  Future<void> prepare(String sourcePath);

  Future<void> open(MediaPosition? initialPosition);

  Stream<MediaPosition> get positions;

  Future<void> seek(MediaPosition position);

  Future<void> command(MediaEngineCommand command);

  Future<MediaPosition?> snapshot();

  Future<void> close();
}

final class PublicationFormatRegistry {
  const PublicationFormatRegistry();

  PublicationFormatDescriptor? probe(String sourcePath) {
    final separator = sourcePath.lastIndexOf('.');
    if (separator < 0) return null;
    return descriptorForExtension(sourcePath.substring(separator));
  }

  PublicationFormatDescriptor? descriptorForExtension(String extension) =>
      switch (_normalize(extension)) {
        '.epub' => epub,
        '.pdf' => pdf,
        '.cbz' => cbz,
        '.html' || '.htm' => webDocument,
        '.txt' || '.md' || '.markdown' => plainText,
        _ => null,
      };

  static String _normalize(String extension) {
    final normalized = extension.trim().toLowerCase();
    return normalized.startsWith('.') ? normalized : '.$normalized';
  }

  static const epub = PublicationFormatDescriptor(
    format: 'EPUB',
    renderer: PublicationRendererKind.reflow,
    positionKind: MediaPositionKind.epubCfi,
    capabilities: {
      MediaEngineCapability.chapterNavigation,
      MediaEngineCapability.tableOfContents,
      MediaEngineCapability.search,
      MediaEngineCapability.layout,
      MediaEngineCapability.readingDirection,
      MediaEngineCapability.continuousScroll,
      MediaEngineCapability.textSelection,
      MediaEngineCapability.annotations,
      MediaEngineCapability.externalOpen,
    },
  );

  static const pdf = PublicationFormatDescriptor(
    format: 'PDF',
    renderer: PublicationRendererKind.fixedDocument,
    positionKind: MediaPositionKind.page,
    capabilities: {
      MediaEngineCapability.pageSeeking,
      MediaEngineCapability.search,
      MediaEngineCapability.zoom,
      MediaEngineCapability.layout,
      MediaEngineCapability.textSelection,
      MediaEngineCapability.annotations,
      MediaEngineCapability.forms,
      MediaEngineCapability.externalOpen,
    },
  );

  static const cbz = PublicationFormatDescriptor(
    format: 'CBZ',
    renderer: PublicationRendererKind.comic,
    positionKind: MediaPositionKind.imageIndex,
    capabilities: {
      MediaEngineCapability.pageSeeking,
      MediaEngineCapability.chapterNavigation,
      MediaEngineCapability.zoom,
      MediaEngineCapability.layout,
      MediaEngineCapability.readingDirection,
      MediaEngineCapability.continuousScroll,
      MediaEngineCapability.annotations,
      MediaEngineCapability.externalOpen,
    },
  );

  static const plainText = PublicationFormatDescriptor(
    format: 'Text',
    renderer: PublicationRendererKind.plainText,
    positionKind: MediaPositionKind.epubCfi,
    capabilities: {
      MediaEngineCapability.search,
      MediaEngineCapability.layout,
      MediaEngineCapability.continuousScroll,
      MediaEngineCapability.textSelection,
      MediaEngineCapability.annotations,
      MediaEngineCapability.externalOpen,
    },
  );

  static const webDocument = PublicationFormatDescriptor(
    format: 'HTML',
    renderer: PublicationRendererKind.reflow,
    positionKind: MediaPositionKind.epubCfi,
    capabilities: {
      MediaEngineCapability.chapterNavigation,
      MediaEngineCapability.search,
      MediaEngineCapability.layout,
      MediaEngineCapability.readingDirection,
      MediaEngineCapability.continuousScroll,
      MediaEngineCapability.textSelection,
      MediaEngineCapability.annotations,
      MediaEngineCapability.externalOpen,
    },
  );
}
