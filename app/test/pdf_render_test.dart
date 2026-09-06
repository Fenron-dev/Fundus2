import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/pdf_source.dart';

/// Womit eine PDF-Seite gezeichnet wird.
///
/// Aus dem Betrieb: die Seite stand winzig in der linken oberen Ecke, der
/// Rest war weiß. Der Grund war ein Ausschnitt ohne Seite: pdfium nimmt ohne
/// die vollen Maße die Punktgröße der Seite und schneidet daraus die
/// angefragte Fläche heraus.
void main() {
  test('gezeichnet wird die ganze Seite, nicht ein Ausschnitt', () {
    final box = pdfRenderBox(612, 792, 1600);

    expect(box.width, 1600);
    expect(box.fullWidth, box.width.toDouble());
    expect(box.fullHeight, box.height.toDouble());
  });

  test('die Seite behält ihr Verhältnis', () {
    final box = pdfRenderBox(612, 792, 1600);

    expect(box.height / box.width, closeTo(792 / 612, 0.01));
  });

  test('eine quere Seite wird breiter als hoch', () {
    final box = pdfRenderBox(842, 595, 1600);

    expect(box.height, lessThan(box.width));
  });

  test('unsinnige Maße geben trotzdem etwas Zeichenbares', () {
    final box = pdfRenderBox(0, 0, 0);

    expect(box.width, greaterThan(0));
    expect(box.height, greaterThan(0));
  });
}
