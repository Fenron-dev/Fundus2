import 'package:path/path.dart' as p;

import 'abs_metadata.dart';
import 'media_areas.dart';
import '../scan/library_scanner.dart';

enum WorkMetadataSource { filename, embedded, abs, sidecar, online, user }

final class AbsBookIdentity {
  const AbsBookIdentity({
    required this.author,
    required this.title,
    this.series,
    this.sequence,
  });

  final String author;
  final String title;
  final String? series;
  final double? sequence;
}

final class AudiobookImportCandidate {
  const AudiobookImportCandidate({
    required this.identity,
    required this.directory,
    required this.audioFiles,
    required this.coverFiles,
    this.kind = 'audiobook',
    this.usesFallbackIdentity = false,
    this.absMetadata,
    this.metadataSource = WorkMetadataSource.filename,
  });

  /// The `works.kind` this candidate becomes — `audiobook`, `album` or
  /// `podcast`, decided by the media folder it lies under.
  final String kind;

  final AbsBookIdentity identity;
  final String directory;
  final List<ScannedFile> audioFiles;
  final List<ScannedFile> coverFiles;
  final bool usesFallbackIdentity;
  final AbsAudiobookMetadata? absMetadata;
  final WorkMetadataSource metadataSource;

  AudiobookImportCandidate copyWith({
    AbsBookIdentity? identity,
    AbsAudiobookMetadata? absMetadata,
    WorkMetadataSource? metadataSource,
  }) => AudiobookImportCandidate(
    identity: identity ?? this.identity,
    directory: directory,
    audioFiles: audioFiles,
    coverFiles: coverFiles,
    kind: kind,
    usesFallbackIdentity: usesFallbackIdentity,
    absMetadata: absMetadata ?? this.absMetadata,
    metadataSource: metadataSource ?? this.metadataSource,
  );
}

final class AbsImporter {
  static const audioExtensions = {
    'm4b',
    'm4a',
    'mp3',
    'flac',
    'ogg',
    'opus',
    'wav',
  };
  static const coverNames = {
    'cover.jpg',
    'cover.jpeg',
    'cover.png',
    'cover.webp',
    'folder.jpg',
    'folder.jpeg',
    'folder.png',
    'folder.webp',
  };

  AbsImporter({
    this.mediaRootNames = const ['Audiobooks', 'Hörbücher'],
    MediaAreaMap? areas,
  }) : _areas = areas ?? MediaAreaMap({'audiobook': mediaRootNames});

  /// The work kind each audio-carrying media area produces.
  ///
  /// Audio is not automatically an audiobook. Everything with a sound file in
  /// it used to become one, which is how an album under `Musik` and a feed
  /// under `Podcasts` ended up on the Hörbücher shelf — with the folder they
  /// came from showing as their series, which is exactly the evidence that
  /// the folder was read and then ignored.
  static const audioAreaKinds = {
    'audiobook': 'audiobook',
    'music': 'album',
    'podcast': 'podcast',
  };

  final List<String> mediaRootNames;
  final MediaAreaMap _areas;

  AbsBookIdentity? parseBookDirectory(String relativeDirectory) {
    final parts = MediaAreaMap.splitPath(relativeDirectory);
    final area = _areas.locate(parts);
    return _identity(area == null ? parts : area.remainder);
  }

  /// `Autor/Serie/02 - Titel` below the area folder, in any of its lengths.
  AbsBookIdentity? _identity(List<String> parts) {
    if (parts.length < 2) return null;
    final author = parts.first;
    final parsedTitle = _parseSequence(parts.last);
    if (parts.length == 2) {
      return AbsBookIdentity(
        author: author,
        title: parsedTitle.title,
        sequence: parsedTitle.sequence,
      );
    }
    return AbsBookIdentity(
      author: author,
      series: parts.sublist(1, parts.length - 1).join(' / '),
      title: parsedTitle.title,
      sequence: parsedTitle.sequence,
    );
  }

  List<AudiobookImportCandidate> group(Iterable<ScannedFile> files) {
    final byDirectory = <String, List<ScannedFile>>{};
    for (final file in files) {
      final directory = p.posix.dirname(file.relativePath);
      byDirectory.putIfAbsent(directory, () => []).add(file);
    }

    final candidates = <AudiobookImportCandidate>[];
    for (final entry in byDirectory.entries) {
      final audio =
          entry.value
              .where((file) => audioExtensions.contains(file.extension))
              .toList()
            ..sort(_compareTracks);
      if (audio.isEmpty) continue;
      final parts = MediaAreaMap.splitPath(entry.key);
      final area = _areas.locate(parts);
      // A sound file in a comic or film folder belongs to what that folder
      // holds; it is not a work of its own. Audio outside every declared area
      // stays an audiobook, which is what a library with loose files expects.
      final kind = area == null ? 'audiobook' : audioAreaKinds[area.kind];
      if (kind == null) continue;
      final parsedIdentity = _identity(area == null ? parts : area.remainder);
      final identity = parsedIdentity ?? _fallbackIdentity(entry.key, audio);
      final covers = entry.value
          .where((file) => coverNames.contains(file.filename.toLowerCase()))
          .toList(growable: false);
      candidates.add(
        AudiobookImportCandidate(
          identity: identity,
          directory: entry.key,
          audioFiles: audio,
          coverFiles: covers,
          kind: kind,
          usesFallbackIdentity: parsedIdentity == null,
        ),
      );
    }
    candidates.sort((a, b) {
      final author = a.identity.author.compareTo(b.identity.author);
      if (author != 0) return author;
      final series = (a.identity.series ?? '').compareTo(
        b.identity.series ?? '',
      );
      if (series != 0) return series;
      return (a.identity.sequence ?? double.infinity).compareTo(
        b.identity.sequence ?? double.infinity,
      );
    });
    return candidates;
  }

  AbsBookIdentity _fallbackIdentity(String directory, List<ScannedFile> audio) {
    final normalized = p.posix.normalize(directory);
    final directoryName = normalized == '.'
        ? ''
        : p.posix.basename(normalized).trim();
    final fileTitle = p.basenameWithoutExtension(audio.first.filename).trim();
    return AbsBookIdentity(
      author: 'Unbekannt',
      title: directoryName.isNotEmpty ? directoryName : fileTitle,
    );
  }

  ({double? sequence, String title}) _parseSequence(String folder) {
    final match = RegExp(
      r'^(\d+(?:[.,]\d+)?)\s*[-–—]\s*(.+)$',
    ).firstMatch(folder);
    if (match == null) return (sequence: null, title: folder.trim());
    return (
      sequence: double.tryParse(match.group(1)!.replaceAll(',', '.')),
      title: match.group(2)!.trim(),
    );
  }

  static int _compareTracks(ScannedFile left, ScannedFile right) {
    final leftNumber = _leadingNumber(left.filename);
    final rightNumber = _leadingNumber(right.filename);
    if (leftNumber != null &&
        rightNumber != null &&
        leftNumber != rightNumber) {
      return leftNumber.compareTo(rightNumber);
    }
    if (leftNumber != null && rightNumber == null) return -1;
    if (leftNumber == null && rightNumber != null) return 1;
    return left.filename.toLowerCase().compareTo(right.filename.toLowerCase());
  }

  static int? _leadingNumber(String filename) {
    final match = RegExp(r'^(\d+)').firstMatch(filename);
    return match == null ? null : int.parse(match.group(1)!);
  }
}
