import 'package:path/path.dart' as p;

/// Where one path below the library root belongs.
final class MediaAreaMatch {
  const MediaAreaMatch({
    required this.kind,
    required this.rootParts,
    required this.remainder,
  });

  /// The configuration key of the area — `audiobook`, `music`, `manga` …
  final String kind;

  /// The segments that named the area, in the spelling the path used.
  final List<String> rootParts;

  /// What is left below the area folder.
  final List<String> remainder;

  String get rootPath => p.posix.joinAll(rootParts);
}

/// Resolves the media area a file belongs to from its folder names.
///
/// The rule the settings screen states — „eingelesen wird nur, was unter
/// diesen Ordnernamen liegt" — is about a *name on the path*, not about the
/// first segment. A vault that keeps its areas one level down (`Medien/Musik`,
/// `Funs/Musik`) is an ordinary way to hold a library, and requiring the area
/// to sit directly at the root made every such folder invisible to the
/// importers: the documents below it were skipped, and every folder with audio
/// in it became an audiobook no matter what it was called.
///
/// So an area is matched wherever its name appears as a whole segment, and the
/// **outermost** match wins: something below `Filme` is a film even if a
/// season folder further down happens to be called `Anime`. Where two areas
/// declare a name at the same depth, the longer declaration wins, so
/// `Medien/Meine Hörbücher` beats a bare `Medien`.
final class MediaAreaMap {
  MediaAreaMap(Map<String, Iterable<String>> mediaRoots)
    : _roots = [
        for (final entry in mediaRoots.entries)
          for (final root in entry.value)
            if (splitPath(root).isNotEmpty)
              (kind: entry.key, parts: splitPath(root)),
      ]..sort((left, right) => right.parts.length.compareTo(left.parts.length));

  final List<({String kind, List<String> parts})> _roots;

  bool get isEmpty => _roots.isEmpty;

  /// The area [parts] lies in, or `null` when no configured name is on it.
  ///
  /// [parts] is a relative path split into segments. The remainder may be
  /// empty — a file lying directly in `Musik` is still music — so callers that
  /// need something below the area folder check the remainder themselves.
  MediaAreaMatch? locate(List<String> parts) {
    for (var start = 0; start < parts.length; start++) {
      for (final root in _roots) {
        if (start + root.parts.length > parts.length) continue;
        var matches = true;
        for (var index = 0; index < root.parts.length; index++) {
          if (root.parts[index].toLowerCase() !=
              parts[start + index].toLowerCase()) {
            matches = false;
            break;
          }
        }
        if (!matches) continue;
        return MediaAreaMatch(
          kind: root.kind,
          rootParts: parts.sublist(0, start + root.parts.length),
          remainder: parts.sublist(start + root.parts.length),
        );
      }
    }
    return null;
  }

  /// The area a *file* lies in, given its relative path.
  MediaAreaMatch? locateFile(String relativePath) {
    final parts = splitPath(relativePath);
    if (parts.isEmpty) return null;
    return locate(parts);
  }

  static List<String> splitPath(String value) => p.posix
      .split(p.posix.normalize(value.replaceAll('\\', '/')))
      .where((part) => part.isNotEmpty && part != '.')
      .toList(growable: false);
}
