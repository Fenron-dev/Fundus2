/// Which season and episode a file belongs to, read off its name.
///
/// Nobody writes this down anywhere a program can ask; it is in the file name
/// and in the folder above it, in the handful of spellings the world settled
/// on. Everything else — a file that says nothing about a season — is simply
/// unnumbered, and a shelf shows it as such rather than inventing a one.
final class EpisodeNumber {
  const EpisodeNumber({this.season, this.episode});

  final int? season;
  final int? episode;

  bool get isEmpty => season == null && episode == null;
}

/// The patterns worth trying, best first.
final _patterns = <RegExp>[
  // S01E02, s1e2, S01.E02, S01 E02
  RegExp(r's(\d{1,3})[\s._-]*e(\d{1,4})', caseSensitive: false),
  // 1x02
  RegExp(r'(?<![\d])(\d{1,3})x(\d{1,4})(?![\d])', caseSensitive: false),
];

final _seasonFolder = RegExp(
  r'^(?:season|staffel|series)[\s._-]*(\d{1,3})$',
  caseSensitive: false,
);

final _episodeOnly = RegExp(
  r'(?:^|[\s._-])(?:e|ep|episode|folge)[\s._-]*(\d{1,4})(?![\d])',
  caseSensitive: false,
);

/// Reads the season and episode out of [path].
///
/// [path] is the file's way below the work — `Season 2/S02E04 - Titel.mkv` or
/// just the file name. The folder is consulted only where the name itself
/// says nothing about a season, because the name is the more specific
/// statement of the two.
EpisodeNumber episodeNumberOf(String path) {
  final parts = path
      .split(RegExp(r'[/\\]'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return const EpisodeNumber();
  final name = parts.last;

  for (final pattern in _patterns) {
    final match = pattern.firstMatch(name);
    if (match == null) continue;
    return EpisodeNumber(
      season: int.tryParse(match.group(1)!),
      episode: int.tryParse(match.group(2)!),
    );
  }

  int? season;
  for (final folder in parts.take(parts.length - 1)) {
    final match = _seasonFolder.firstMatch(folder.trim());
    if (match != null) season = int.tryParse(match.group(1)!);
  }
  final episode = _episodeOnly.firstMatch(name);
  return EpisodeNumber(
    season: season,
    episode: episode == null ? null : int.tryParse(episode.group(1)!),
  );
}
