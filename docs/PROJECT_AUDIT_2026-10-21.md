# Projektprüfung Fundus2 – 21.10.2026

Historischer Prüfstand **vor** der beauftragten Umsetzung. Korrekturen,
Nachweise und Grenzen stehen im
[Stabilisierungsnachtrag](STABILIZATION_2026-10-21.md), Umsetzung unter Issue #47.

## Prüfstand und Gesamturteil

Geprüft wurde `1edbe0e42d8adec73292c3698c4e80e356d837f1` auf
`claude/media-management-design-h84z84`, Schema 22. Der Branch entspricht dem
aktuellen Remote-Stand und ist der GitHub-Default-Branch. Vor der Prüfung war
der Arbeitsbaum sauber. Die 27 offenen GitHub-Issues wurden lesend mit dem
Code abgeglichen; es wurden keine Issues geändert oder neu angelegt.

Fundus2 besitzt eine weit entwickelte Funktionsbasis. Für den nächsten
Entwicklungsschritt haben Datensicherung, Zugriffskontrolle und die rote CI
jedoch Vorrang vor weiteren großen Funktionen. Die portable
Fortschrittssicherung ist implementiert, aber noch nicht ausreichend robust.
Die frühere Aussage, sie sichere Neuinstallation und Index-Neuaufbau allgemein
ab, war zu weitgehend.

Dieser Auftrag war eine Prüfung: Anwendungscode, reale Vaults und GitHub wurden
nicht verändert. Die zusätzlichen Reproduktionen liefen ausschließlich gegen
temporäre, eigens angelegte Testbibliotheken. Neu ist nur dieser lokale Bericht.

## Verifikation

| Prüfung | Ergebnis |
| --- | --- |
| Statische Analyse | Keine Fehler/Warnungen, 5 Info-Lints |
| Formatprüfung | 272 Dateien, keine Änderungen erforderlich |
| Core | 251 Tests erfolgreich |
| Server | 36 Tests erfolgreich |
| Client | 35 Tests erfolgreich |
| Design | 3 Tests erfolgreich |
| Flutter-App | 456 erfolgreich, 11 fehlgeschlagen, 8 übersprungen |
| Paketprüfung | 158 gehostete Pub-Pakete aus `pubspec.lock` über OSV geprüft, keine zugeordneten Advisories |

Die 11 lokalen App-Testfehler entstehen beim Aufräumen temporärer
Reader-/Player-Vaults (`Directory not empty` bzw. `PathNotFoundException`).
Die Checkpoint-Schreibqueue arbeitet nach dem Schließen noch weiter.
Der letzte [GitHub-CI-Lauf](https://github.com/Fenron-dev/Fundus2/actions/runs/36674902377)
ist ebenfalls fehlgeschlagen: 445 App-Tests erfolgreich, 22 fehlgeschlagen,
8 übersprungen. Die wechselnde Fehlerzahl passt zum Wettlauf. Die drei
Plattform-Builds desselben Commits waren trotzdem erfolgreich, weil sie
unabhängig von der CI veröffentlicht werden.

Die anfänglich durch die Sandbox blockierten Netzwerk-Tests wurden mit
freigegebenen lokalen Testports wiederholt und bestanden. Es wurde kein
lokaler App-Build erzeugt.

Die [OSV-Abfrage](https://google.github.io/osv.dev/post-v1-querybatch/) deckt
gemeldete Probleme zu den konkreten Pub-Paketversionen ab. Sie ist keine
vollständige Prüfung der eingebetteten nativen mpv-/FFmpeg-/PDFium-Bibliotheken
oder aller transitiven Android-/Windows-Komponenten. Die gezielte Suche nach
typischen eingecheckten privaten Schlüsseln und Tokenmustern im aktiven
Quellbaum ergab keinen Treffer; die gesamte Git-Historie wurde nicht auf
Geheimnisse gescannt.

## Priorisierte Fehler und Sicherheitsbefunde

P1 bedeutet: vor der nächsten als stabil bezeichneten Version beheben.
P2 bedeutet: anschließend im normalen Wartungsblock beheben. Die Bezeichnungen
sind Entwicklungsprioritäten, keine CVSS-Bewertungen.

### P1 – Löschen fremder/geschützter Marken über ein sichtbares Werk

**Bestätigt durch Reproduktion.**
`packages/server/lib/fundus_server.dart:1384` prüft beim Löschen nur, ob das
Werk aus der URL sichtbar ist. `FundusLibrary.deleteBookmark` reicht die
Marken-ID weiter; `packages/core/lib/src/database/fundus_database.dart:2890`
löscht ausschließlich mit `WHERE id = ?`. Die Zugehörigkeit der Marke zum
freigegebenen Werk fehlt. Markierungen verwenden denselben Löschpfad.

Ein gekoppeltes Gerät ohne HHH-Freigabe erhielt beim Lesen des geschützten
Werks HTTP 404. Mit dessen bekannter Marken-ID unter der URL eines sichtbaren
Werks erhielt es beim Löschen HTTP 200; die geschützte Marke war danach weg.
Voraussetzungen sind ein gültiges Geräte-Token und Kenntnis der Marken-ID,
etwa aus einer früheren Freigabe. Es ist kein anonymer Fernzugriff.

**Korrektur:** Löschabfrage an `id`, `work_id` und Nutzer binden, den
Annotationstyp prüfen und einen negativen Server-Test ergänzen. Dieser
spezifische Befund ist in den abgefragten offenen Issues noch nicht erfasst.

### P1 – Geschützte Playlist per POST überschreibbar

**Bestätigt durch Reproduktion; [Issue #30](https://github.com/Fenron-dev/Fundus2/issues/30).**
`packages/server/lib/fundus_server.dart:808` akzeptiert beim Anlegen eine
bestehende Playlist-ID. Der DB-Upsert ersetzt daraufhin die Liste, während
die Sichtbarkeits- und Revisionsprüfungen nur im PUT-Pfad stehen.
Das eingeschränkte Testgerät ersetzte eine geschützte Liste mit HTTP 201.

**Korrektur:** POST bei vorhandener ID mit Konflikt beantworten; bestehende
Listen über den geprüften PUT-Pfad ändern. Auch `file_id` pro Listeneintrag
gegen das angegebene Werk prüfen.

### P1 – Fremde Server-Kataloge werden erneut freigegeben

**Bestätigt durch Reproduktion; [Issue #28](https://github.com/Fenron-dev/Fundus2/issues/28).**
`SharedFundusLibrary._ensureFresh` liest in
`packages/server/lib/fundus_server.dart:68` alle Werke. Gespiegelte
Peer-Werke sind darunter. Ein nur mit Server A gekoppeltes Gerät erhält so
auch Titel und Metadaten eines von A eingebundenen Servers B, obwohl B dieses
Gerät nie freigegeben hat. Der HHH-Filter bleibt wirksam, die ursprüngliche
Quellenfreigabe jedoch nicht. Die Inhalte solcher Phantom-Werke sind über A
häufig nicht abrufbar.

**Korrektur:** Der Host liefert standardmäßig ausschließlich die lokale
Quelle aus; Katalog, Zähler, Dateien, Listen und Fortschritt konsistent prüfen.
Eine bewusste Weiterfreigabe wäre eine eigene, ausdrücklich konfigurierte Funktion.

### P1 – Checkpoints werden beim Schließen nicht zuverlässig abgeschlossen

**Durch Tests und Code bestätigt; [Issue #27](https://github.com/Fenron-dev/Fundus2/issues/27).**
`packages/core/lib/src/library/fundus_library.dart:1325` startet den
Sidecar-Schreibvorgang ohne Abwarten. `close()` bei Zeile 2779 schließt nur
die DB. Reader/Player lösen beim Dispose noch einen Checkpoint aus; ihre
Aufrufer können anschließend den Vault bereits freigeben oder entfernen.
`flushSidecarWrites()` existiert, wird in den produktiven Aufrufketten aber
nicht als Abschlussbarriere genutzt. Der Fehlerpfad der verworfenen Futures
ist ebenfalls nicht kontrolliert bis zum Aufrufer geführt.

**Korrektur:** Asynchronen, abwartbaren Checkpoint-/Close-Vertrag einführen,
Schreibfehler sichtbar protokollieren und die Lebenszyklen der Controller
einschließlich App-Hintergrund berücksichtigen. Builds erst bei grüner CI
als getestete Vorschau veröffentlichen.

### P1 – Eigene Eigenschaften gehen beim Index-Neuaufbau verloren

**Bestätigt durch Reproduktion; Teil von [Issue #7](https://github.com/Fenron-dev/Fundus2/issues/7).**
`savePropertyDefinition` und `setWorkProperty` in
`packages/core/lib/src/library/fundus_library.dart:1712`/`:1741` speichern nur
in SQLite. Der Metadaten-Sidecar enthält diese Definitionen/Werte nicht;
auch der Peer-Vertrag transportiert sie nicht.
Nach Speichern eines eigenen Textfelds, Schließen, Entfernen ausschließlich
der Test-`index.db` und erneutem Scan waren Definitionen und Werte leer.

**Korrektur:** Benutzerdefinierte Felder samt Definition, Herkunft und
Schutzkennzeichen portabel sichern, konfliktfähig importieren und synchronisieren.
Bis dahin darf der Index nicht als vollständig ersetzbarer Cache behandelt werden.

### P1 – Schutzmodus hat Nebenkanäle in der Oberfläche und im Protokoll

**Im Code bestätigt; [Issue #29](https://github.com/Fenron-dev/Fundus2/issues/29).**
Die zentrale Werkliste filtert geschützte Inhalte, aber Downloadaufträge,
Sync-Journal und automatisch angebotene Metadatenkonflikte lesen an dieser
Liste vorbei. Beispielsweise stehen `job.title` im Download-Verlauf und
`entry.title` in den Sync-Einstellungen ohne dieselbe Schutzprüfung.
`app/lib/app/fundus_scope.dart:920` und
`app/lib/media/playback_controller.dart:448` schreiben Werktitel unabhängig
von der Schutzklassifikation ins dauerhafte Diagnoseprotokoll.

**Korrektur:** Sichtbarkeitsprüfung auch für diese Ansichten; Titel/Pfade vor
dem Protokollieren anhand der Werkklassifikation redigieren. Entpackte
Comicseiten werden durch das leere `dispose()` ebenfalls nicht zeitnah
entfernt ([Issue #41](https://github.com/Fenron-dev/Fundus2/issues/41)); ihre
Bereinigung sollte zum Reader-Lebenszyklus gehören.

### P2 – Scrollposition innerhalb desselben Bilds wird nicht synchronisiert

**Bestätigt durch Reproduktion.**
`packages/client/lib/src/sync.dart:412` betrachtet Positionen als identisch,
wenn Datei, Zahlenwert, Element und Fertig-Status gleich sind. `scrollOffset`,
Positionsart, Kapitel und Schlüssel werden nicht vollständig verglichen.
Die Grundlinien bei Zeile 337/342 haben dieselbe Lücke.

Reproduktion: Zwei Geräte stehen auf Bild 5, eines bei 10 %, das andere neuer
bei 90 % der Bildhöhe. Der Sync meldet keinen Pull und lässt die alte
Scrollposition von 10 % stehen. Das kann einen Teil der früheren
Manga-Resume-Probleme erklären; es beweist nicht die Ursache jedes gemeldeten Sprungs.

**Korrektur:** Vollständige typisierte Position für Gleichheit und Grundlinie
verwenden; sinnvolle Toleranzen nur für numerische Rundungswerte festlegen.

### P2 – Fortschritts-Sidecar übersteht Ordnerumzug nicht vollständig

**Bestätigt durch Reproduktion.**
`progress.json` enthält den Pfad relativ zum Vault. Beim Import vergleicht
`packages/core/lib/src/library/fundus_library.dart:3046` diesen exakt.
Nach Verschieben des Testwerkordners und Neuaufbau nur der `index.db` blieb
die Werk-ID stabil, aber `loadProgress` lieferte keinen Stand.

**Korrektur:** Pfad relativ zum Werk oder eine portable Dateiidentität
verwenden; ältere Sidecars migrieren. Das bestehende DB-Tracking eines Umzugs
allein reicht für die Wiederherstellung aus Sidecars nicht.

### P2 – Fehlerhafter Fortschritts-Sidecar bricht den Scan ab

**Bestätigt durch Reproduktion; ebenfalls [Issue #27](https://github.com/Fenron-dev/Fundus2/issues/27).**
Ein Zahlenwert als String in `position.numeric_value` erzeugte einen
ungefangenen `_TypeError`. Der Scan fängt um den Import nur
`FileSystemException` und `FormatException` ab. Unbekannte Positionsarten
können zusätzlich einen `ArgumentError` auslösen.

**Korrektur:** Schema und Feldtypen vor dem Konstruieren validieren,
unlesbare/neuartige Einzelsidecars isolieren und diagnostizieren. Ein
fehlerhaftes Werk darf nicht die Bibliotheksaktualisierung abbrechen.

### P2 – Noch offene Härtung von Geheimnissen und Metadaten-Transport

**Im Code bestätigt; [Issue #31](https://github.com/Fenron-dev/Fundus2/issues/31),
[Issue #32](https://github.com/Fenron-dev/Fundus2/issues/32),
[Issue #33](https://github.com/Fenron-dev/Fundus2/issues/33).**

- Bei Keychain-Fehlern speichert `AppSettings._persist` Zugangsdaten still in
  `device.json` (`app/lib/app/app_settings.dart:575`).
- Der private Server-TLS-Schlüssel liegt als PEM-Datei im App-Support-Ordner
  (`app/lib/data/server_identity.dart:84`). Rechte werden auf Unix nachträglich
  eingeschränkt; unter Windows fehlt eine explizite zusätzliche Absicherung.
- Android definiert keine eigenen Backup-Regeln. Laut
  [Android-Dokumentation](https://developer.android.com/identity/data/autobackup)
  kann Auto Backup standardmäßig App-Dateien und DBs sichern, sofern die
  Geräte-/Nutzereinstellungen und Limits dies zulassen. Die tatsächliche
  Sicherung eines konkreten Geräts wurde nicht geprüft.
- `_networkMessage` gibt den Text von Transportfehlern ungefiltert aus
  (`app/lib/metadata/metadata_providers.dart:32`); dieser kann die vollständige
  TMDB-URL einschließlich `api_key` enthalten.
- Bildabrufe puffern außerhalb des Windows-Transportlimits Antworten ohne
  eigene gemeinsame Größen-/Formatprüfung.
- Fünf Claim-Anfragen mit beliebiger falscher Nonce können eine aktive
  Kopplung abbrechen. Reader-Profile besitzen keine kumulierten Größenlimits.

Keiner dieser Befunde belegt einen anonymen Zugriff aus dem Internet. Sie
sind relevante lokale, LAN- oder Datenschutzrisiken und sollten vor einer
breiteren Weitergabe behoben werden.

## Performance und Robustheit

| Engpass | Konkreter Codebefund | Empfohlener nächster Schritt |
| --- | --- | --- |
| Wiederholter Vollabgleich | Fehlendes Cover genügt in `catalogue_mirror.dart:109` für einen erneuten Vollkatalog, auch wenn die Quelle kein Cover besitzt | Remote-`hasCover` und ausstehende Cover lokal merken; gezielte Nachlieferung, Backoff; [#37](https://github.com/Fenron-dev/Fundus2/issues/37) |
| Dateicache spart Übertragung nicht | `peer_file_cache.dart:82` liest bei Cache-Treffer den kompletten GET-Body per `drain()`; ohne Server wird der vorhandene Cache nicht verwendet | Bedingter GET/304, Validatoren im Proxy weiterreichen; Offline-Fallback mit vollständigem Cache; [#38](https://github.com/Fenron-dev/Fundus2/issues/38) |
| Oberfläche wartet auf Serverarbeit | `SharedFundusLibrary` verwirft Tracks/Hashes nach 30 s; `/catalogue/index` baut pro Werk erneut Dateilisten und Hashes auf; Server läuft im UI-Isolate | Änderungsbasierte Invalidierung, gebündelte Abfragen, mittelfristig Worker-Isolate; [#39](https://github.com/Fenron-dev/Fundus2/issues/39) |
| Einzelne Checkpoints lesen zu viel | `_usesPortableSidecars` liest bei jedem Checkpoint die gesamte Werkliste und akzeptiert auch Peer-Werke | Einzelwerk-/Quellenabfrage; Peer-Sidecars gezielt behandeln; [#35](https://github.com/Fenron-dev/Fundus2/issues/35), [#36](https://github.com/Fenron-dev/Fundus2/issues/36) |
| Fehlende DB-Indizes | Rückwärtssuche in `work_files` nach `file_id` sowie mehrere Kind-/Personentabellen besitzen keine passenden führenden Indizes | Migration mit `EXPLAIN QUERY PLAN`-Tests; [#40](https://github.com/Fenron-dev/Fundus2/issues/40) |
| Netzwerkscan bleibt teuer | Verzeichnisse werden nacheinander gelistet; 16-fache Parallelität gilt nur für Dateien im aktuellen Ordner | Begrenzte Ordnerparallelität, Schreibbündelung, SMB-Messung; [#42](https://github.com/Fenron-dev/Fundus2/issues/42) |

Die zuletzt eingeführte Begrenzung auf acht parallele Cover-Downloads ist
sinnvoll, aber kein Sammelcover-Endpunkt. Sie löst die Vollabruf-Schleife nicht.
Auch normale Scans lesen bestehende Fero-Seitenwagen erneut; „keine
Mediendatei geändert“ garantiert damit noch keinen günstigen Scan.

Beim gemeinsamen Vault auf SMB öffnen beide Desktops dieselbe
`.library/index.db` schreibend. `busy_timeout=5000` ersetzt kein
geräteübergreifendes Schreib-/Sidecar-Protokoll. Es wurde hier keine
Datenkorruption nachgewiesen. SQLite selbst beschreibt jedoch
[Zuverlässigkeits- und Lockingrisiken bei Netzwerk-Dateisystemen](https://sqlite.org/useovernet.html).
Empfehlung: ein schreibender Host je Vault; weitere Geräte greifen über dessen
API zu. Alternativ lokale Geräte-Indizes mit wohldefiniertem Sidecar-Abgleich
planen, nicht mehrere beliebige Schreiber in derselben Netzwerk-DB.

Die aktuellen Videooptionen enthalten Read-ahead, Hardware-/Taktbehandlung und
Frame-Diagnose. Ob Windows-Mikroruckler damit vollständig beseitigt sind,
lässt sich auf diesem macOS-Prüfrechner ohne betroffene Medien, Netzwerkpfad
und Windows-Lauf nicht seriös bestätigen. Gleiches gilt für tatsächlichen
Android-Leerlaufverbrauch. Diese Abnahmen bleiben Gerätemessungen, siehe
[#24](https://github.com/Fenron-dev/Fundus2/issues/24).

## Umsetzung gegenüber Konzept und bisherigen Wünschen

| Bereich | Stand |
| --- | --- |
| Mehrere Serverbibliotheken, kombinierte Oberfläche, lokale Sichtbarkeit | Vorhanden; Weiterfreigabe-/Quellenidentitätsprobleme bleiben offen |
| Genre-/Tag-/Statusfilter, persönliche Statuswerte, Ratings | Vorhanden |
| Personenprofile, Rollenfilter, eigenes Bild, externe Links | Vorhanden; Identität wird weiterhin hauptsächlich über Namen aufgelöst |
| Flexible Eigenschaften | Acht Werttypen und Editor vorhanden; Personenwerttyp, vollständige Migration, Portabilität und Sync fehlen |
| Detailseiten je Datei/Band/Folge, Kapitelnavigation | Vorhanden; keine gleichwertige globale Einzelteil-Suche |
| Globale Suche nach einzelnen Folgen/Büchern | Noch offen: `work_filter.dart:250` durchsucht Werk-Metadaten, nicht Datei-/Teiltitel; [#7](https://github.com/Fenron-dev/Fundus2/issues/7) |
| Personen mit gleichem Namen auseinanderhalten | Noch offen: `replaceWorkPeople` sucht per Anzeigename; keine Zuordnungsrückfrage; [#7](https://github.com/Fenron-dev/Fundus2/issues/7) |
| Fero/ABS und Online-Metadaten | Adapter und konfliktfähiger Import vorhanden; echte Provider-Verfügbarkeit hier nicht live mit Benutzerwerken getestet |
| Konflikt-Posteingang | Sammel-UI vorhanden; ausstehende Konflikte liegen nur in `LibraryController._metadataConflicts`, gehen beim Neustart verloren bzw. müssen per Scan neu entdeckt werden |
| NovelUpdates | HTML-Reader vorhanden; Browserprüfung wird nur gemeldet, kein integrierter Browser-Challenge-Ablauf |
| CBR/7z, MOBI/AZW3 und generische Archive | Teilweise indexiert, aber im Reader nicht unterstützt; explizite Formatkennzeichnung/Fallback fehlt; [#44](https://github.com/Fenron-dev/Fundus2/issues/44) |
| Fernsehsender mit Regeln, Serienrotation und Werbeblöcken | Konzept und [#25](https://github.com/Fenron-dev/Fundus2/issues/25) vorhanden; kein implementierter Senderbereich/Planer |
| Mehrere Nutzer und Freigabe persönlicher Stände | Tabellen vorbereitet, produktiv weiterhin `default`; [#16](https://github.com/Fenron-dev/Fundus2/issues/16) |
| Versionierung und dauerhafte Downloads | App-Version weiterhin `0.1.0+1`, keine sichtbare Commit-Version; Artefakte 14 Tage; [#46](https://github.com/Fenron-dev/Fundus2/issues/46) |

## Empfohlene Reihenfolge und zusätzliche Funktionen

1. **Stabilisierung:** Zugriffslücken schließen, Checkpoint-Lebenszyklus und
   beschädigte Sidecars reparieren, CI wieder grün machen. Tests vor
   Artefaktfreigabe verpflichtend machen.
2. **Datenerhalt:** eigener vollständiger Backup-/Restore-Weg für persönliche
   Stände, Eigenschaften, Teile-Metadaten und Personenprofile; Wiederherstellung
   regelmäßig automatisiert prüfen. Ein Restore-Test ist aussagekräftiger als
   ein erfolgreicher Export allein.
3. **Schutz vervollständigen:** dieselbe Sichtbarkeitsregel in Journal,
   Download-Historie und Konflikten; redigierter Diagnoseexport; temporäre
   Comicseiten beim Schließen und nach Absturz aufräumen.
4. **Netzwerk und Medien:** Cache/304, Katalog-Delta, Hash-Invalidierung und
   DB-Indizes zuerst. Danach mit Frame-Diagnose die Windows-Wiedergabe unter
   lokaler Datei, SMB und Peer-Stream getrennt abnehmen.
5. **Bestehende Konzepte fertigstellen:** Einzelteil-Suche, eindeutige
   Personenidentität, typisierte Personenfelder, dauerhaft gespeicherter
   Konflikt-Posteingang und vollständiger Eigenschaften-Sync.
6. **Bedienbarkeit:** sichtbare Version/Commit, dauerhafte GitHub-Releases mit
   Änderungsnotizen und Rückkehr zu einem bekannten funktionierenden Stand.
   Ein Provider-Selbsttest in den Einstellungen sollte Authentifizierung,
   TLS, Suche und Bildabruf getrennt mit bereinigten Fehlern anzeigen.
7. **Neue Funktionen danach:** Bibliotheks-Sender zunächst mit Regelvorschau
   und deterministischer Serienrotation umsetzen, anschließend Zeitplan und
   Retro-Zwischenblöcke. Ein sichtbarer Bibliotheks-Gesundheitsbericht
   (ausstehende Sicherungen, letzter erfolgreicher Sync, fehlende Dateien)
   würde viele derzeit schwer deutbare Zustände direkt erklärbar machen.

Die Architektur muss dafür nicht komplett ersetzt werden. Die unmittelbaren
Fehler liegen überwiegend in Lebenszyklus, Quellen-/Berechtigungsgrenzen und
unvollständiger Persistenz bereits vorhandener Funktionen.
