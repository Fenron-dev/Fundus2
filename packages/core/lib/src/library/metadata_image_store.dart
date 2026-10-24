import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../model/fundus_id.dart';
import '../model/metadata_image.dart';

/// Only immutable managed copies are written or collected; source images are
/// read-only. The owning library serializes image operations and collection.
final class MetadataImageStore {
  MetadataImageStore(this.root);
  final Directory root;
  static final _stalePartName = RegExp(
    r'^[a-f0-9]{64}\.(cover|backdrop)\.(jpg|png|webp|gif|bmp)\.[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.part$',
  );

  Future<Directory?> _directory({bool create = false}) async {
    final realRoot = await root.resolveSymbolicLinks();
    var directory = root;
    var relative = '';
    for (final component in MetadataImageVersion.directory.split('/')) {
      relative = p.join(relative, component);
      directory = Directory(p.join(directory.path, component));
      var type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        if (!create) return null;
        await directory.create();
        type = await FileSystemEntity.type(directory.path, followLinks: false);
      }
      if (type != FileSystemEntityType.directory ||
          !p.equals(
            await directory.resolveSymbolicLinks(),
            p.join(realRoot, relative),
          )) {
        throw const FileSystemException(
          'Bildversionsordner ist kein verwalteter Vault-Ordner.',
        );
      }
    }
    return directory;
  }

  Future<Uint8List> readVaultImage(String relative) async {
    if (relative.contains('\\') ||
        p.posix.isAbsolute(relative) ||
        relative
            .split('/')
            .any((part) => part.isEmpty || part == '..' || part == '.')) {
      throw const FormatException('Bildpfad verlässt den Vault.');
    }
    final file = File(p.joinAll([root.path, ...p.posix.split(relative)]));
    final realRoot = await root.resolveSymbolicLinks();
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.isWithin(realRoot, await file.resolveSymbolicLinks())) {
      throw const FileSystemException(
        'Bild ist keine reguläre Datei im Vault.',
      );
    }
    final before = await file.stat();
    if (before.size < 1 || before.size > MetadataImageVersion.maxBytes) {
      throw const FormatException('Bild ist leer oder größer als 32 MiB.');
    }
    final result = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (result.length + chunk.length > MetadataImageVersion.maxBytes) {
        throw const FormatException('Bild überschreitet das Versionslimit.');
      }
      result.add(chunk);
    }
    final after = await file.stat();
    if (before.size != after.size ||
        before.modified != after.modified ||
        result.length != before.size ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.isWithin(realRoot, await file.resolveSymbolicLinks())) {
      throw const FileSystemException(
        'Bild wurde während des Lesens verändert.',
      );
    }
    return result.takeBytes();
  }

  Future<MetadataImageVersion> store(
    Uint8List bytes, {
    required String role,
    String extension = 'jpg',
  }) async {
    if (!const ['cover', 'backdrop'].contains(role) ||
        bytes.isEmpty ||
        bytes.length > MetadataImageVersion.maxBytes) {
      throw const FormatException(
        'Ungültiges Bild oder Bildversionslimit überschritten.',
      );
    }
    final normalized = extension.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    final suffix = const ['png', 'webp', 'gif', 'bmp'].contains(normalized)
        ? normalized
        : 'jpg';
    final hash = sha256.convert(bytes).toString();
    final version = MetadataImageVersion(
      path: '${MetadataImageVersion.directory}/$hash.$role.$suffix',
      digest: hash,
      bytes: bytes.length,
    )..validate();
    final directory = (await _directory(create: true))!;
    final target = File(p.join(directory.path, p.posix.basename(version.path)));
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      await verify(version);
      return version;
    }
    final part = File('${target.path}.${FundusId.generate()}.part');
    try {
      await part.writeAsBytes(bytes, flush: true);
      await _directory();
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await verify(version);
      } else {
        await part.rename(target.path);
      }
    } finally {
      if (await part.exists()) await part.delete();
    }
    return version;
  }

  Future<MetadataImageVersion> snapshot(
    String relative, {
    required String role,
  }) async => store(
    await readVaultImage(relative),
    role: role,
    extension: p.posix.extension(relative),
  );

  Future<Uint8List> verify(MetadataImageVersion version) async {
    version.validate();
    if (await _directory() == null) {
      throw const FileSystemException('Bildversion ist nicht mehr verfügbar.');
    }
    final bytes = await readVaultImage(version.path);
    if (bytes.length != version.bytes ||
        sha256.convert(bytes).toString() != version.digest) {
      throw const FormatException(
        'Bildversion wurde verändert oder beschädigt.',
      );
    }
    return bytes;
  }

  Future<({int files, int bytes})> collect(Set<String> referenced) async {
    final directory = await _directory();
    if (directory == null) return (files: 0, bytes: 0);
    var files = 0, bytes = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final match = MetadataImageVersion.filenamePattern.firstMatch(name);
      final relative = '${MetadataImageVersion.directory}/$name';
      if (match == null && _stalePartName.hasMatch(name)) {
        final age = DateTime.now().difference(await entity.lastModified());
        if (age < const Duration(days: 1) ||
            await FileSystemEntity.type(entity.path, followLinks: false) !=
                FileSystemEntityType.file) {
          continue;
        }
        final size = await entity.length();
        if (size > MetadataImageVersion.maxBytes) continue;
        await entity.delete();
        files++;
        bytes += size;
        continue;
      }
      if (match == null || referenced.contains(relative)) continue;
      final size = await entity.length();
      if (size < 1 || size > MetadataImageVersion.maxBytes) continue;
      try {
        await verify(
          MetadataImageVersion(
            path: relative,
            digest: match.group(1)!,
            bytes: size,
          ),
        );
        await _directory();
        if (await FileSystemEntity.type(entity.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        await entity.delete();
        files++;
        bytes += size;
      } on FileSystemException {
        // Unverified, linked or changed files are not collection authority.
      } on FormatException {
        // Keep unrelated or corrupted data for explicit diagnosis.
      }
    }
    return (files: files, bytes: bytes);
  }
}
