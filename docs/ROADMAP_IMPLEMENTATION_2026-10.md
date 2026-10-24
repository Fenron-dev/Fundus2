# Umsetzung der freigegebenen Erweiterungen

Auftrag vom 24.10.2026, [Roadmap #54](https://github.com/Fenron-dev/Fundus2/issues/54).
Dies ist ein Arbeitsstand, keine Erklärung, dass die gesamte Roadmap bereits
implementiert oder ausgeliefert ist. Die Stabilisierungsabnahme #47 bleibt separat.

## Umfang und Reihenfolge

1. Update-Posteingang und Abos (#56) – in Arbeit, Datei- und EPUB-Kapitel-Updates.
2. Intelligentes Offline-Mitnehmen (#55) – offen.
3. Metadatenverlauf und gezieltes Rückgängig (#57) – offen.
4. Medienwelten und Reihenfolgen (#60) – offen.
5. Regelregale und Dashboard-Zeilen (#58) – offen.
6. Bibliotheks-Check (#59) – offen.
7. Erklärbare lokale Empfehlungen (#63) – offen.
8. Inhaltssuche (#62) – offen.
9. Getrennte portable App/Server-Startprogramme und optionaler Dienst (#61) – offen.

Der normale Start darf nie einen Dienst/Autostart installieren. Dauerbetrieb
ist eine gesonderte, rechnergebundene Entscheidung in den Einstellungen;
die CLI bleibt optional. Externe Archivplatten werden durch Öffnen nicht in
die dauerhaft bereitgestellten Bibliotheken aufgenommen. App und Dienst
dürfen nicht unabhängig gleichzeitig denselben Vault schreibend öffnen.

## Update-Posteingang: erster Umsetzungsschritt

- Werkdetails bieten „Updates abonnieren“ auch für gespiegelte Werke. Eine
  bewusste Sammelaktion abonniert bereits begonnene sichtbare Werke.
- Das Abo speichert zunächst einen stillen Bestand. Erst spätere Änderungen
  werden als hinzugefügt, geändert oder nicht mehr verfügbar aufgezeichnet.
- Auswertung nach abgeschlossenem vorhandenem Scan bzw. Katalogimport;
  keine neuen Timer, Vollabzüge oder Medienabrufe im Scrollpfad.
- `Neues für dich` ist über Dashboard und Seitenleiste/Drawer erreichbar.
  Neue Hinweise, „Später“, gesehene/ausgeblendete Historie und Abos sind
  getrennte Ansichten. Die Liste ist virtualisiert; keine Popup-Kaskade.
- Statusentscheidungen sind unabhängig von Medienfortschritt und Ratings.
  Ein Hinweis kann wieder auf „neu“ gesetzt werden. Ein direkter Einstieg
  löst die Datei erneut auf, statt einer möglicherweise veralteten ID zu folgen.
- Die gemeinsame Öffnen-Funktion berücksichtigt explizit ausgewählte Dateien
  jetzt auch im Bild- und Textreader; bisher wurde `startAt` dort ignoriert.
- Der Controller filtert Hinweise und Zähler anhand sichtbarer Werke. Beim
  ersten Mounten des Scopes wird auch ein bereits geladener Katalog sofort
  durch die initiale Schutz-/Bibliotheksfreigabe gefiltert; zuvor geschah das
  erst beim nächsten Schutzwechsel.

### Ablage und Protokoll

`_fundus/content-updates.json`, Format 2, enthält Abos, Baselines, stabile
Ereigniskennungen und den Bearbeitungsstatus. Die bestehenden serialisierten
Sidecar-Schreibvorgänge und der Shutdown-Vertrag werden genutzt. Format 1 wird
gelesen und beim nächsten Speichern übernommen; der erste Kapitelbestand ist
eine stille Baseline. Alte Clients dürfen Format 2 nicht überschreiben.
Der Index migriert von Schema 23 nach 24: `files.publication_manifest_json`
ist ein abgeleiteter Cache, nicht der persönliche Fortschritt.
Wird nur der Index neu aufgebaut, bleibt die Baseline bestehen. Bei lokalen
Dateien ist der werkrelative Pfad maßgeblich, beim Peer dessen stabile Datei-ID.
Dateinamen/Revisionen sind private Vault-Daten, keine Diagnoseausgabe.

Unbekannte, beschädigte oder übergroße Posteingänge werden nicht als leer
interpretiert oder überschrieben. Die Medienbibliothek bleibt lesbar, die
neue Funktion zeigt einen Fehler und lässt das vorhandene Dokument unverändert.

Katalogdateien übertragen zusätzlich `size_bytes` und `content_revision`.
Die Revision beruht auf dem vorhandenen Dateistand im Index, nicht auf dem
jeweiligen Abrufzeitpunkt. Neue Clients akzeptieren ältere Kataloge ohne diese
Felder. Alte Clients können zusätzliche Felder ignorieren. Die Größe hilft
auch dem nachfolgenden Offline-Budget. Der Katalog selbst benötigt keinen
zusätzlichen Vollabruf von Mediendateien. Für abonnierte EPUBs wird lokal bei
einem neuen Dateistand einmalig der Kapitelbestand gelesen und gehasht.

### Kapitel innerhalb bestehender EPUBs

- Ein struktureller Bestand mit Reader-Kapitel-ID, Titel und Inhaltsrevision
  erkennt neue, geänderte und entfernte lesbare Kapitel getrennt. Nicht lesbare
  Navigationseinträge werden wie im bestehenden Textreader herausgefiltert.
- Entpacken und Hashen laufen außerhalb des UI-/Server-Isolates. Identische
  Anfragen teilen einen laufenden Auftrag; maximal 32 Aufträge werden seriell
  verarbeitet. Cachetreffer lösen kein erneutes Lesen der EPUB-Datei aus.
- Vorher-/Nachher-Prüfung von Dateigröße, Änderungszeit und Indexrevision
  verhindert die Speicherung eines Kapitelbestands unter falscher Revision.
- Der optionale Peer-Endpunkt `publication-manifest` transportiert nur IDs,
  Titel und Hashes, keinen Buchtext. Schutz, Geräte- und Bibliotheksfreigaben
  entsprechen dem Zugriff auf die Datei. Gespiegelte Quellen werden nicht
  erneut durch einen Host weitergereicht.
- Der Client begrenzt die gestreamte Metadatenantwort auf rund 4 MiB, auch
  wenn ein Server eine falsche oder keine Größenangabe sendet. Maximal 10.000
  Kapitel pro Datei; beschädigte/ungültige Bestände werden nicht übernommen.
- Vorübergehende Fehler halten die bisherige Baseline fest. Ein unveränderter
  Kataloglauf versucht fehlende Kapitelmetadaten erneut. Alte Server ohne
  diese Fähigkeit liefern weiterhin ehrliche Dateiänderungs-Hinweise.
- „Diesen Teil öffnen“ adressiert das genaue Kapitel. Ein inzwischen
  entfallener Band oder Kapitel zeigt einen Fehler statt unbemerkt Kapitel 1.
- Schließen/Checkpoint wartet auf bereits gestartete Kapitel- und
  Posteingangsvorgänge; ein unveränderter Scan schreibt den Posteingang nicht.
- Die letzten 500 bearbeiteten Hinweise bleiben erhalten. Ungelesene und
  auf später gesetzte Hinweise werden nicht automatisch entfernt. Der
  Posteingang ist auf 32 MiB begrenzt und weist einen Überlauf ausdrücklich ab.

Bestehende Medien, Positionen und Vault-Konfigurationen werden nicht ersetzt.
Vor Versionswechsel wie gewohnt sichern; einen einmal auf Schema 24/Format 2
aktualisierten Vault nicht mit alten Clients schreibend öffnen.

### Abnahme und noch offene Ergänzungen

Neue Tests decken stille Baseline, idempotente Änderungen, Wiederöffnen,
Index-Neuaufbau, Abo-Wechsel, spätere/ausgeblendete Hinweise und ungültige
Formatversionen ab. Ein echter Server-/Client-Test prüft neue und geänderte
Dateien über das Katalog-Delta. Widget-Tests prüfen Mobile, Desktop,
Initialschutz und Sperren einer geöffneten Ansicht; Reader-Tests den gezielten
Band-Einstieg. Lokaler Zwischenstand: Analyse ohne Befunde, Formatprüfung
sauber, Core 268, Server 44, Client 36, Design 3 und App 480 erfolgreiche Tests
(zusammen 831); acht App-Tests plattform-/zugangsdatenabhängig übersprungen.
GitHub-CI und Plattform-Builds bleiben getrennte Freigabeschritte.

Die Kapitel-Erweiterung ergänzt Tests für Schema 23→24, Format 1→2, neue,
geänderte und entfernte eingebettete Kapitel, Index-Neuaufbau, abgebrochene
Scans, unveränderte Sidecars, parallele Anfragen und Shutdown. Echte
Server-/Client-Tests prüfen Metadata-only-Transport, alte Server, Fehler und
Wiederholung bei unverändertem Katalog. Schutztests und direkte
Reader-/Oberflächen-Einstiege ergänzen die Abnahme. Lokaler Kapitel-Zwischenstand:
Analyse und Formatprüfung sauber; Core 278, Server 45, Client 41, Design 3,
App 484 bestanden, zusammen 851. Acht App-Tests bleiben plattform- oder
zugangsdatenabhängig übersprungen. Der vorherige Datei-Zwischenstand hat die
GitHub-CI bestanden (Run 40076351630); die Kapitel-Erweiterung benötigt noch
ihren eigenen CI-/Plattformlauf. Die Gesamt-Roadmap bleibt offen.
