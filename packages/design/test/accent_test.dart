import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus_design/fundus_design.dart';

/// Eine andere Farbe, dieselbe Lesbarkeit.
///
/// Eine Rampe sind nicht neun beliebige Farben, sondern ein Ton in neun
/// sorgfältig gewählten Helligkeiten — und diese Kurve ist es, die Schrift
/// darauf lesbar macht.
void main() {
  test('die Helligkeitskurve bleibt, der Ton wandert', () {
    const seed = Color(0xff4f7ddb);
    final shifted = FundusPalette.accent.shiftedTo(seed);

    for (final (original, moved) in [
      (FundusPalette.accent.s100, shifted.s100),
      (FundusPalette.accent.s500, shifted.s500),
      (FundusPalette.accent.s900, shifted.s900),
    ]) {
      expect(
        moved.computeLuminance(),
        closeTo(original.computeLuminance(), 0.12),
        reason: 'die Stufe darf ihre Helligkeit nicht verlieren',
      );
    }

    // Und der Ton ist der gewählte.
    expect(
      HSLColor.fromColor(shifted.s500).hue,
      closeTo(HSLColor.fromColor(seed).hue, 1),
    );
  });

  test('eine graue Wahl wird wirklich grau', () {
    final grey = FundusPalette.accent.shiftedTo(const Color(0xff808080));

    expect(HSLColor.fromColor(grey.s500).saturation, lessThan(0.1));
  });

  test('das Thema nimmt die Farbe an', () {
    const seed = Color(0xff2fa4a0);
    final tokens = FundusTokens.dark(accent: seed);

    expect(
      HSLColor.fromColor(tokens.accent).hue,
      closeTo(HSLColor.fromColor(seed).hue, 1),
    );
    // Ohne Wahl bleibt alles, wie es geliefert wurde.
    expect(FundusTokens.dark().accent, FundusPalette.darkAccent);
  });
}
