import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// Phosphor icons, named the way the design names them.
///
/// The prototype writes icons by name (`ph ph-headphones`,
/// `ph-fill ph-hard-drives`). Keeping that mapping in one place means a symbol
/// and its meaning cannot drift apart, and swapping the icon set later is one
/// file rather than a search across the app.
abstract final class FundusIcons {
  // Shell.
  static final vault = PhosphorIcons.diamondsFour(PhosphorIconsStyle.fill);
  static final vaultSwitch = PhosphorIcons.caretUpDown();
  static final dashboard = PhosphorIcons.squaresFour();
  static final resume = PhosphorIcons.playCircle();
  static final favourites = PhosphorIcons.heart();
  static final lists = PhosphorIcons.queue();
  static final newMediaType = PhosphorIcons.plusCircle();
  static final downloads = PhosphorIcons.downloadSimple();
  static final settings = PhosphorIcons.gearSix();
  static final sync = PhosphorIcons.arrowsClockwise();
  static final sidebar = PhosphorIcons.sidebarSimple();

  // Header.
  static final back = PhosphorIcons.caretLeft();
  static final forward = PhosphorIcons.caretRight();
  static final search = PhosphorIcons.magnifyingGlass();
  static final filter = PhosphorIcons.funnelSimple();
  static final sort = PhosphorIcons.sortAscending();
  static final devices = PhosphorIcons.devices();
  static final activity = PhosphorIcons.bellSimple();

  // Media types.
  static final audiobook = PhosphorIcons.headphones();
  static final film = PhosphorIcons.filmSlate();
  static final series = PhosphorIcons.monitorPlay();
  static final anime = PhosphorIcons.sparkle();
  static final manga = PhosphorIcons.bookOpenText();
  static final novel = PhosphorIcons.scroll();
  static final book = PhosphorIcons.books();
  static final document = PhosphorIcons.fileText();
  static final pdf = PhosphorIcons.filePdf();
  static final ttrpg = PhosphorIcons.diceSix();
  static final photo = PhosphorIcons.imageSquare();
  static final music = PhosphorIcons.musicNotes();
  static final protected = PhosphorIcons.lockSimple();
  static final folder = PhosphorIcons.folder();

  // Origin marks — see [FundusOrigin]. Always these five, never recoloured.
  static final originLocal = PhosphorIcons.hardDrives(PhosphorIconsStyle.fill);
  static final originStream = PhosphorIcons.broadcast();
  static final originOffline = PhosphorIcons.cloudCheck(
    PhosphorIconsStyle.fill,
  );
  static final originUnreachable = PhosphorIcons.plugs();
  static final originArchive = PhosphorIcons.archive();

  // Playback and reading.
  static final play = PhosphorIcons.play(PhosphorIconsStyle.fill);
  static final pause = PhosphorIcons.pause(PhosphorIconsStyle.fill);
  static final skipBack = PhosphorIcons.skipBack(PhosphorIconsStyle.fill);
  static final skipForward = PhosphorIcons.skipForward(PhosphorIconsStyle.fill);
  static final bookmark = PhosphorIcons.bookmarkSimple();
  static final sleepTimer = PhosphorIcons.moon();
  static final expand = PhosphorIcons.caretUp();
  static final collapse = PhosphorIcons.caretDown();
  static final shuffle = PhosphorIcons.shuffle();
  static final repeat = PhosphorIcons.repeat();
  static final repeatOne = PhosphorIcons.repeatOnce();
  static final audioTrack = PhosphorIcons.speakerHigh();
  static final subtitles = PhosphorIcons.closedCaptioning();
  static final fullscreen = PhosphorIcons.cornersOut();
  static final camera = PhosphorIcons.camera();

  // Pairing.
  static final qrCode = PhosphorIcons.qrCode();
  static final scan = PhosphorIcons.scan();
  static final torch = PhosphorIcons.flashlight();

  // Views and states.
  static final viewGrid = PhosphorIcons.gridFour();
  static final viewTable = PhosphorIcons.rows();
  static final viewFolder = PhosphorIcons.treeStructure();
  static final empty = PhosphorIcons.circleDashed();
  static final warning = PhosphorIcons.warning();
  static final note = PhosphorIcons.notePencil();
  static final person = PhosphorIcons.userCircle();
  static final check = PhosphorIcons.check(PhosphorIconsStyle.fill);
  static final close = PhosphorIcons.x();

  /// Icon sizes used by the interface. Anything else is a mistake.
  static const sizeSm = 14.0;
  static const sizeMd = 18.0;
  static const sizeLg = 22.0;

  static IconData? byMediaKindKey(String key) => switch (key) {
    'audiobook' || 'hoerbuch' => audiobook,
    'movie' || 'film' || 'filme' => film,
    'series' || 'serie' || 'serien' => series,
    'anime' => anime,
    'manga' || 'comic' => manga,
    'novel' || 'webnovel' || 'novels' => novel,
    'book' || 'ebook' || 'buecher' => book,
    'document' || 'pdf' => document,
    'ttrpg' => ttrpg,
    'photo' || 'image' || 'fotos' => photo,
    'music' || 'album' || 'track' => music,
    'protected' || 'hhh' => protected,
    _ => null,
  };
}
