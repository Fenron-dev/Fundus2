# Umsetzung der freigegebenen Erweiterungen

Auftrag vom 24.10.2026, [Roadmap #54](https://github.com/Fenron-dev/Fundus2/issues/54).
Dies ist ein Arbeitsstand, keine Erklärung, dass die gesamte Roadmap bereits
implementiert oder ausgeliefert ist. Die Stabilisierungsabnahme #47 bleibt separat.

## Umfang und Reihenfolge

1. Update-Posteingang und Abos (#56) – in Arbeit, erste dateibasierte Umsetzung.
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

`_fundus/content-updates.json`, Format 1, enthält Abos, Baselines, stabile
Ereigniskennungen und den Bearbeitungsstatus. Die bestehenden serialisierten
Sidecar-Schreibvorgänge und der Shutdown-Vertrag werden genutzt. Der Index
bleibt Schema 23; keine Datenbankmigration ist für diese Datei erforderlich.
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
auch dem nachfolgenden Offline-Budget; es werden keine Medien gehasht oder
komplett übertragen, nur um einen Update-Hinweis zu erzeugen.

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

Noch nicht abgeschlossen: neue Kapitel **innerhalb einer bereits vorhandenen
EPUB-Datei** einzeln erkennen, zählen und direkt adressieren. Solche Änderungen
erscheinen derzeit ehrlich als „Datei geändert“, nicht als erfundene Kapitelzahl.
Hierfür muss ein wiederverwendbarer Kapitelbestand samt Peer-Transport ergänzt
werden. Ebenso sind eine weitergehende Größen-/Aufbewahrungsregel für eine
sehr lange Historie und weitere Fehler-/Teilscan-Abnahmen vor dem Schließen
von #56 zu prüfen. Die Gesamt-Roadmap bleibt offen.
