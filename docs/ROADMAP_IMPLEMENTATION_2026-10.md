# Umsetzung der freigegebenen Erweiterungen

Auftrag vom 24.10.2026, [Roadmap #54](https://github.com/Fenron-dev/Fundus2/issues/54).
Dies ist ein Arbeitsstand, keine Erklärung, dass die gesamte Roadmap bereits
implementiert oder ausgeliefert ist. Die Stabilisierungsabnahme #47 bleibt separat.

## Umfang und Reihenfolge

1. Update-Posteingang und Abos (#56) – implementiert, CI und drei Plattform-Builds bestanden.
2. Intelligentes Offline-Mitnehmen (#55) – Regeln, Downloads und bestätigtes Aufräumen implementiert; Plattform-/Geräteabnahme offen.
3. Metadatenverlauf und gezieltes Rückgängig (#57) – Editor-/Abgleicherfassung, selektive Rücknahme und versionierte Bilder mit Aufbewahrung in der Oberfläche; automatische Scan-Erfassung offen.
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
zugangsdatenabhängig übersprungen. Die Kapitel-Erweiterung `ff8d48e` hat ihre
GitHub-CI bestanden (Run 40078336229). Zugeordnete Plattformläufe:
Windows 40078641688, macOS 40078641657, Android 40078641656; alle erfolgreich.
Issue #56 ist anhand dieser Nachweise abgeschlossen. #47 bleibt gesondert offen.
Die Gesamt-Roadmap bleibt offen.

## Intelligentes Offline-Mitnehmen: Planer-Grundlage

Der gemeinsame Core enthält zunächst eine reine Vorschau-Berechnung, noch
keine neue Download-Automatik oder fertige Bedienoberfläche. Regeln sind
standardmäßig aus. Anzahl, Speicherbudget, WLAN- und Ladebedingung haben ein
versioniertes Modell. Unbekannte Systembedingungen erlauben keine Übertragung;
die erste Ausführung bleibt ausdrücklich auf die geöffnete App begrenzt.

Die Auswahl beginnt an der ausdrücklich gewählten persönlichen Datei und
behält die vorgegebene Reihenfolge. Bereits vorhandene oder vorgemerkte Dateien
belegen Plätze im Vorausladefenster, damit erneutes Auswerten nicht immer weiter
die nächsten N Dateien nachlädt. Verbrauch und Reservierungen zählen global,
auch wenn die zugehörigen Werke derzeit nicht sichtbar sind. Unbekannte Größen,
fehlende Positionsanker und Budgetüberschreitungen werden als Grund ausgegeben;
eine zu große Folge wird nicht still übersprungen. EPUB/CBZ sind physische
Dateien, keine einzeln angebotenen eingebetteten Kapitel.

Zwölf gezielte Tests prüfen diese Berechnung. Der gesamte lokale Lauf mit
dieser Grundlage besteht 863 Tests (Core 290, Server 45, Client 41, Design 3,
App 484; acht App-Tests übersprungen), Analyse/Format sauber. Noch offen in #55: gespeicherte
Werk-/Regalregeln, Vorschau und Einstellungen in der Oberfläche, zuverlässige
Systembedingungen, Anbindung an die vorhandene Download-Warteschlange,
Unterbrechungs-/Fortsetzungsverhalten, ausdrücklich erlaubtes Aufräumen nach
bestätigtem Fortschrittssync sowie die Android-Geräteabnahme. Diese Grundlage
ist deshalb nicht als fertige Offline-Funktion abzuhaken.

### Zweiter Schritt: Regeln, Vorschau und Übertragung

- Auf einem entfernten Werk und im Download-Bereich (auch im Leerzustand)
  öffnet „Automatisch mitnehmen“ die Einstellungen. Opt-in, Anzahl, globales
  MiB-Budget, WLAN und Laden sind einstellbar. Die Vorschau nennt konkrete
  Dateien und Größen sowie Wartegründe. Lange Dateilisten sind virtualisiert.
- Regeln für einzelne Werke und gespeicherte Regale liegen versioniert im
  installationsgebundenen `device.json`, getrennt nach Vault-ID. Eine konkrete
  Werkregel hat Vorrang vor einem überlappenden Regal. Konfiguration wird
  gemeinsam gespeichert; unbekannte Versionen werden nicht still ersetzt.
- Die vorhandene Download-Warteschlange wird weiterverwendet. Nach Änderungen
  und optional einmal pro Minute wird **nur im Vordergrund und nur bei aktivem
  Opt-in mit Regeln** neu ausgewertet, ohne Scan oder zusätzlichen Katalogabruf.
  Wiederholversuche sind begrenzt. Hintergrundwechsel stoppt die Auswertung;
  laufende neue Übertragungen pausieren und behalten den empfangenen Präfix.
- Android fragt den aktiven ungetakteten WLAN-Transport und Ladestatus über
  System-APIs ab, ohne neuen Dienst, Wake-Lock oder permanente Registrierung.
  Während einer Übertragung höchstens eine Systemabfrage pro Sekunde;
  Schutz-/Vordergrundwechsel wirken ohne diese Verzögerung. Auf noch nicht
  unterstützten Plattformen bleibt der Systemstatus unbekannt: aktivierte
  Bedingungen warten, statt sie als erfüllt auszugeben. Der Nutzer kann
  bewusst Bedingungen abwählen. Quellen: [Android Netzwerkfähigkeiten](https://developer.android.com/reference/android/net/NetworkCapabilities),
  [Ladestatus](https://developer.android.com/training/monitoring-device-state/battery-monitoring).
- Budget zählt tatsächlich belegte Offline-Dateien einschließlich versteckter,
  verwaister und anderer Vault-Kopien sowie vorgemerkte Dateien. Ein gebündeltes
  Index-Inventar verhindert je eine Abfrage pro Werk auf Netzwerk-Vaults.
  Die Übertragung verwirft Antworten, die größer als die reservierte Datei sind;
  Größen ohne verlässliche Angaben werden nicht als kostenlos betrachtet.
- Unterbrochene Dateien werden mit Range und starkem ETag fortgesetzt. Ein
  geänderter Ressourcenstand, ungültiger Bereich oder vollständige Antwort
  darf nie an alte Bytes angehängt werden. Höchstens ein Neustartversuch.
  Identische gleichzeitige Cache-Anfragen teilen eine Übertragung. Erst eine
  vollständige Datei wird als Offline-Kopie registriert. Ein begrenzter Abruf
  überschreibt bei Fehlern keine bereits vollständige Kopie.
- Pausierte Aufträge lassen sich unter Beibehaltung von Dateiauswahl und
  Bedingungen fortsetzen. Vault-Wechsel beendet zugehörige Aufträge; alte
  Übertragungen dürfen nicht in einen neuen/geschlossenen Index schreiben.
- Nebenbefunde behoben: teilweise gesicherte Werke lösten ihre Gegenstelle
  fälschlich anhand der schon lokalen ersten Datei auf. Fertige Teilaufträge
  verhinderten weitere gezielte Downloads. Der leere Download-Bildschirm
  benachrichtigte beim Aufbau synchron seinen übergeordneten Zustand.
  Außerhalb von Fundus gelöschte Kopien werden in der Vorschau wieder als
  benötigte Dateien erkannt und tatsächlich erneut geholt, ohne den
  persönlichen Fortschritt zurückzusetzen.

Neue echte Server-/Clienttests prüfen Regeln, überlappende Regale, Gates,
globale Budgets, Schutz, keine endlose Nachfüllung, Wiederholung und weitere
Teildownloads. Cache-Tests prüfen Range, ETag-Wechsel, Zusammenlegen paralleler
Abrufe und Budgetgrenzen. Widget-Test: Einstellungen auch ohne Downloads,
Speichern und Abweisen ungültiger Eingaben ohne Überschreiben.

Lokale Abnahme dieses zweiten Schritts: Core 290, Server 45, Client 41,
Design 3 und App 498 bestanden (zusammen 877), acht App-Tests übersprungen.
Analyse/Format sauber. Eine bestehende unzuverlässige Testbereinigung wartet
nun auf `vault.shutdown`, bevor der temporäre Hörbuchordner entfernt wird;
zuvor konnte ein noch laufender Checkpoint dessen Löschung überholen.
Die automatische Auslösung und die reine Auswahlberechnung sind getrennt
getestet, damit ein Timer nicht unbemerkt eine Vorschau-Prüfung verändert.
GitHub-CI (40080736340) und die Plattformläufe für `2b0629e` sind erfolgreich:
Android 40081021280, Windows 40081021226, macOS 40081021231. Das bestätigt
Kompilierung und automatische Tests, nicht das Laufzeit-/Akkuverhalten auf
einem Android-Gerät.

**Zum Ende dieses zweiten Schritts noch offen:** ausdrücklich erlaubtes Aufräumen konsumierter
Kopien erst nach bestätigtem Fortschrittsabgleich und geprüftem verwaltetem
Dateipfad (keine Originale/externen Pfade), weitere Plattform-Erkennung
für WLAN/Laden, Neustart-/Unterbrechungs- und Schutzwechsel-Abnahmen sowie
Android-Laufzeit-/Akkuprüfung auf einem Gerät. Keine automatische Löschung ist
mit diesem Schritt aktiviert; Originalmedien bleiben unangetastet.

### Dritter Schritt: bestätigtes, ausdrücklich erlaubtes Aufräumen

Die neue Option „Konsumierte Offline-Kopien automatisch entfernen“ ist
standardmäßig **aus**. Sie setzt aktivierte Werk-/Regalregeln voraus und läuft
nur im Vordergrund. Die folgenden Voraussetzungen gelten gemeinsam:

- Nur ausdrücklich als fertig markierte physische Dateien gelten als
  konsumiert. Eine Position weiter hinten beweist nicht, dass davor liegende
  Kapitel gelesen wurden. Natürliches Audio-/Video-Ende mit bekannter Dauer
  und Reader-Wechsel hinter die letzte Seite/das letzte Kapitel markieren die
  tatsächlich beendete Datei, nicht übersprungene Dateien.
- Ein eigener Abschluss-Checkpoint muss vom zuständigen Server bestätigt
  sein. Dafür kann der vorhandene Fortschritts-PUT `confirm_checkpoint`
  anfordern. Der Server bestätigt erst nach erfolgreichem, abgewartetem
  Schreiben des portablen `progress.json` mit Flush und atomarem Ersetzen.
  Ein gleicher Autosave-Stand, ein fremder Gerätefortschritt oder ein alter
  Server ohne diese Bestätigung berechtigt nicht zum Aufräumen. Fehler beim
  Sidecar ergeben keine Bestätigung, auch wenn der Index schon aktualisiert ist.
- Die installationsgebundene Bestätigung enthält nur IDs, Peer-Fingerprint,
  Zeitpunkt und einen Hash des exakten lokalen Checkpoints; keine Titel,
  Dateipfade, Texte oder Zugangstokens. Vault, Quelle, Server, Bibliothek und
  Geräte-ID müssen übereinstimmen. Schon ein neuer lokaler Stand entwertet
  die alte Bestätigung. Höchstens 5.000 Bestätigungen werden behalten; entfernte
  alte Belege führen nur zum Behalten/erneuten Bestätigen von Kopien.
- Ungelöste Fortschrittskonflikte, aktive Player/Reader, versteckte Werke,
  laufende Downloads, die aktuelle unfertige Datei und das nächste ungelesene
  Vorausladefenster werden gehalten. Fertige kommende Dateien erzeugen keine
  endlose Folge von Entfernen und erneutem Herunterladen.
- Entfernt werden ausschließlich exakt zugeordnete verwaltete Cachedateien
  mit passendem Dateinamen, ID, Länge und Ressourcenrevision. Normalisierte
  und kanonische Pfade werden geprüft; Symlinks/Junctions und externe
  `offline_path`-Werte berechtigen nie zur Löschung von Originalen.
  Alte Kopien ohne Revisionsbeleg bleiben erhalten. Freigabe, Vordergrund,
  Vault, Konfiguration und Checkpoint werden vor dem Entfernen nochmals geprüft.
  Positionen, Bewertungen und Originalmedien werden dabei nicht gelöscht.

Die Auswahl und echte Server-/Clientbestätigung haben eigene Tests, inklusive
fehlgeschlagenem Sidecar-Schreiben, alten Servern ohne Beleg, fremden Geräten,
geändertem Checkpoint, aktivem/verstecktem Werk, Konflikten, veralteter Revision,
externem Originalpfad, symbolischem Link und nachträglich entzogener Erlaubnis.
Abschlusszustände bleiben beim Schließen und erneuten Öffnen erhalten; ein
bewusstes Zurückgehen zum erneuten Lesen beendet diesen Zustand wieder.
Die Bestätigungsauswahl arbeitet nur auf den ohnehin synchronisierten Werken,
nicht mit einer zusätzlichen Einzelabfrage pro Werk des gesamten Katalogs.
Ein unbekanntes zukünftiges Bestätigungsformat blockiert nur die optionale
Bereinigung, nicht den normalen Fortschrittsabgleich.

Lokale Abnahme: Core 296, Server 45, Client 46, Design 3, App 510 bestanden
(zusammen 900), acht App-Tests übersprungen; Analyse und Format sauber.
`6108375` hat GitHub-CI 40100997358 und alle drei Plattform-Builds bestanden:
macOS 40101296371, Windows 40101296270 und Android 40101296342.

**Weiterhin offen in #55:** weitere Plattform-Erkennung für WLAN/Laden sowie
die reale Android-Neustart-/Unterbrechungs-, Schutzwechsel- und Akkuabnahme.
Die vollständige Roadmap und #47 bleiben offen.

## Metadatenverlauf: Daten- und Ablagegrundlage

Der erste Grundlagenschritt war noch keine fertige Benutzerfunktion. Seine
Core-Verträge werden im nachfolgenden Anbindungsschritt tatsächlich genutzt:

- Ein Feldzustand enthält Wert bzw. ausdrückliches Fehlen, Herkunft,
  Herkunftszeitpunkt und manuelle Sperre. Unveränderliche JSON-Kopien
  verhindern, dass eine später veränderte Editor-Liste alte Einträge ändert.
- Eine bestätigte Bearbeitung/Übernahme ist ein Batch mit eigener ID, Quelle,
  Zeitpunkt und Feldänderungen über ein oder mehrere Werke. Gleiche ID mit
  gleichen Daten ist wiederholbar; andere Daten unter gleicher ID werden
  zurückgewiesen. Eine Rücknahme bleibt als neuer Batch auf ihren Ursprung
  bezogen, statt den alten Verlauf umzuschreiben.
- Die Rücknahme-Vorschau vergleicht den aktuellen Zustand mit dem damals
  gespeicherten Nachher-Zustand einschließlich Herkunft/Sperre. Neuere
  Korrekturen sind Konflikte. Nicht sichtbare/nicht verfügbare Felder geben
  keine alten Inhalte preis. Der spätere Schreiber muss diesen Vergleich
  unmittelbar in seiner Änderungstransaktion erneut ausführen.
- Eine Positivliste erlaubt nur Metadatenfelder und eigene Eigenschaften.
  Positionen, persönliche Stimmen, Notizen, Lesezeichen, Gerätegeheimnisse und
  Offline-Pfade sind keine rücknehmbaren Metadatenfelder.
- `_fundus/metadata-history.json`, zunächst Format 1 (Format 2 siehe unten), wird bei explizitem Core-Aufruf
  seriell gelesen/ergänzt und mit dem bestehenden atomaren Sidecar-Schreiber
  gesichert. Fehlende Dateien bedeuten leeren Verlauf; beschädigte,
  unbekannte, übergroße oder verlinkte Dateien/Ordner werden nicht als leer
  ersetzt. Shutdown und Backup warten auf laufende Ergänzungen. Backup/Restore
  übernimmt den Verlauf; das reine Ergänzen verändert keine Werkdaten/Stände.
- Vorläufige API-Standardgrenzen: 100 ganze Batches und 16 MiB, harte
  Lesebegrenzung 32 MiB, höchstens 1.000 Batches. Ein einzelner Feldzustand
  ist auf 256 KiB und begrenzte JSON-Tiefe beschränkt. Aufbewahrung entfernt
  immer ganze alte Batches; ein zu großer einzelner Batch wird ausdrücklich
  abgewiesen. Dafür gibt es noch keine Benutzereinstellung.

Zwanzig gezielte Tests prüfen Modell, Vergleich, Herkunft/Sperre, Auswahl,
Zwischenänderungen, verborgene Felder, vollständige Batch-Aufbewahrung,
Wiederholung, ungültige Formate, paralleles Schreiben, Neustart, Schreibschutz,
Pfadverlinkungen und echte Sicherung/Wiederherstellung. Es gibt keinen neuen
Peer-Endpunkt und keine Datenbankschemaänderung.

Lokale Gesamtprüfung mit dieser Grundlage: Core 316, Server 45, Client 46,
Design 3 und App 510 bestanden (zusammen 920), acht App-Tests übersprungen.
Analyse/Format sauber. `6f9345e` hat CI 40101991984 und alle drei Builds
bestanden: macOS 40102291808, Windows 40102291818, Android 40102291872.

**Zum Ende dieses Grundlagenschritts noch offen:** tatsächliche Erfassung aller bestätigten Editor-, Provider-,
Fero-/ABS-Konflikt- und Massenänderungen, transaktionale Konsistenz zwischen
Änderung und Verlauf, geschützte/virtualisierte Oberfläche, echtes feldweises
und Batch-Rücknehmen, Bildversionen einschließlich Begrenzung und Bedienung
der Aufbewahrung. Dieser Grundlagenschritt hakt diese Abnahmepunkte nicht ab.

### Zweiter Schritt: tatsächliche Erfassung und Rücknahme

- Schema 25 ergänzt `metadata_history_batches` und einen kleinen
  Revisions-/Exportstatus. Die Migration von 24 und ältere Vorversionspfade
  sind geprüft. Medien, Fortschritt, Stimmen und Annotationen werden dabei
  nicht umgebaut oder gelöscht. Ein älterer Client lehnt den neueren Index ab;
  betroffene Apps aktualisieren und vor der Migration ein Backup erstellen.
- Bestätigte Änderungen über Werkeditor, Statusauswahl, Tags, eigene
  Nicht-Bewertungs-Eigenschaften, Online-Abgleich und Fero-/ABS-Konfliktentscheidungen
  speichern tatsächliche Vorher-/Nachher-Zustände zusammen mit der Änderung
  in **derselben SQLite-Transaktion**. Schlägt das Einfügen in den Verlauf
  fehl, werden auch Metadaten und Suchindexänderung zurückgerollt. Verschachtelte
  Metadatenoperationen nutzen Savepoints. Fortschrittsoperationen gehören
  nicht in diese Transaktion.
- Werkeditor mit „alle Bände“, Mehrfacheditor, Massenabgleich und gemeinsam
  bestätigte Importkonflikte verwenden je eine logische Batch-ID. Einzelne
  Schritte dürfen auf Bilder oder Sidecars warten, ohne SQLite offen zu halten.
  Der Batch behält pro Feld den ersten Vorher- und letzten Nachher-Zustand.
  Bei einem späteren Teilfehler bleiben genau die bereits bestätigten Schritte
  nachvollziehbar; es wird keine rückwirkende Komplett-Atomarität versprochen.
- Die portable Datei wird pro logischem Batch zusammengefasst geschrieben.
  Shutdown und Backup erzwingen auch bei einem noch offenen Batch die Sicherung
  des bislang bestätigten Standes. Ein fehlgeschlagener Export löscht den
  Indexverlauf nicht: sein Revisionsstand bleibt offen und wird beim nächsten
  Öffnen nachgetragen. Eine beschädigte/zu neue portable Datei bleibt erhalten;
  die Oberfläche meldet den ausstehenden Export. Ein frischer Index importiert
  den portablen Verlauf einmalig. Ein nicht initialisierbarer Verlauf blockiert
  neue protokollpflichtige Änderungen, nicht das Lesen oder Fortschrittsspeichern.
- „Metadatenverlauf“ am Werk zeigt Quelle, Zeitpunkt und feldweisen Vergleich
  mit aufklappbarer langer Darstellung. Batch- und Feldlisten sind virtualisiert.
  Zunächst gilt die Auswahl nur für dieses Werk; andere **aktuell sichtbare**
  Werke des Batches werden nur ausdrücklich einbezogen. Auswahl ist anfangs leer.
- Die echte Rücknahme prüft Feldzustand und Auswahl direkt in ihrer
  Transaktion erneut. Zwischenzeitliche Werte/Herkunft/Sperren verhindern die
  gesamte ausgewählte Rücknahme; nichts wird still teilweise überschrieben.
  Der Nutzer kann danach ausdrücklich nur konfliktfreie Felder auswählen.
  Eine seit der angezeigten Vorschau erweiterte Batch-Fassung wird ebenfalls
  abgewiesen. Rücknahmen werden als neuer, auf den Ursprung bezogener Batch
  protokolliert und können selbst wieder zurückgenommen werden.
- Frühere Feldherkunft und Sperre werden wiederhergestellt, statt alles als
  neue manuelle Vorgabe zu sperren. Urheberliste und abgeleiteter Haupturheber
  sind dabei ein gemeinsames Feld; Suchindex und abgeleitete Personenbezüge
  werden nachgeführt. Entfernte/geänderte eigene Felddefinitionen werden
  geprüft, nicht still passend gemacht. Persönliche Sterne-Felder, Stimmen,
  Fortschritte, Notizen und Lesezeichen bleiben unangetastet.
- Format 2 hält die Schutzkennzeichnung **zum Änderungszeitpunkt** fest.
  Früher geschützte Inhalte bleiben im Verlauf verborgen, auch wenn das Werk
  später anders eingestuft wird. Format 1 wird konservativ als geschützt
  eingelesen und erst bewusst entsperrt angezeigt; ältere Clients dürfen
  Format 2 nicht überschreiben. Zusätzlich gelten aktuelle Werk-, Bibliotheks-,
  Eigenschafts- und Tagfreigaben. Sperren entfernt auch einen bereits geöffneten
  und vergrößerten Vergleich. Es gibt weiterhin keinen Peer-Verlaufsendpunkt.
- Gleiche Werte mit gleicher Herkunft erzeugen keine neue Herkunftszeit und
  keinen neuen Verlaufseintrag. Ein unveränderter Scan entwertet dadurch keine
  Rücknahme-Vorschau. Werkänderungen lesen nur noch das betroffene Werk zurück,
  nicht den ganzen Katalog.

Nebenbefund aus der Gesamtprüfung: Ein automatisch nachgeholter Serverstart
konnte nach `stop`/`dispose` weiterlaufen. Startaufrufe teilen jetzt ihren
laufenden Abschluss, Stop wartet darauf; nach asynchronen Startschritten wird
eine Rücknahme geprüft. Nach Dispose erfolgen keine späten Start- oder
Pairing-Benachrichtigungen. Tests warten auf den tatsächlichen Start statt auf
eine feste 400-ms-Vermutung. Der mobile Detailtest scrollt den gewachsenen
Aktionskopf tatsächlich bis zu den Tabs, statt deren sofortige Sichtbarkeit
vorauszusetzen.

Lokale Gesamtprüfung dieses Anbindungsschritts: Core 334, Server 45, Client 46,
Design 3 und App 516 bestanden (zusammen 944); acht App-Tests übersprungen,
Analyse/Format sauber. Neue Tests prüfen echte Feld-/Massenrücknahme und deren
Rücknahme, erhaltene Herkunft, veraltete Batch-Vorschau, atomaren Abbruch,
verschachtelte Transaktionen, unveränderte persönliche Daten, Exportfehler mit
Neustart-Recovery, historische Schutzkennzeichnung, Schema-24-Migration und
mobile Bedienung einschließlich Sperren eines erweiterten Vergleichs.
GitHub-CI 40105755747 und die Plattform-Builds dieses Schritts sind bestanden:
macOS 40106116415, Windows 40106116368, Android 40106116308. Der
nachfolgende Bildschritt benötigt eine eigene Abnahme.

**Zum Ende dieses Schritts offen in #57:** Bildversionen mit begrenzter
Aufbewahrung, Bild-Rücknahme, vollständige Erfassung automatischer
Scan-Übernahmen und Bedienung der Aufbewahrungsgrenzen. Die folgenden Absätze
beschreiben den danach begonnenen Bildschritt. #57 bleibt offen.

### Dritter Schritt: Bildversionen und Aufbewahrung

- Schema 26 ergänzt eine Aufbewahrungsregel und Belege für die aktuell
  ausgewählten Cover, Breitbilder und zwischengespeicherten Cover. Die Migration
  von Schema 25 bewahrt Verlauf, Exportrevision und persönliche Daten. Vor dem
  ersten Öffnen mit Schema 26 beide Clients aktualisieren und ein Backup
  erstellen; ältere Clients lehnen den neuen Index ab.
- Neue Bildentscheidungen speichern eine unveränderliche, anhand SHA-256
  überprüfte Kopie unter `.library/covers/versions/`. Bilder aus Medienordnern
  werden gelesen und nie überschrieben. Ein ungenutztes heruntergeladenes
  Cover ändert den sichtbaren Bildverlauf erst bei ausdrücklicher Auswahl.
  Der manuelle Werkeditor aktiviert ein dort gewähltes Cover nun auch dann,
  wenn ein Ordner-Cover vorhanden ist.
- Der Verlaufszustand beschreibt die *sichtbare* Bildversion. Wechsel und
  Rücknahme prüfen das aktuelle Bild sowie die vorherige Kopie auf Größe und
  Hash. Ein fehlendes, beschädigtes oder extern verändertes Bild bricht die
  ganze ausgewählte Rücknahme ab. Alte Einträge ohne sicheren Bildbeleg bleiben
  lesbar, aber für Bilder nicht auswählbar. Andere Metadaten im selben Batch
  können weiter einzeln zurückgenommen werden.
- Das Werk-Sidecar trägt Bildauswahl und Belege in Format 5. Beim Neuaufbau des
  Index werden nur überprüfte Kopien wiederhergestellt; ein neueres Bild aus
  dem Medienordner übernimmt keinen veralteten Beleg. Vault-Backup und
  Wiederherstellung nehmen den verwalteten Bildordner mit.
- Das Verlaufsdokument nutzt Format 3 mit portabler Aufbewahrungsregel.
  Standard: 100 ganze Batches, 16 MiB Verlaufstext und 256 MiB ältere
  Bildversionen; pro Bild höchstens 32 MiB. Im Verlauf lässt sich die Grenze
  ändern. Vor einem verlustbehafteten Absenken zeigt die App die Anzahl der
  betroffenen Änderungspakete und die voraussichtlich entfallenden Bildbytes
  zur Bestätigung. Aktuell benutzte Bilder zählen nicht gegen das Budget und
  werden nicht entfernt. Aufräumen erfolgt erst nach erfolgreichem Export der
  portablen Verlaufskopie; fremde Dateien, Links und unbestätigte Bilder werden
  nicht gelöscht. Alte eigene Teil-Dateien werden erst nach einem Tag entfernt.
- Ein normaler inkrementeller Scan bemerkt jetzt auch neu hinzugefügte oder
  geänderte Hörbuch-Cover. Bei geänderter Ordnerdatei wird ein alter Bildbeleg
  verworfen. Die automatische Historisierung aller Fero-/ABS-/Scan-Metadaten
  benötigt weiterhin eine separate saubere Transaktionsgrenze und bleibt offen.

Gezielte Tests prüfen Schema-25-Migration, Bildwechsel und Rücknahme,
fehlende Bildversionen, unveränderte Ordner-Cover, Neuaufbau des Index,
Bildbudget und Löschung alter Kopien, verlinkte Pfade und die Bildvorschau im
Flutter-Dialog. Die lokale Gesamtprüfung dieses Bildschritts besteht aus
Core 344, Server 45, Client 46, Design 3 und App 518 bestandenen Tests
(zusammen 956); acht App-Tests sind übersprungen. `dart analyze` und
Formatprüfung sind sauber. GitHub-CI und Plattform-Builds für diesen
Änderungsstand sind noch ausstehende Freigabeschritte.
