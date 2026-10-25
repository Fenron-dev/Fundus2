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
  weiter. Audiofokus-Pause hält das aktuelle Segment zum späteren Fortsetzen;
  ein Stopp (auch vom Sperrbildschirm) gilt nicht als Synthesefehler und darf
  keine andere, inzwischen gestartete Wiedergabe schließen. Ein Wechsel zu
  einem anderen Werk stoppt das Vorlesen ohne den Lesestand zurückzusetzen.
- Der Textreader checkpointet normales Lesen spätestens alle 15 Sekunden und
  zusätzlich beim Weglegen oder Schließen. Jeder vollständig gehörte
  TTS-Abschnitt wird sofort im lokalen Fortschrittsdatensatz gespeichert;
  portable und Peer-Checkpoints folgen höchstens alle 15 Sekunden und bei
  Pause/Stop sofort. Beim Wiederöffnen stellt die Ansicht auch den Offset innerhalb
  des Absatzes wieder her, nicht nur den Absatzanfang. Lesen und Hören teilen
  damit Datei, Kapitel, Absatzanker und Text-Offset; ein pausierter Satz wird
  beim Fortsetzen nötigenfalls ab Satzanfang wiederholt, aber nie übersprungen.
- Während Phonon den nächsten begrenzten Textabschnitt im Worker vorbereitet,
  bleibt die Android-Mediasitzung aktiv. Sie hält Audiofokus, Mediensteuerung
  und den von audio_service verwalteten Vordergrunddienst/Wake-Lock auch in
  den kurzen Synthesepausen. Sperrbildschirm-Steuerung kann TTS pausieren und
  fortsetzen, einschließlich einer Pause zwischen zwei Sätzen.
- Der gemeinsame Sleep-Timer ist im Textreader erreichbar. Für TTS bedeutet
  „Bis Kapitelende" das Ende des aktuellen Buchkapitels. Auf Android kann ein
  bewusstes Doppelschütteln den noch aktiven Timer um fünf Minuten verlängern;
  der Sensor wird nur bei aktivem Timer gelesen und lässt sich in den
  Wiedergabeeinstellungen ausschalten.
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
- Der Modellimport schreibt eine lokale SHA-256-Prüfliste neben die
  importierten Dateien und prüft sie vor dem Laden der nativen Engine. Damit
  werden beschädigte oder nachträglich veränderte Dateien erkannt; die Liste
  ist kein Signaturnachweis und kann die Herkunft eines frei gewählten Archivs
  nicht bestätigen. Ältere Importe erhalten beim ersten Laden einmalig eine
  solche lokale Ausgangsprüfung. Danach gilt die erfolgreiche Prüfung für
  diese Modellmappe bis zum Ende der laufenden App-Sitzung, damit ein
  Sprachwechsel nicht jedes Mal sämtliche Gewichte erneut hasht.
- Die Modellwahl weist auf die unterschiedlichen Lizenzen hin: laut dem
  bereitgestellten Phonon-Projekt ist `phonon-31m-en` Apache-2.0, während die
  `phonon-40m`-Modelle einschließlich Englisch CC BY-NC 4.0 sind. Fundus
  verteilt keine Modellgewichte; Modelle und Prüflisten bleiben lokal.
- Im Reader lassen sich die Vorlesesprache sowie die im installierten Modell
  verfügbaren Sprachen und Stimmen ansehen. Die Auswahl wird lokal je Werk
  gespeichert; eine Stimme wird zusätzlich nach Sprache getrennt gemerkt.
  Für Novels ist Englisch vorausgewählt, explizite Sprachmetadaten oder eine
  gespeicherte Auswahl gehen weiterhin vor. Die Stimmenliste stammt aus der
  installierten Phonon-Engine, nicht aus einer fest codierten Fundus-Liste.
  Die Einstellungen zeigen die wirksame Sprache und Stimme. Eine lokalisierte
  Hörprobe verwendet genau diese Auswahl, ohne den Buchstand fortzuschreiben.
- Das Vorlesetempo ist lokal pro Werk einstellbar. Es wird nur für die
  jeweilige TTS-Wiedergabe vorübergehend auf dem gemeinsamen Player gesetzt
  und danach zurückgestellt; Tempo-Habits von Musik und Hörbüchern werden nicht
  verändert.
- Eine lokale, werkbezogene Ausspracheliste lässt einzelne Begriffe
  (einschließlich englischer Namen) für die Stimme ersetzen. Der Abgleich ist
  wortgenau und Unicode-fähig; längere Einträge haben Vorrang. Nur der an die
  Engine gesendete Sprechtext ändert sich, niemals der gespeicherte Roman oder
  seine Positionsanker. Die Liste bleibt installationslokal.
- GitHub-Builds sind für die gepinnte Phonon-C-FFI-Revision vorbereitet:
  Android ARM64/x86_64, Windows x64 und macOS. Modellgewichte bleiben davon
  getrennt und werden nicht in Fundus-Builds oder das öffentliche Repository
  aufgenommen.
- Der Server bietet unter den authentifizierten `/v1/tts/`-Routen ein CPU-Modell
  mit relativen Dateinamen, Größen und SHA-256-Prüfsummen an. Native Bibliotheken,
  andere Ordner und beliebige Dateien werden nicht übertragen. Q8 hat Vorrang
  vor den unkomprimierten Gewichten, damit nicht beide Varianten geladen werden.
  Modellprüfung und Hash-Berechnung laufen außerhalb des UI-/Server-Isolates.
- Android holt ein fehlendes Modell beim Verbinden von einem gekoppelten Server.
  Es nutzt dessen bestehendes Zugangstoken und Zertifikat-Pinning, streamt die
  Dateien mit Größen- und Prüfsummenkontrolle und aktiviert erst den vollständig
  geprüften Download. Fehlversuche werden nicht mit jedem Herzschlag wiederholt;
  im Reader und unter Geräte & Abgleich kann man den Bezug erneut starten.
  Vorhandene lokale Modelle werden weiterverwendet, auch ohne Serverkontakt.
- Der erste Klick auf Vorlesen erklärt die noch erforderliche Modelleinrichtung,
  bevor ein Dateiauswahldialog erscheint. Windows prüft den gewählten CPU-Ordner
  auf Konfiguration, Tokenizer, Gewichte und Stimme. Am Server kann ein separates
  CPU-Modell gewählt werden, damit ein Mac weiterhin sein Core-ML-Modell für die
  eigene Wiedergabe nutzen und Android gleichzeitig CPU-Daten liefern kann.

## Einrichtung für Windows, Server und Android

Die GitHub-App-Pakete enthalten die native Sprachengine (`ptts_ffi.dll` unter
Windows, `libptts_ffi.so` unter Android). **Sprachmodelle und Stimmen sind separate
Daten.** Der Öffnen-Dialog im bisherigen Windows-Build bedeutet, dass noch kein
Modellordner gewählt wurde; er fragt nicht nach einer Novel oder einer Engine.

Für englische Novels ist der vorhandene Phonon-Ordner `models/phonon-31m-en`
geeignet. Man kann ihn direkt auswählen oder vollständig z. B. nach
`C:\Fundus-TTS\phonon-31m-en` kopieren und diesen Ordner auswählen. Für CPU sind
mindestens diese Dateien erforderlich:

```text
phonon-31m-en/
  config.json
  tokenizer.json
  model.q8.gguf              (alternativ model.safetensors)
  default-voice.safetensors  (alternativ passende Stimmen in voices/)
```

Weitere Modelldateien und Lizenzhinweise aus dem Phonon-Ordner können erhalten
bleiben. Zusätzliche Stimmen kommen in dessen `voices/`-Unterordner. Eine
Phonon-Python-Umgebung muss nicht kopiert oder gestartet werden. Die bevorzugten
Dateinamen sind gegen die [fest gepinnte native CPU-Implementierung](https://github.com/gradium-ai/xn-ptts/blob/49b9033e44ab0fbb935973eca3213757644d1bbb/ptts-ffi/src/cpu.rs)
geprüft.

Am Desktop-Server unter **Einstellungen → Geräte & Abgleich → Vorlesemodell für
gekoppelte Geräte → CPU-Modellordner wählen** denselben Ordner hinterlegen. Ohne
separate Auswahl verwendet der Server den lokalen Vorlese-Modellordner. Die
Auswahl gilt sofort, auch bei laufendem Server. Bei macOS muss für Android ein
CPU-Modell hinterlegt werden; ein exportiertes Core-ML-Bundle ist nicht portabel
auf Windows/Android.

Android verbindet sich wie bisher mit dem Server und lädt das angebotene Modell,
wenn noch keines lokal eingerichtet ist. Der Fortschritt ist unter Geräte &
Abgleich sowie in den Reader-Einstellungen sichtbar. Falls zuvor noch kein
Modell am Server eingerichtet war, dort **Vorlesemodell vom Server laden**
antippen. Ein manuelles ZIP bleibt als Alternative vorhanden. Es wird kein
HuggingFace-Zugang auf dem Handy benötigt. Beide Geräte benötigen den Build mit
Modelltransfer; ein älterer Server liefert ein erklärtes leeres Angebot.

## Präzision und derzeitige Grenzen

Die Engine erzeugt kurze Sprachsegmente. Während ein Abschnitt abgespielt wird,
bereitet der Worker höchstens einen Folgeabschnitt vor, um Pausen zu verkürzen;
bei langsamer Synthese kann es weiterhin eine hörbare Lücke geben. Es gibt
keine Wort-für-Wort-Zeitmarken. Nur vollständig abgespielte Segmente schreiben
den Textstand fort; beim Stoppen mitten in einem Satz kann dieser beim Fortsetzen
erneut beginnen. Dies schützt vor dem Überspringen noch nicht gehörter Wörter.

Eine funktionierende Übersetzung der nativen Bibliothek im GitHub-Build und
grüne Steuerungs-/Protokolltests belegen noch keine Sprachqualität,
Echtzeitfähigkeit oder Akkulaufzeit auf dem S21 FE. Dafür bleiben die echten
Windows-/Android-Abspieltests ausdrücklich erforderlich. Vollständige
Hörbuch-/m4b-Exporte sind kein Teil der Reader-TTS-Umsetzung.

**Noch offen:** eine vertrauenswürdige Herkunfts-/Signaturprüfung für
Modellarchive (lokale SHA-256-Prüflisten erkennen nur spätere Veränderungen),
Phonons sprachweite Wörterbücher und optionale Textregeln, vorausschauender
Audio-Puffer, Sperrbildschirm- und
Unterbrechungstests sowie Laufzeit- und Akku-Abnahme auf echtem Android
(insbesondere S21 FE). Ein erfolgreicher GitHub-Build ersetzt keinen
Gerätetest. Android-Hersteller können Hintergrunddienste zusätzlich durch
eigene Akkuverwaltung einschränken; auf dem S21 FE muss die gesperrte
Wiedergabe daher praktisch abgenommen werden. Schütteln setzt verfügbare
Bewegungssensorwerte voraus.

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

Als nächste Schritte bleiben: eine vertrauenswürdige Signatur bzw. ein
Prüfnachweis für die Herkunft von Modellarchiven, optionale sprachweite
Phonon-Wörterbücher/Textregeln und die Abnahme auf echten Geräten. Dabei sind
Laufzeit, Speicher, Akkuverbrauch, Audiofokus im Hintergrund, Timer-Ende am
Buchkapitel und Schütteln im gesperrten Zustand zu messen. Der bereits
vorhandene `audio_service`-/`audio_session`-Pfad darf nicht mit einer zweiten,
gleichzeitig spielenden Fundus-Audiositzung konkurrieren.
