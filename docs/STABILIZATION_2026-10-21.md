# Stabilisierung nach Projektprüfung – 21.10.2026

Umsetzung zu [Issue #47](https://github.com/Fenron-dev/Fundus2/issues/47).
Ausgangspunkt `1edbe0e`; der [Prüfbericht](PROJECT_AUDIT_2026-10-21.md)
bleibt als historischer Vorher-Zustand erhalten.

## Dauerbetrieb und Netzwerk

- Der Host kontrolliert Bibliothekszugriffe alle 15 Sekunden. Fehlerhafte
  aktive, von der Oberfläche geliehene Handles ersetzt der LibraryController;
  zusätzliche Host-Vaults ersetzt der Host. Kein dauerhaftes Entfernen eines
  fehlgeschlagenen aktiven Vaults mehr. Wiederholungen sind serialisiert und
  nach Fehlern 30 Sekunden zurückgenommen.
- SQLite-I/O-/Öffnungsfehler markieren das Registry-Handle explizit als
  fehlerhaft: eine Schema-Probe kann noch aus dem Cache antworten, während die
  nächste Werkabfrage bereits an SMB scheitert. Gesperrte DBs antworten mit 503
  statt unspezifischem 500; die DB wird nicht zurückgesetzt.
- Wiederöffnen ändert weder Server-ID, Zertifikat, Token noch Port. Ein
  Regressionstest ersetzt ein geschlossenes aktives Handle und prüft
  Identität, Port, Werkbestand und Erreichbarkeitsstatus.
  Offene Reader/Player werden an das Ersatz-Handle gebunden, ohne ihre aktuelle
  Position neu zu laden; fortlaufendes Speichern ist ebenfalls getestet.
- Katalog-/Datei-/Hash-Caches werden über eine DB-Revision invalidiert, nicht
  mehr alle 30 Sekunden oder bei jeder Fortschritts-UI-Meldung. SQLite-Trigger
  erfassen auch Änderungen anderer Verbindungen.
- Remote-Cover werden anhand `remote_has_cover` gezielt nachgeladen. Coverlose
  Werke erzwingen keinen Vollabzug; fehlgeschlagene Bilder haben eine Stunde
  Backoff. Alte Spiegel lernen diese Information einmalig; fehlende/verwaiste
  Werke lösen diese Migration nicht erneut aus.
- Dateicache/Proxy benutzen ETag/Last-Modified und bedingte Abrufe. Cache-Treffer
  leeren keinen kompletten GET-Body mehr. Nur vollständig verifizierte Dateien
  sind bei Verbindungsfehlern/5xx offline verwendbar; 401/403 werden nicht durch
  einen stillen Fallback kaschiert. Netzwerkoperationen und inaktive Streams
  sind begrenzt; die Stream-Frist gilt zwischen Paketen, nicht für die gesamte
  Filmlaufzeit.
- Ordner werden begrenzt parallel gelistet (vier), Dateiproben gebündelt.
  Unerwartet beendete Scan-Isolates beenden den Scan mit Fehler, statt den
  Fortschrittsindikator unbegrenzt weiterlaufen zu lassen.

## Zugriffsschutz und Geheimnisse

- Markenlöschung ist an Werk, Nutzer und Annotationstyp gebunden. Eine bekannte
  fremde Marken-ID unter einem sichtbaren Werk löscht keine geschützte Marke.
- Playlist-POST mit vorhandener ID liefert 409. Änderungen bleiben im
  revisionsgeprüften PUT-Pfad. Datei-IDs müssen zum jeweiligen Werk gehören.
- Server liefern nur die lokale Quelle des freigegebenen Vaults aus, keine
  gespiegelten Kataloge fremder Hosts. Bewusste Weiterfreigabe wäre eine eigene,
  noch nicht implementierte Funktion.
- Geschützte Eigenschaften/Tags werden auch in Katalog, Details und
  Annotationen gefiltert. Ein eingeschränktes Gerät entfernt versteckte Tags
  nicht unbeabsichtigt beim Speichern seiner sichtbaren Liste.
- Download-Historie, laufende Downloads, Sync-Journal und Konflikt-Posteingang
  beachten dieselbe sichtbare Werkmenge. Beim Sperren werden offene geschützte
  Reader/Player/Galerien geschlossen. Veraltete Play-Aufrufe umgehen diese
  Sichtbarkeitsprüfung nicht.
- Diagnoseeinträge enthalten keine Mediennamen unter den bekannten
  Titel-/Datei-/Werk-Feldern; Fehler werden auf Typ/Code reduziert. Vollständige
  Request-URLs mit API-Schlüsseln gelangen nicht in Provider-Fehlermeldungen.
  Schreibqueue und laufende Dateigröße des Diagnoseprotokolls sind begrenzt.
- AppSettings schreibt nach Keychain-Fehlern keine neuen Zugangsdaten in
  `device.json`. Legacy-Werte werden erst nach bestätigter sicherer Speicherung
  entfernt. Der Ausfall ist in Diagnose sichtbar; neue Zugangsdaten bleiben
  dann nur im Arbeitsspeicher der Sitzung. Änderungen sind serialisiert und
  lösen keine unnötigen erneuten Secret-Schreibvorgänge aus.
- Der normale Plattformpfad migriert den Server-TLS-Schlüssel in den
  Betriebssystem-Schlüsselspeicher. Zertifikat/Fingerprint und Server-ID bleiben
  gleich. Erst bestätigtes Zurücklesen erlaubt das Entfernen der alten PEM.
  Explizite Dateispeicher für Tests/Headless-Nutzung bleiben möglich.
- Android-Cloud-/Gerätetransfer-Backup für App-private Daten ist explizit
  ausgeschlossen. Der ungenutzte, breit konfigurierte FileProvider wurde aus
  der App-Konfiguration entfernt; keine Nutzerdaten wurden dabei gelöscht.
- Cover-Abrufe verlangen HTTPS (Loopback-Tests ausgenommen), besitzen ein
  gemeinsames 20-MiB-Limit und prüfen Bildsignaturen. Kein TLS-Bypass.
- Nicht zur Einladung gehörende Nonces verbrauchen keine PIN-Versuche.
  Reader-Profile sind pro Profil, Gerät und Werk begrenzt; ein gekoppeltes Gerät
  darf nur unter seiner eigenen Gerätekennung schreiben.

## Datenerhalt

- `FundusLibrary.shutdown()` wartet Sidecar-Schreibvorgänge ab. Vault-Wechsel,
  Host-Stop und Handle-Austausch benutzen diesen Vertrag. Fehler laufen nicht
  mehr als unbeobachtete Futures weiter; Diagnose und die unterstützte
  Desktop-Exit-Anfrage weisen auf unbestätigte Sicherungen hin. Hintergrund-
  wechsel erzeugt einen bewussten Reader-/Player-Checkpoint.
- Sidecars werden serialisiert über eindeutige temporäre Nachbardateien
  ersetzt. Kein vorheriges Löschen des gültigen Ziels. Fortschritt und
  Metadaten bleiben getrennte Datenbankoperationen.
- Fortschrittsformat 2 enthält zusätzlich den werkrelativen Dateipfad. Ein
  Werkordnerumzug mit Index-Neuaufbau verliert damit nicht den Bild-/Lesestand.
  Version 1 bleibt lesbar, bei Umzug nur mit eindeutigem Dateinamen-Fallback.
  Fehlerhafte Typen, unbekannte Formate und Zukunftszeitpunkte brechen nicht
  den gesamten Scan ab. Sync-Vergleiche berücksichtigen Scrolloffset, Kapitel,
  Positionsart und Schlüssel.
- Eigene Felddefinitionen/Löschmarken liegen zusätzlich unter
  `_fundus/property-definitions.json`; Werte samt Definition/Herkunft in den
  `meta.yaml`-Seitenwagen. Index-Neuaufbau ist dafür getestet. Der Katalog
  transportiert freigegebene Definitionen/Werte zum Spiegel; bestehende lokale
  Werte/Typen werden nicht still überschrieben.
- Konflikte werden unter `_fundus/metadata-conflicts.json` gesichert und ohne
  neuen Scan beim Öffnen geladen. „Später“ behält die Entscheidung. Automatische
  Dialoge sind in Benachrichtigungen abschaltbar; dieselbe Entscheidung wird
  innerhalb einer Sitzung nicht bei jeder Aktualisierung erneut angeboten.
- Backup in der Serverwartung benutzt SQLite `VACUUM INTO`, nicht Kopieren
  einer laufenden DB. ZIP enthält DB, Fundus-Metadaten und Fundus-Bilder, also
  auch Personenprofile, Teile-Metadaten, Ratings und eigene Felder. Keine
  Mediendateien/Geräte-Schlüssel. Die Sicherung enthält private Informationen
  und ist nicht automatisch verschlüsselt.
- Restore prüft Pfade, Symlinks, Mengen-/Größenlimits, Manifest, Schema und
  DB-Integrität. Es wird ausschließlich ein neuer Unterordner angelegt; kein
  vorhandener Vault wird überschrieben. Medien anschließend mit gleichen
  relativen Pfaden separat zurückkopieren. Restore und bösartiger Archivpfad
  sind automatisiert geprüft.
- Comicquellen besitzen ihre temporären Entpackverzeichnisse und löschen sie
  beim Schließen. Veraltete asynchrone Ladevorgänge dürfen weder den neuen Band
  überschreiben noch nach Dispose UI-Meldungen auslösen. Die bisherige
  Altersbereinigung nach Abstürzen bleibt zusätzlich bestehen.

## Schema und Builds

- Migration 22 → 23: Rückwärtsindizes für Dateien, Personen, Tags und
  Anmerkungs-/Playlist-Kindtabellen sowie Katalogrevision/Trigger. Migration und
  Indexnutzung getestet; keine Medien-/Fortschrittstabellen werden gelöscht.
- Vorschau `0.2.0`, sichtbare Buildnummer/Commit in Diagnose. Nicht unterstützte
  Formate erhalten auf der Einzelteilseite einen klaren Reader-Hinweis.
- Plattform-Builds folgen erfolgreicher Push-CI desselben Commits. Manuelle
  Builds durchlaufen die wiederverwendbare CI zuerst. PR-/Fork-CI löst keinen
  signierten Build aus. Actions sind auf geprüfte Commit-IDs gepinnt,
  Android-Secrets gelangen nur über Umgebungsvariablen ins Skript; Dependabot
  ist konfiguriert. Vorschau-Artefakte bleiben 90 statt 14 Tage erhalten.
  Plattformkompilierung ausschließlich GitHub, keine lokalen App-Builds.

## Abnahme und bewusst offene Grenzen

Lokaler Abschlussstand: Analyse ohne Befunde, Formatprüfung sauber,
Core 260, Server 44, Client 35, Design 3, App 475 erfolgreiche Tests;
8 plattform-/zugangsdatenabhängige App-Tests übersprungen. Die zuvor roten
Reader-/Player-Teardowns warten den Abschlussvertrag ab, statt Test-Vaults
während laufender Checkpoint-Schreibvorgänge zu löschen. Workflows zusätzlich
mit actionlint geprüft. GitHub-Läufe und Abnahme werden in #47 verlinkt.

Nicht als erledigt ausgegeben werden:

1. Mehrtägiger Windows-/SMB-Dauerbetrieb, echte Video-Frame-Zeiten und Android-
   Akkuverbrauch brauchen die jeweiligen Geräte. Hier wurden konkrete
   Fehlerpfade/Wiederherstellung getestet, nicht jeder mögliche Grund eines
   eingefrorenen Windows-Fensters bewiesen oder ausgeschlossen.
2. SQLite bleibt bei Netzwerk-Vaults auf der Freigabe. Keine Zusicherung für
   mehrere gleichzeitig schreibende Desktops; ein schreibender Host je Vault
   bleibt die Betriebsregel. Lokale Indizes/Worker für alle Server-DB-Abfragen
   wären ein eigener größerer Umbau.
3. `index.db` ist noch kein vollständig entbehrlicher Cache. Eigene Felder sind
   portabel, weitere Zusatzdaten durch vollständiges Backup abgesichert. Vor
   Neuaufbau/Neuinstallation sichern, nicht einfach DB/App löschen.
4. Eigenschafts-Katalogimport ergänzt fehlende Werte. Vollständiger
   bidirektionaler Eigenschafts-/Löschkonfliktabgleich, Personenwerttyp und
   Rückfrage bei gleichnamigen Personen bleiben in #7 offen.
5. Ein Format-Hinweis macht CBR/7z und MOBI/AZW3 nicht zu unterstützten internen
   Reader-Formaten (#44). Einzelteil-Suche, Mehrnutzerbetrieb, Browser-Challenge-
   Integration und Bibliotheks-TV bleiben eigenständige Funktionsarbeiten.
6. Permanente Releases/Rollback-Artefakte (#46; 90 Tage sind nicht dauerhaft)
   und restliche Vereinheitlichung älterer UI-Maße/Farben (#43) bleiben offen.
   Grüne Tests sind keine pauschale Garantie, dass Anwendung oder eingebettete
   native Bibliotheken frei von Sicherheitslücken sind.
