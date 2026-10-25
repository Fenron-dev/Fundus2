# Phonon-TTS im Textreader – Arbeitsstand

Issue [#64](https://github.com/Fenron-dev/Fundus2/issues/64) ergänzt die
bereits freigegebene Roadmap, ersetzt oder schließt sie aber nicht. Diese Datei
trennt implementierte Grundlage von noch nicht ausgelieferter Sprachausgabe.

## Ziel und Fortschrittsvertrag

Ein Buch oder Novel hat **einen textuellen Medienstand**, gleichgültig ob der
letzte Abschnitt gelesen oder gehört wurde. Er enthält Datei, Kapitel,
Absatzanker und normalisierten Zeichen-Offset. Ein Audio-Zeitstempel wäre kein
dauerhafter Buchstand: Stimme, Tempo, Aussprache und Textregeln ändern seine
Zuordnung zum Text. Geräte behalten ihre eigenen Stände und bestehende
Konfliktentscheidungen; TTS darf keinen fremden Stand automatisch übernehmen.

Die Sprachausgabe wird in kurze Abschnitte mit Originaltext-Anfang und -Ende
aufgeteilt. Nur ein **vollständig vom Audio-Ausgabegerät abgespielter**
Abschnitt darf den Stand bis zu seinem Ende verschieben. Synthese,
Vorausladen und Audio-Queueing allein zählen nicht als gehört. Beim Pausieren,
Stoppen, Verlassen und Weglegen der App muss der letzte tatsächlich gehörte
Stand über den bestehenden Fortschritts-Checkpoint gesichert werden. Eine
veränderte Absatz-ID wird kenntlich gemacht; falsche Datei-/Kapitelanker oder
veraltete Segmente dürfen einen neueren Lesestand nicht überschreiben.

## Inzwischen implementiert

- `SpeechTextPlan` zerlegt den unveränderten Text eines Reader-Kapitels in
  begrenzte, satzorientierte Segmente. Jeder Abschnitt trägt Original-Offsets
  und Fundus-Medienpositionen. Der Einstieg aus einer Leseposition wiederholt
  höchstens den begonnenen Satz, statt ein Wort abzuschneiden.
- Der Textreader bietet den Plan für die aktuelle Stelle an. Er akzeptiert
  einen abgespielten Abschnitt nur aus dem weiterhin geöffneten Kapitel und
  nur wenn dessen Originaltext noch passt und dessen Ende vorwärts führt.
  Ein separater Checkpoint verwendet den bestehenden Lesestand/Journaleintrag.
- Die Sprachauflösung nutzt explizite Werkswahl vor Werks- und verlässlicher
  Dateimetadaten-Sprache, danach konfigurierbare Standards. Sie kennt Englisch,
  Deutsch, Französisch, Spanisch und Portugiesisch einschließlich üblicher
  Sprachcodes. Unbekannte Werte ergeben **keine** stillschweigende deutsche
  Stimme, sondern erfordern eine Wahl. Der Textreader reicht seine vorhandene
  Werks-Sprache an diese Auflösung weiter. Für Novels gilt Englisch als
  Medientyp-Standard vor der allgemeinen Gerätesprache; explizite Werk- oder
  Dateiangaben haben Vorrang. Reader-Tests prüfen beide Fälle.
- Core- und Reader-Tests prüfen Einstieg, Abkürzungen, lange Absätze,
  Unicode-Zeichengrenzen, geänderte Anker, falsche Kapitel,
  Synthese ohne Fortschrittsänderung,
  bestätigtes Abspielen, Wiederöffnen und veraltete Abschnitte.
- Ein erster nativer Worker bindet die offizielle Phonon-C-Schnittstelle über
  `dart:ffi` an. Modellladen und Synthese laufen seriell außerhalb der
  Flutter-Oberfläche. Für jeden Abschnitt prüft er Modellsprache und Stimme,
  begrenzt die erzeugten PCM-Daten und gibt ein 24-kHz-Mono-WAV zurück.
  Fehlendes Modell bzw. fehlende native Bibliothek liefern einen Fehler statt
  Cloud-Fallback oder stiller Sprachumstellung. WAV- und Fehlermodelltests
  sind hinzugefügt.
- Der Textreader hat eine Vorlesesteuerung. Sie nutzt den gemeinsamen
  Fundus-Player mit dessen Audiofokus; es gibt keine zweite Audiositzung.
  Abschnitte werden temporär als WAV geschrieben und nach der Wiedergabe
  entfernt. Erst nach natürlichem Audioende wandert der gemeinsame Lesestand
  weiter. Pause, Stopp, Fehler und App-Ende sichern den tatsächlich gehörten
  Stand; ein Wechsel zu einem anderen Werk stoppt das Vorlesen.
- Die Modellmappe wird nur lokal in `device.json` gespeichert. Novels ohne
  verlässliche Sprachangabe nutzen Englisch, während explizite Werk- oder
  Dateiangaben Vorrang behalten.
- Auf Android kann ein lokales ZIP-Modellarchiv in den privaten App-Speicher
  importiert werden. Der Import begrenzt Archivgröße, entpackte Größe und
  Dateizahl, verwirft unsichere Pfade/Symlinks und verlangt Modellgewichte,
  Tokenizer sowie eine Stimme. Es gibt keinen pauschalen Zugriff auf den
  gemeinsamen Gerätespeicher. Bei einer Deinstallation wird das App-private
  Modell entfernt und muss danach erneut importiert werden; bei einem normalen
  App-Update bleibt es erhalten.
- Im Reader lassen sich die Vorlesesprache sowie die im installierten Modell
  verfügbaren Sprachen und Stimmen ansehen. Die Auswahl wird lokal je Werk
  gespeichert; eine Stimme wird zusätzlich nach Sprache getrennt gemerkt.
  Für Novels ist Englisch vorausgewählt, explizite Sprachmetadaten oder eine
  gespeicherte Auswahl gehen weiterhin vor. Die Stimmenliste stammt aus der
  installierten Phonon-Engine, nicht aus einer fest codierten Fundus-Liste.
- GitHub-Builds sind für die gepinnte Phonon-C-FFI-Revision vorbereitet:
  Android ARM64/x86_64, Windows x64 und macOS. Modellgewichte bleiben davon
  getrennt und werden nicht in Fundus-Builds oder das öffentliche Repository
  aufgenommen.

**Noch offen:** Prüfsummen- und Lizenzprüfung für Modellarchive,
Hörprobe und sichtbare Anzeige der aktuell wirksamen Sprache/Stimme,
Phonons Aussprache-Wörterbücher und Textregeln, Sperrbildschirm-/Unterbrechungstests sowie Laufzeit- und
Akku-Abnahme auf echtem Android (insbesondere S21 FE). Die neuen nativen
GitHub-Buildschritte sind konfiguriert, müssen nach dem Push aber erst noch
remote erfolgreich laufen; ein erfolgreicher CI-Build ersetzt keinen
Gerätetest.

## Engine- und Datenschutzentscheidung für die nächsten Schritte

### Sprachen und Stimmen

Englisch ist ein **gleichrangiger Hauptanwendungsfall**, weil viele Novels in
der Bibliothek englischsprachig sind. Fundus darf sie nicht mit einem deutschen
Modell oder deutscher Textnormalisierung vorlesen. Die Auswahl ist je Werk
überschreibbar; ohne manuelle Wahl gilt in dieser Reihenfolge: explizite
Werks-Sprache, verlässliche Sprachangabe der Datei, konfigurierbarer Standard
des Medientyps (für Novels beispielsweise Englisch), allgemeiner Standard.
Eine bloße Vermutung aus Titel oder Dateiname darf nicht stillschweigend die
Werks-Sprache überschreiben. Der Reader zeigt die wirksame Sprache und Stimme
an und erlaubt eine Hörprobe. Stimmen und Aussprache-Wörterbücher sind nach
Sprache getrennt; ein Sprachwechsel ändert keine Textanker oder Lesestände.

Phonon bietet im vorhandenen Studio `phonon-40m-en` sowie das kleinere
`phonon-31m-en` als englische Modelloptionen. Qualität, Größe, Lizenz und
Laufzeit auf Desktop und S21 FE werden separat geprüft; die Modellwahl darf
nicht auf Deutsch festgelegt sein. Fundus baut die
[fest gepinnte Phonon-C-FFI-Schnittstelle](https://github.com/gradium-ai/xn-ptts/tree/49b9033e44ab0fbb935973eca3213757644d1bbb/ptts-ffi)
ein, aber das ersetzt keine Flutter-Laufzeitabnahme.

Das eigenständige Phonon-Studio nutzt Python/`ptts`, Kapitel-WAV und m4b-Export.
Für Fundus ist ein Python-Server im Client weder für Android geeignet noch für
eine schnelle Reader-Umschaltung nötig. Stattdessen erzeugt die native
`ptts-ffi`-Schnittstelle begrenzte Textabschnitte auf einem Worker. Die
Sprachabschnitte laufen als temporäre WAVs durch den gemeinsamen Fundus-Player.
Android enthält eine ARM64-CPU-Bibliothek; das optionale
Snapdragon-NPU-Paket ist kein allgemeiner Ersatz. Die aktuelle Android-Anleitung
des Herstellers bezeichnet das direkte Flutter-FFI-Binding noch als ungetestet;
ein GitHub-Build ist daher keine Geräteabnahme.

Sprachmodelle werden nicht in das öffentliche Git-Repository gelegt und nicht
ohne Nutzerwahl installiert. Das gewählte Modellverzeichnis wird nur je
Installation referenziert; Modell, Stimme und Audio-Cache bleiben gerätelokal;
der Buchtext wird nicht an einen Cloud-TTS-Dienst gesendet. Der Cache ist
begrenzt und wird ohne Löschen von Originalmedien bereinigt. Die 40m-Modelle
haben eine nichtkommerzielle Lizenz; Weitergabe, Attribution und
Download-Herkunft müssen vor einem Release gesondert geklärt werden.

Die nächste Implementierungsfolge ist: Modellimport mit Integritätsprüfung,
Sprach-/Stimmenwahl, Aussprache/Textregeln und Akku-/Laufzeittest auf echtem
Android-Gerät. Der bereits vorhandene
`audio_service`-/`audio_session`-Pfad darf nicht mit einer zweiten,
gleichzeitig spielenden Fundus-Audiositzung konkurrieren.
