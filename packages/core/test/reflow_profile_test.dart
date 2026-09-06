import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Womit im Text die Leiste erscheint, gehört zum Profil — es überlebt das
/// Schließen des Buchs wie die Schriftgröße auch.
void main() {
  test('zwei Finger sind die Voreinstellung', () {
    expect(
      const ReflowReaderProfile().menuGesture,
      ReaderMenuGesture.twoFingers,
    );
  });

  test('die Geste übersteht die Reise durch JSON', () {
    const profile = ReflowReaderProfile(menuGesture: ReaderMenuGesture.tap);

    final again = ReflowReaderProfile.fromJson(profile.toJson());

    expect(again.menuGesture, ReaderMenuGesture.tap);
  });

  test('ein Profil ohne die Angabe bekommt die Voreinstellung', () {
    final json = const ReflowReaderProfile().toJson()..remove('menu_gesture');

    expect(
      ReflowReaderProfile.fromJson(json).menuGesture,
      ReaderMenuGesture.twoFingers,
    );
  });
}
