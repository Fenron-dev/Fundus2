import 'package:flutter/widgets.dart';
import 'package:fundus_design/fundus_design.dart';

/// What "how far along" means for a media type.
///
/// A single `position_seconds` for everything is the mistake this enum exists
/// to prevent: a manga remembers a page within a volume, an EPUB a fraction of
/// a chapter (a page number would be wrong at another font size), and a PDF a
/// jump mark that is deliberately never merged into a percentage — in a
/// reference work what matters is where you land, not how far you got.
enum ProgressKind {
  /// Seconds, saved every 30 s.
  seconds(saveInterval: Duration(seconds: 30)),

  /// Page per volume, saved on events only.
  pagePerVolume(),

  /// Fraction within the chapter, saved every 2 minutes.
  chapterFraction(saveInterval: Duration(minutes: 2)),

  /// The page a document was last left on. Never merged across files.
  documentPage(saveInterval: Duration(minutes: 2), merges: false),

  /// A play counter, no position.
  playCount(),

  /// Photos have none.
  none();

  const ProgressKind({this.saveInterval, this.merges = true});

  final Duration? saveInterval;

  /// Whether positions of several files roll up into one work-level number.
  final bool merges;
}

/// A tab on the work detail screen. Tabs are configuration, not code: adding a
/// media type must not mean adding a screen.
enum WorkTab {
  files('Dateien'),
  chapters('Kapitel'),
  episodes('Folgen'),
  volumes('Bände'),
  cast('Besetzung'),
  related('Verwandt'),
  extras('Extras'),
  notes('Notizen'),
  properties('Eigenschaften'),
  devices('Geräte');

  const WorkTab(this.label);

  final String label;
}

/// The "Ordnen nach" switch: the same files, laid out differently.
///
/// The folder view always shows the real disk — including `_Rohscans/`, cache
/// directories and loose files in the root. Everything else is generated from
/// properties. Filters apply in every one of them.
enum GroupingMode {
  tiles('Kacheln', 'viewGrid'),
  table('Tabelle', 'viewTable'),
  folder('Ordner', 'viewFolder'),
  series('Reihe', 'viewTable'),
  author('Urheber', 'viewTable'),
  system('System', 'viewTable'),
  round('Runde', 'viewTable'),
  fileType('Dateityp', 'viewTable'),
  topic('Thema', 'viewTable'),
  time('Zeit', 'viewTable'),
  albums('Alben', 'viewGrid');

  const GroupingMode(this.label, this._icon);

  final String label;
  final String _icon;

  IconData get icon => switch (_icon) {
    'viewGrid' => FundusIcons.viewGrid,
    'viewTable' => FundusIcons.viewTable,
    _ => FundusIcons.viewFolder,
  };
}

/// A media type as data.
///
/// Player, progress kind, detail tabs and grouping modes are configuration.
/// If a new type needs a new widget, the abstraction is wrong.
final class MediaTypeDefinition {
  const MediaTypeDefinition({
    required this.id,
    required this.label,
    required this.icon,
    required this.workKinds,
    required this.progressKind,
    required this.tabs,
    this.groupings = const [
      GroupingMode.tiles,
      GroupingMode.table,
      GroupingMode.folder,
    ],
    this.protected = false,
  });

  final String id;
  final String label;
  final IconData icon;

  /// The `works.kind` values this type collects.
  final Set<String> workKinds;
  final ProgressKind progressKind;
  final List<WorkTab> tabs;
  final List<GroupingMode> groupings;

  /// Types behind the protection mode never appear in search, "Fortsetzen",
  /// statistics or notifications while locked.
  final bool protected;
}

/// The built-in types, in the order the navigation shows them.
abstract final class MediaTypes {
  static final audiobook = MediaTypeDefinition(
    id: 'audiobook',
    label: 'Hörbücher',
    icon: FundusIcons.audiobook,
    workKinds: const {'audiobook', 'podcast', 'podcast_episode'},
    progressKind: ProgressKind.seconds,
    tabs: const [
      WorkTab.files,
      WorkTab.chapters,
      WorkTab.notes,
      WorkTab.properties,
      WorkTab.devices,
    ],
  );

  static final movies = MediaTypeDefinition(
    id: 'movie',
    label: 'Filme',
    icon: FundusIcons.film,
    workKinds: const {'movie'},
    progressKind: ProgressKind.seconds,
    tabs: const [
      WorkTab.files,
      WorkTab.cast,
      WorkTab.related,
      WorkTab.properties,
      WorkTab.devices,
    ],
  );

  static final series = MediaTypeDefinition(
    id: 'series',
    label: 'Serien',
    icon: FundusIcons.series,
    workKinds: const {'series', 'season', 'episode'},
    progressKind: ProgressKind.seconds,
    tabs: const [
      WorkTab.episodes,
      WorkTab.cast,
      WorkTab.extras,
      WorkTab.properties,
      WorkTab.devices,
    ],
  );

  static final anime = MediaTypeDefinition(
    id: 'anime',
    label: 'Anime',
    icon: FundusIcons.anime,
    workKinds: const {'anime', 'anime_season', 'anime_episode'},
    progressKind: ProgressKind.seconds,
    tabs: const [
      WorkTab.episodes,
      WorkTab.related,
      WorkTab.properties,
      WorkTab.devices,
    ],
  );

  static final manga = MediaTypeDefinition(
    id: 'manga',
    label: 'Manga & Comics',
    icon: FundusIcons.manga,
    workKinds: const {'manga', 'chapter', 'comic'},
    progressKind: ProgressKind.pagePerVolume,
    tabs: const [
      WorkTab.volumes,
      WorkTab.related,
      WorkTab.notes,
      WorkTab.properties,
      WorkTab.devices,
    ],
    groupings: const [
      GroupingMode.tiles,
      GroupingMode.table,
      GroupingMode.author,
      GroupingMode.folder,
    ],
  );

  static final novels = MediaTypeDefinition(
    id: 'novel',
    label: 'Light Novels',
    icon: FundusIcons.novel,
    workKinds: const {'webnovel', 'light_novel'},
    progressKind: ProgressKind.chapterFraction,
    tabs: const [
      WorkTab.volumes,
      WorkTab.notes,
      WorkTab.properties,
      WorkTab.devices,
    ],
  );

  static final books = MediaTypeDefinition(
    id: 'book',
    label: 'Bücher & E-Books',
    icon: FundusIcons.book,
    workKinds: const {'book', 'book_series'},
    progressKind: ProgressKind.chapterFraction,
    tabs: const [
      WorkTab.files,
      WorkTab.notes,
      WorkTab.properties,
      WorkTab.devices,
    ],
    groupings: const [
      GroupingMode.tiles,
      GroupingMode.table,
      GroupingMode.series,
      GroupingMode.folder,
    ],
  );

  static final documents = MediaTypeDefinition(
    id: 'document',
    label: 'PDFs & Dokumente',
    icon: FundusIcons.document,
    workKinds: const {'document', 'archive'},
    progressKind: ProgressKind.documentPage,
    tabs: const [WorkTab.files, WorkTab.notes, WorkTab.properties],
    groupings: const [
      GroupingMode.folder,
      GroupingMode.fileType,
      GroupingMode.topic,
      GroupingMode.tiles,
    ],
  );

  static final ttrpg = MediaTypeDefinition(
    id: 'ttrpg',
    label: 'TTRPG',
    icon: FundusIcons.ttrpg,
    workKinds: const {'ttrpg_product'},
    progressKind: ProgressKind.documentPage,
    tabs: const [WorkTab.files, WorkTab.notes, WorkTab.properties],
    groupings: const [
      GroupingMode.round,
      GroupingMode.system,
      GroupingMode.folder,
    ],
  );

  static final photos = MediaTypeDefinition(
    id: 'photo',
    label: 'Fotos',
    icon: FundusIcons.photo,
    workKinds: const {'image'},
    progressKind: ProgressKind.none,
    tabs: const [WorkTab.properties],
    groupings: const [
      GroupingMode.time,
      GroupingMode.albums,
      GroupingMode.folder,
    ],
  );

  static final music = MediaTypeDefinition(
    id: 'music',
    label: 'Musik',
    icon: FundusIcons.music,
    workKinds: const {'album', 'track'},
    progressKind: ProgressKind.playCount,
    tabs: const [WorkTab.files, WorkTab.properties],
  );

  static final protectedType = MediaTypeDefinition(
    id: 'protected',
    label: 'Geschützt',
    icon: FundusIcons.protected,
    workKinds: const {},
    progressKind: ProgressKind.none,
    tabs: const [WorkTab.files, WorkTab.properties],
    protected: true,
  );

  /// Navigation order, as in the prototype.
  static List<MediaTypeDefinition> get all => [
    audiobook,
    movies,
    series,
    anime,
    manga,
    novels,
    books,
    documents,
    ttrpg,
    photos,
    music,
    protectedType,
  ];

  static MediaTypeDefinition? byId(String id) {
    for (final type in all) {
      if (type.id == id) return type;
    }
    return null;
  }

  /// The type a work belongs to, or null when nothing claims its kind — those
  /// works land in "Nicht zugeordnet" rather than being hidden.
  static MediaTypeDefinition? forWorkKind(String kind) {
    for (final type in all) {
      if (type.workKinds.contains(kind)) return type;
    }
    return null;
  }
}
