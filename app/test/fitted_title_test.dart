import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/features/library/work_spotlight.dart';

/// Ein Titel wird kleiner, bevor er gekürzt wird.
///
/// „I Became an S-Rank Hunter …" sagt nichts; derselbe Name in zwei Dritteln
/// der Größe sagt alles.
void main() {
  const style = TextStyle(height: 1.1);

  double sizeFor(String title, {double width = 320, double size = 40}) =>
      fittedTitleSize(
        title: title,
        style: style,
        size: size,
        maxWidth: width,
        direction: TextDirection.ltr,
      );

  test('ein kurzer Titel behält die volle Größe', () {
    expect(sizeFor('Dune'), 40);
  });

  test('ein langer Titel wird kleiner', () {
    expect(
      sizeFor('I Became an S-Rank Hunter with a One-Star Recommendation'),
      lessThan(40),
    );
  });

  test('unter 55 Prozent hört das Schrumpfen auf', () {
    // Sonst wird aus einer Überschrift Kleingedrucktes.
    expect(sizeFor('Wort ' * 200), greaterThanOrEqualTo(40 * 0.55));
  });

  test('ohne bekannte Breite bleibt es bei der Wunschgröße', () {
    expect(sizeFor('Irgendwas', width: double.infinity), 40);
  });
}
