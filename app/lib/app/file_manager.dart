import 'dart:io';

import 'package:path/path.dart' as p;

/// Whether this platform has a file manager Fundus can hand a folder to.
bool get canRevealInFileManager =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Opens [path] in the system file manager.
///
/// The path goes in as a single argument, never through a shell, and only an
/// absolute one: a folder name must not be able to read as a command or an
/// option. Returns whether a file manager could be started.
Future<bool> revealInFileManager(String path) async {
  final command = Platform.isMacOS
      ? 'open'
      : Platform.isWindows
      ? 'explorer'
      : Platform.isLinux
      ? 'xdg-open'
      : null;
  if (command == null || path.isEmpty || !p.isAbsolute(path)) return false;
  try {
    await Process.run(command, [path]);
    return true;
  } on Object {
    return false;
  }
}
