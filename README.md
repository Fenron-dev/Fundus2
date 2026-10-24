# Fundus2

Fundus ist eine lokale, portable Medienbibliothek für Desktop und Android —
selbst gehostet, ohne Cloud. Die Desktop-App ist zugleich Server im Heimnetz;
Android greift darauf zu, lädt Inhalte für unterwegs herunter und gleicht den
Fortschritt zurück.

> **Verhältnis zum Repo `Fundus`.** Dieses Repository ist am 2026-09-02 als
> Kopie von [`Fenron-dev/Fundus`](https://github.com/Fenron-dev/Fundus)
> angelegt worden. `Fundus` läuft dort unverändert weiter und wird von hier aus
> **nicht** angefasst. In `Fundus2` entsteht die Oberfläche neu auf Basis der
> Designvorlage; Datenmodell, Scanner, Import und Peer-Server werden
> übernommen und weiterentwickelt.
>
> Konzept, Designvorlagen und Umsetzungsplan liegen bewusst **nicht** im
> Repository (`Dokumentation/` steht in `.gitignore`), weil es öffentlich ist.

## Workspace

| Ordner | Inhalt |
|---|---|
| `app/` | Flutter-Client für macOS, Windows, Linux und Android |
| `packages/core/` | Datenmodell, SQLite-Index, Scanner, Import, Publication Engine |
| `packages/design/` | Nocturne als Flutter-Theme: Tokens und geteilte Komponenten |
| `packages/server/` | Eingebetteter Shelf-Server für das lokale Netz |
| `legacy/app/` | Der bisherige Client als Referenz — kein Workspace-Mitglied |

## Zwei Leitsätze

**Ansicht ≠ Ablage.** Ordner sind eine Ansicht auf dieselben Dateien, nicht die
Wahrheit. Jeder Bereich hat einen „Ordnen nach"-Umschalter; Filter gelten in
jeder Ansicht, auch im Ordnermodus.

**Herkunft ist eine Eigenschaft des Werks, keine Ansicht.** Lokal, Stream,
offline gesichert, nicht erreichbar und im Archiv sind Werte einer Spalte. Es
gibt daher **eine** Bibliotheksansicht, und „offline verfügbar" ist ein Filter,
kein eigener Bereich.

## Aktueller Stand

Lauffähig als Einzelplatz-Bibliothek:

- Bibliothek anlegen oder öffnen, zuletzt verwendete Ordner mit
  Verfügbarkeitsstatus
- unterbrechbarer Scan mit sichtbarem Fortschritt; portable relative Pfade
- eine Bibliotheksansicht mit Kacheln, Tabelle und Gruppierungen (Ordner,
  Reihe, Urheber, System, Runde, Thema, Zeit) — je Medientyp konfiguriert
- Filter nach Herkunft, Suche in der Ansicht, Sortierung; Leerzustände nennen
  immer ihre Ursache
- Werkdetail als ein Gerüst für alle Medientypen: Hero plus Bausteine
  (Dateien, Eigenschaften, Notizen und Lesezeichen, Personen, Geräte)
- Dashboard mit „Fortsetzen" und „Zuletzt hinzugefügt"
- zweispaltige Shell mit einklappbarer Navigation und Pfadleiste; darunter
  Bottom-Navigation für schmale Fenster und Android
- Einstellungen mit Thema, Dichte, Bibliotheken, Geräten und Diagnose
- Hell und Dunkel gleichwertig, Dichteumschaltung komfortabel/kompakt

Datenmodell (Schema 26):

- `sources` — die geöffnete Bibliothek ist selbst eine Quelle
- `availability` auf Dateien und Werken; der Pfad ist nicht mehr die Identität
- Geräteprofile portabel unter `_fundus/devices/`, damit eine Neuinstallation
  keine Reader- und Darstellungseinstellungen kostet
- Metadatenänderung und Feldverlauf gemeinsam im Index, anschließend portable
  Verlaufskopie; selektive Rücknahme unter „Metadatenverlauf“ am Werk
- unveränderliche Bildversionen im Vault, bildgenaue Rücknahme und einstellbare
  Aufbewahrung für ältere Änderungspakete und Bilder

Schema 26 migriert vorhandene Indizes ohne Änderung der Medien oder persönlichen
Stände. Ältere Clients können den neueren Index nicht öffnen; beteiligte Apps
aktualisieren und vorher eine Sicherung erstellen. Die automatische Erfassung
aller Metadatenübernahmen beim Bibliotheksscan ist noch in Arbeit.

Wiedergabe, Reader, Peer-Server-Anbindung, Katalog-Delta, Sync-Journal,
Downloads, Metadaten-Abgleich und Schutzmodus sind inzwischen im Workspace
vorhanden. `legacy/` bleibt als Referenz erhalten und ist kein Bestandteil des
aktiven Builds.

### Datensicherung und Dauerbetrieb

`Einstellungen → Serverwartung` sichert einen konsistenten SQLite-Schnappschuss
zusammen mit Fundus-Metadaten und Bildern als ZIP. Enthalten sind auch eigene
Eigenschaften, Personenprofile, Bewertungen und Teile-Metadaten. Die Sicherung
enthält private Daten, aber keine Geräte-Schlüssel oder Mediendateien.
Die Wiederherstellung prüft das Archiv und die Datenbank und legt ausschließlich
einen **neuen** Vault-Ordner an. Medien anschließend mit denselben relativen
Pfaden separat zurückkopieren; vorhandene Vaults werden nicht überschrieben.
`index.db` ist noch kein vollständig entbehrlicher Cache: vor einem Neuaufbau
die Sicherung benutzen. Ein App-Update nicht durch Deinstallation ersetzen.

Ein aktiver Host prüft seine Bibliothekszugriffe alle 15 Sekunden und versucht
fehlgeschlagene Handles mit Rücknahmeintervall wiederherzustellen. Kopplungen,
Zertifikat und Server-Port bleiben dabei unverändert. Mehrere gleichzeitig
schreibende Desktops auf derselben SMB-SQLite-Datei sind weiterhin nicht
empfohlen: pro Vault einen schreibenden Host benutzen, weitere Geräte per API.
Der konkrete Windows-/SMB-Langzeittest bleibt eine Geräteabnahme.

Neue Vorschau-Builds erfordern eine grüne CI; die sichtbare Version samt Commit
steht unter `Diagnose & Logging`. GitHub hält Vorschau-Artefakte 90 Tage vor.
Das ist keine dauerhafte Release-Ablage.

## Entwicklung

```sh
flutter pub get
dart analyze
dart format --output=none --set-exit-if-changed app packages
(cd packages/core && dart test)
(cd packages/server && dart test)
(cd packages/client && dart test)
(cd packages/design && flutter test)
(cd app && flutter test)
```

**Gebaut wird in GitHub Actions, nicht lokal.** Die Workflows
`Build macOS Preview`, `Build Windows Preview` und `Build Android Preview`
erzeugen die Artefakte und lassen sich auch von Hand starten
(`workflow_dispatch`); lokal laufen nur Analyse, Format und Tests.

### Android-Vorschau: der Signaturschlüssel

Jede veröffentlichte Vorschau muss mit demselben stabilen Schlüssel signiert
werden. Ein Debug-Schlüssel des GitHub-Runners wird bei jedem Lauf neu erzeugt
und kann keine vorhandene Installation aktualisieren. Der Workflow bricht
deshalb ohne die vier Secrets ab, statt eine APK zu veröffentlichen, die zur
Deinstallation zwingt.

Abhilfe ist ein eigener Schlüssel, einmal erzeugt und als Repository-Secret
hinterlegt. Der Schlüssel selbst gehört **nicht** ins Repository:

```sh
keytool -genkeypair -v -storetype PKCS12 \
  -keystore fundus-preview.p12 -alias fundus \
  -keyalg RSA -keysize 2048 -validity 10000
base64 -i fundus-preview.p12 | pbcopy   # macOS
```

Unter *Settings → Secrets and variables → Actions* anlegen:

| Secret | Inhalt |
| --- | --- |
| `FUNDUS_ANDROID_KEYSTORE_BASE64` | die kopierte Base64-Zeile |
| `FUNDUS_ANDROID_STORE_PASSWORD` | das Keystore-Passwort |
| `FUNDUS_ANDROID_KEY_ALIAS` | `fundus` |
| `FUNDUS_ANDROID_KEY_PASSWORD` | das Schlüssel-Passwort |

Falls bisher nur die alten, wechselnden Debug-APK installiert wurden, muss die
erste APK mit dem stabilen Schlüssel noch einmal von Hand installiert werden
(einmalig alte Installation entfernen). Ab dann geht jedes Update in place,
und die Kopplung sowie Offline-Kopien bleiben erhalten. Der Schlüssel darf
niemals ins Repository committed werden. Bei einem öffentlichen Repository
sollten außerdem nur vertrauenswürdige Personen Schreibrechte und die
Möglichkeit haben, GitHub-Workflows zu ändern: Der Keystore ist die
Signaturidentität der App, nicht bloß ein Versionszähler.

Dasselbe gilt für die heruntergeladenen Medien. Sie liegen im App-Speicher
des Geräts — dort, wo auch die Kopplung liegt —, und Android räumt diesen
Ordner beim Deinstallieren restlos ab. Solange jede Vorschau neu signiert
wird, ist jede Installation eine Deinstallation, und die Offline-Kopien sind
danach weg. Mit hinterlegtem Schlüssel ist ein Update ein Update: Kopplung
und Offline-Kopien bleiben. Einen Ort, der eine Deinstallation überlebt, gibt
es unter Android nur außerhalb des App-Speichers — in den geteilten
Dokumenten, wo die Dateien für jede andere App sichtbar wären; das wäre für
eine Mediathek der falsche Tausch.
