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

Datenmodell (Schema 8):

- `sources` — die geöffnete Bibliothek ist selbst eine Quelle
- `availability` auf Dateien und Werken; der Pfad ist nicht mehr die Identität
- Geräteprofile portabel unter `_fundus/devices/`, damit eine Neuinstallation
  keine Reader- und Darstellungseinstellungen kostet

Noch nicht gebaut: Wiedergabe und Reader, Peer-Server-Anbindung, Katalog-Delta,
Sync-Journal, Downloads, Metadaten-Abgleich, Schutzmodus.

## Entwicklung

```sh
flutter pub get
dart analyze
dart format --output=none --set-exit-if-changed app packages
(cd packages/core && dart test)
(cd packages/server && dart test)
(cd app && flutter test)
```

**Gebaut wird in GitHub Actions, nicht lokal.** Die Workflows
`Build macOS Preview` und `Build Android Preview` erzeugen die Artefakte und
lassen sich auch von Hand starten (`workflow_dispatch`); lokal laufen nur
Analyse, Format und Tests.

### Android-Vorschau: der Signaturschlüssel

Ohne hinterlegten Schlüssel signiert Gradle jede Vorschau mit einem
Debug-Schlüssel, den der Runner neu erzeugt. Android lässt eine so signierte
App nicht über die vorige installieren — man muss deinstallieren, und damit
sind Einstellungen, gekoppelte Geräte und der Gerätename weg. Genau das ist
der Grund, warum das Handy nach jedem Build neu verbunden werden muss.

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

Die erste APK mit dem neuen Schlüssel muss noch einmal von Hand installiert
werden (die alte deinstallieren); ab dann geht jedes Update in place, und die
Kopplung bleibt.

Dasselbe gilt für die heruntergeladenen Medien. Sie liegen im App-Speicher
des Geräts — dort, wo auch die Kopplung liegt —, und Android räumt diesen
Ordner beim Deinstallieren restlos ab. Solange jede Vorschau neu signiert
wird, ist jede Installation eine Deinstallation, und die Offline-Kopien sind
danach weg. Mit hinterlegtem Schlüssel ist ein Update ein Update: Kopplung
und Offline-Kopien bleiben. Einen Ort, der eine Deinstallation überlebt, gibt
es unter Android nur außerhalb des App-Speichers — in den geteilten
Dokumenten, wo die Dateien für jede andere App sichtbar wären; das wäre für
eine Mediathek der falsche Tausch.
