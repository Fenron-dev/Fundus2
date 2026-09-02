import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/media_type.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

LibraryWorkSummary summary({
  String kind = 'audiobook',
  String title = 'Der Schacht',
  String author = 'Karl May',
  String? series,
  double? seriesSequence,
  Duration? position,
  Duration? duration,
  MediaPosition? mediaProgress,
  bool finished = false,
  String availability = 'available',
}) => LibraryWorkSummary(
  id: 'w1',
  kind: kind,
  title: title,
  author: author,
  fileCount: 1,
  addedAt: DateTime(2026, 1, 1),
  series: series,
  seriesSequence: seriesSequence,
  progressPosition: position,
  progressDuration: duration,
  mediaProgress: mediaProgress,
  progressFinished: finished,
  availability: availability,
);

void main() {
  group('Fortschritt bedeutet je Medientyp etwas anderes', () {
    test('Hörbuch zählt in Sekunden und nennt die Restzeit', () {
      final work = WorkView.fromSummary(
        summary(
          position: const Duration(hours: 4),
          duration: const Duration(hours: 10),
        ),
      );

      expect(work.mediaType, MediaTypes.audiobook);
      expect(work.progressFraction, closeTo(0.4, 0.001));
      expect(work.progressLabel, 'noch 6 Std 00 Min');
    });

    test('Manga merkt sich die Seite im Band', () {
      final work = WorkView.fromSummary(
        summary(
          kind: 'manga',
          mediaProgress: const MediaPosition(
            kind: MediaPositionKind.page,
            numericValue: 108,
            total: 180,
          ),
        ),
      );

      expect(work.progressLabel, 'Seite 108 von 180');
      expect(work.progressFraction, closeTo(0.6, 0.001));
    });

    test('PDF nennt die Sprungmarke und rechnet sie nicht in Prozent um', () {
      final work = WorkView.fromSummary(
        summary(
          kind: 'document',
          mediaProgress: const MediaPosition(
            kind: MediaPositionKind.page,
            numericValue: 214,
            total: 480,
          ),
        ),
      );

      // Bei einem Nachschlagewerk zählt, wo man landet — nicht wie weit.
      expect(work.progressFraction, isNull);
      expect(work.progressLabel, 'zuletzt Seite 214');
    });

    test('EPUB rechnet im Anteil, nicht in Seiten', () {
      final work = WorkView.fromSummary(
        summary(
          kind: 'webnovel',
          mediaProgress: const MediaPosition(
            kind: MediaPositionKind.epubCfi,
            key: 'epubcfi(/6/14!/4/2/2)',
            label: 'Kapitel 44',
            scrollOffset: 0.18,
          ),
        ),
      );

      expect(work.progressFraction, closeTo(0.18, 0.001));
      expect(work.progressLabel, 'Kapitel 44 · 18 %');
    });

    test('Fotos tragen keinen Fortschritt', () {
      final work = WorkView.fromSummary(summary(kind: 'image'));

      expect(work.mediaType, MediaTypes.photos);
      expect(work.progressFraction, isNull);
      expect(work.progressLabel, isNull);
      expect(work.hasProgress, isFalse);
    });

    test('ein fertiges Werk sagt das, egal in welcher Einheit', () {
      final work = WorkView.fromSummary(summary(kind: 'manga', finished: true));

      expect(work.progressFraction, 1);
      expect(work.progressLabel, 'Fertig');
      expect(work.finished, isTrue);
    });
  });

  group('Herkunft', () {
    test('kommt aus der Zeile, nicht aus der Ansicht', () {
      expect(
        WorkView.fromSummary(summary(availability: 'remote')).origin,
        FundusOrigin.stream,
      );
      expect(
        WorkView.fromSummary(summary(availability: 'offline_copy')).origin,
        FundusOrigin.offline,
      );
      expect(
        WorkView.fromSummary(summary(availability: 'unreachable')).origin,
        FundusOrigin.unreachable,
      );
      expect(
        WorkView.fromSummary(summary(availability: 'in_archive')).origin,
        FundusOrigin.archive,
      );
    });

    test('offline gesichert und lokal sind ohne Netz spielbar', () {
      expect(FundusOrigin.offline.isPlayableOffline, isTrue);
      expect(FundusOrigin.local.isPlayableOffline, isTrue);
      expect(FundusOrigin.stream.isPlayableOffline, isFalse);
    });
  });

  test('ein unbekannter Grundtyp verschwindet nicht', () {
    final work = WorkView.fromSummary(summary(kind: 'steuerunterlagen'));

    expect(work.mediaType, isNull);
    expect(work.title, 'Der Schacht');
  });

  test('der Untertitel führt Reihe und Urheber zusammen', () {
    final work = WorkView.fromSummary(
      summary(series: 'Winnetou', seriesSequence: 2),
    );

    expect(work.subtitle, 'Winnetou 2 · Karl May');
    expect(work.initials, 'DS');
  });
}
