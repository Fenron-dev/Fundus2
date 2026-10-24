# Umsetzung der freigegebenen Erweiterungen

Auftrag vom 24.10.2026, [Roadmap #54](https://github.com/Fenron-dev/Fundus2/issues/54).
Dies ist ein Arbeitsstand, keine Erklärung, dass die gesamte Roadmap bereits
implementiert oder ausgeliefert ist. Die Stabilisierungsabnahme #47 bleibt separat.

## Umfang und Reihenfolge

1. Update-Posteingang und Abos (#56) – implementiert, CI und drei Plattform-Builds bestanden.
2. Intelligentes Offline-Mitnehmen (#55) – Regeln, Oberfläche und Download-Anbindung in Arbeit.
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
GitHub-CI und Android-Kompilierung der neuen Systemabfrage stehen für diesen
Schritt noch aus; erfolgreiche Builds des vorigen Schritts ersetzen das nicht.

**Weiterhin offen in #55:** ausdrücklich erlaubtes Aufräumen konsumierter
Kopien erst nach bestätigtem Fortschrittsabgleich und geprüftem verwaltetem
Dateipfad (keine Originale/externen Pfade), weitere Plattform-Erkennung
für WLAN/Laden, Neustart-/Unterbrechungs- und Schutzwechsel-Abnahmen sowie
Android-Laufzeit-/Akkuprüfung auf einem Gerät. Keine automatische Löschung ist
mit diesem Schritt aktiviert; Originalmedien bleiben unangetastet.
