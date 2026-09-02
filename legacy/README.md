# legacy

Der bisherige Flutter-Client aus `Fenron-dev/Fundus`, Stand 2026-09-02.

**Dieser Ordner ist Fundgrube, kein Import-Ziel.** Er ist kein
Workspace-Mitglied, wird nicht kompiliert und ist von der Analyse
ausgenommen (`analysis_options.yaml`).

Regel aus der Technik-Spezifikation: Dateien einzeln herbeiholen und dabei
lesen, nie ordnerweise kopieren — sonst kommt die alte Schichtung mit. Konkret
lohnt der Blick hierher bei:

| Thema | Datei |
|---|---|
| Comic-/Manga-Seitenquelle (Vorbild fuer `MediaByteSource`) | `app/lib/library/comic_page_source.dart` |
| Audio-Wiedergabe, Kapitel, Sleep-Timer | `app/lib/playback/fundus_player_controller.dart` |
| Native Medienbenachrichtigung | `app/lib/playback/fundus_system_media_session.dart` |
| Remote-Client, Pairing, Zertifikats-Pinning | `app/lib/server/fundus_remote_client.dart` |
| Offline-Downloads mit Manifest | `app/lib/server/fundus_offline_store.dart` |
| EPUB-/Reflow-Reader | `app/lib/library/reflow_text_reader.dart` |
| ZIP-Browser | `app/lib/library/zip_archive_browser.dart` |

`pubspec.yaml.reference` ist die alte Paketdefinition; sie heisst bewusst nicht
`pubspec.yaml`, damit kein Werkzeug den Ordner als Paket aufgreift.

Der Ordner verschwindet, sobald die neue App die entsprechenden Faehigkeiten
traegt.
