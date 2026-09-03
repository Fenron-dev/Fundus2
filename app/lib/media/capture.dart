import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Saving a captured frame or page to a file the user picks.
///
/// Behind an interface for the same reason the fullscreen is: it opens a
/// system dialog, and a test must be able to watch that happen without one.
abstract interface class CaptureSink {
  /// Returns where the bytes went, or null when the dialog was dismissed.
  Future<String?> save(Uint8List bytes, {required String suggestedName});
}

final class FileCaptureSink implements CaptureSink {
  const FileCaptureSink();

  @override
  Future<String?> save(Uint8List bytes, {required String suggestedName}) async {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Bild speichern',
      fileName: suggestedName,
      type: FileType.image,
      // Android and iOS hand the bytes to the system dialog itself; on the
      // desktop only a path comes back and the writing is ours.
      bytes: Platform.isAndroid || Platform.isIOS ? bytes : null,
    );
    if (path == null) return null;
    if (!Platform.isAndroid && !Platform.isIOS) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return path;
  }
}
