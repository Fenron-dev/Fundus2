# Fundus2 — Arbeitsanweisungen

Lokale, portable Medienbibliothek für Desktop und Android. Die Desktop-App ist
zugleich Server im Heimnetz; Android greift darauf zu, lädt Inhalte für
unterwegs herunter und gleicht den Fortschritt zurück. Kein Cloud-Dienst.

## Niemals lokal bauen

**Gebaut wird ausschließlich in GitHub Actions — nie lokal.** Der
Flutter-Buildordner belegt dauerhaft Plattenplatz, den diese Maschine nicht
hat. Verboten sind daher `flutter build`, `flutter run`, `pod install`,
Gradle-Aufrufe und jeder Xcode-/MSBuild-Start. Auch nicht „nur zum Prüfen".

Lokal erlaubt und vor jedem Push verpflichtend:

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

Artefakte erzeugen die Workflows `Build macOS Preview`, `Build Windows Preview`
und `Build Android Preview` (`workflow_dispatch` möglich). Wenn eine Änderung
nur im echten Build überprüfbar ist, wird das gesagt und der Workflow
angestoßen — nicht lokal kompiliert.

## Workspace

| Ordner | Inhalt |
|---|---|
| `app/` | Flutter-Client für macOS, Windows, Linux und Android |
| `packages/core/` | Datenmodell, SQLite-Index, Scanner, Import, Publication Engine |
| `packages/client/` | Kopplung, Katalogspiegel, Sync-Journal, Stream-Proxy |
| `packages/server/` | Eingebetteter Shelf-Server für das lokale Netz |
| `packages/design/` | Nocturne als Flutter-Theme: Tokens und geteilte Komponenten |
| `legacy/app/` | Der bisherige Client als Referenz — kein Workspace-Mitglied, nicht ändern |

## Die zwei Leitsätze

**Ansicht ≠ Ablage.** Ordner sind eine Ansicht auf dieselben Dateien, nicht die
Wahrheit. Jeder Bereich hat einen „Ordnen nach"-Umschalter; Filter gelten in
jeder Ansicht, auch im Ordnermodus.

**Herkunft ist eine Eigenschaft des Werks, keine Ansicht.** Lokal, Stream,
offline gesichert, nicht erreichbar und im Archiv sind Werte einer Spalte, kein
Zweig im Widget-Baum. Daraus folgt: eine Bibliotheksansicht, ein
Player-Controller, ein Satz gespeicherter Ansichten; „offline verfügbar" ist
ein Filter, kein eigener Bereich.

## Leitplanken

- **Nichts doppelt bauen.** Hätte eine neue Datei ein Gegenstück mit `remote_`
  oder `local_` im Namen, ist der Entwurf falsch. Treffer nur in Gateways und
  Byte-Quellen, nie in einer Datei, die Oberfläche baut.
- **Kein Netz im Scrollpfad.** Die UI liest ausschließlich aus der lokalen
  `index.db`.
- **Fortschritt und Metadaten nie in einer Transaktion.** Ein
  Metadaten-Abgleich fasst Positionen, Notizen und Lesezeichen nicht an.
- **HHH gilt auch für Sync und Journal.** Geschützte Werke erzeugen keine
  Journaleinträge für ungekoppelte Geräte, erscheinen nicht im Katalog-Delta an
  nicht freigeschaltete Geräte und nicht in Protokollen.
- **Archive nie schreiben, nie automatisch entpacken.**
- **Leerzustände nennen ihre Ursache** — „keine Treffer" ohne Hinweis auf den
  aktiven Filter ist eine Sackgasse.
- **Virtualisierung von Anfang an** — rund 12 000 Werke und 4 000 Fotos sind der
  Maßstab; Zähler in der Navigation sind Aggregate.
- **Kein Hex, keine rohe Pixelzahl in `app/lib`** — alles über `packages/design`.
- **Jede Schemaänderung hat eine Migration und einen Test von der Vorversion.**
- **Jeder neue Medientyp ist Konfiguration**, kein neuer Bildschirm.
- **Deutsch in der Oberfläche, Englisch im Code.**

## Sicherheit

- **Nichts Vertrauliches ins Repo.** `Fenron-dev/Fundus2` ist öffentlich. Keine
  Konzept- oder Designunterlagen, keine Schlüssel, Tokens oder Zertifikate.
  Signaturmaterial ausschließlich als GitHub-Secret. Vor jedem Push ein Blick
  auf neu hinzugekommene Dateien.
- **Geheimnisse gehören in `flutter_secure_storage`** — Peer-Tokens,
  API-Schlüssel und Schutz-PIN. `device.json` trägt nur unkritische Präferenzen.
- **Kein TLS-Bypass.** Kein Ignore-TLS-Flag, kein „akzeptiere alles".
  Peer-TLS nutzt bewusst `badCertificateCallback` — aber ausschließlich als
  Fingerprint-Pinning gegen den Wert aus dem Kopplungscode, mit
  `SecurityContext(withTrustedRoots: false)`. Metadaten-Abrufe laufen über
  `createMetadataHttpClient()`, unter Windows WinHTTP/Schannel mit
  Betriebssystem-Kettenprüfung. Unverschlüsseltes HTTP ist nur für den
  Loopback-Stream-Proxy und Testserver zulässig.

## Unterlagen

`Dokumentation/` steht in `.gitignore` und bleibt außerhalb des öffentlichen
Repos. Bei Widerspruch gilt:

**Code und `docs/REVIEW_2026-09.md` vor `Dokumentation/design/Fundus - Technik-Spezifikation.md`
vor `Fundus - Design-Handoff.md` vor `UMSETZUNGSPLAN.md` vor `KONZEPT*.md`.**

Der `UMSETZUNGSPLAN.md` hat den Stand 2026-09-02 und ist in seiner
Fortschrittstabelle überholt; `docs/REVIEW_2026-09.md` ist der laufend
gepflegte Wartungsstand und wird bei jeder größeren Änderung fortgeschrieben.
