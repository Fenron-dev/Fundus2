import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/media_type.dart';

/// Welches Regal oben steht, entscheidet der Nutzer.
void main() {
  test('eine eigene Reihenfolge steht vorn', () {
    final order = MediaTypes.ordered(const ['music', 'movie']);

    expect(order.first.id, 'music');
    expect(order[1].id, 'movie');
  });

  test('was nicht genannt ist, behält seinen Platz hinten', () {
    final order = MediaTypes.ordered(const ['music']);

    expect(order.first.id, 'music');
    // Alle sind noch da, keiner doppelt.
    expect(order.length, MediaTypes.all.length);
    expect(order.map((type) => type.id).toSet().length, order.length);
    // Und der Rest steht in der eingebauten Reihenfolge.
    expect(order[1].id, MediaTypes.all.first.id);
  });

  test('eine Liste aus einer älteren Fassung kostet kein Regal', () {
    final order = MediaTypes.ordered(const ['gibt-es-nicht', 'movie']);

    expect(order.first.id, 'movie');
    expect(order.length, MediaTypes.all.length);
  });

  test('ohne eigene Reihenfolge bleibt es beim Eingebauten', () {
    expect(
      MediaTypes.ordered(const []).map((type) => type.id),
      MediaTypes.all.map((type) => type.id),
    );
  });
}
