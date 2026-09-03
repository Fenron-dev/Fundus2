import 'package:flutter/widgets.dart';
import 'package:fundus_design/fundus_design.dart';

/// The settings areas, in the order the design puts them.
///
/// One list, read by both the navigation column and the overview a phone
/// shows. Two lists would drift, and the way that drift shows is an area
/// nothing can reach.
@immutable
final class SettingsArea {
  const SettingsArea({
    required this.key,
    required this.label,
    required this.icon,
    required this.description,
  });

  final String key;
  final String label;
  final IconData icon;

  /// One line saying what is decided here. The overview shows it; the
  /// column has no room for it.
  final String description;
}

abstract final class SettingsAreas {
  static List<SettingsArea> get all => [
    SettingsArea(
      key: 'darstellung',
      label: 'Darstellung',
      icon: FundusIcons.viewGrid,
      description: 'Thema und Dichte.',
    ),
    SettingsArea(
      key: 'wiedergabe',
      label: 'Wiedergabe',
      icon: FundusIcons.play,
      description: 'Geschwindigkeit, Sprungweiten, Sleep-Timer.',
    ),
    SettingsArea(
      key: 'reader',
      label: 'Reader',
      icon: FundusIcons.book,
      description: 'Leserichtung, Doppelseiten, Schriftgröße.',
    ),
    SettingsArea(
      key: 'bibliotheken',
      label: 'Bibliotheken',
      icon: FundusIcons.vault,
      description: 'Ordner, Medienarten und was noch nicht zugeordnet ist.',
    ),
    SettingsArea(
      key: 'suche',
      label: 'Suche & Filter',
      icon: FundusIcons.search,
      description: 'Gespeicherte Ansichten und Suchbereich.',
    ),
    SettingsArea(
      key: 'synchronisation',
      label: 'Geräte & Abgleich',
      icon: FundusIcons.devices,
      description: 'Dieses Gerät, die Freigabe und gekoppelte Geräte.',
    ),
    SettingsArea(
      key: 'wartung',
      label: 'Serverwartung',
      icon: FundusIcons.folder,
      description: 'Speicher, Scan-Zeitplan und Wartungsaufgaben.',
    ),
    SettingsArea(
      key: 'schutz',
      label: 'Schutzmodus',
      icon: FundusIcons.protected,
      description: 'PIN, unscharfe Vorschau und Ausblenden.',
    ),
    SettingsArea(
      key: 'diagnose',
      label: 'Diagnose & Logging',
      icon: FundusIcons.warning,
      description: 'Protokolle, Zustand und was zuletzt schiefging.',
    ),
  ];

  static SettingsArea? byKey(String? key) {
    for (final area in all) {
      if (area.key == key) return area;
    }
    return null;
  }
}
