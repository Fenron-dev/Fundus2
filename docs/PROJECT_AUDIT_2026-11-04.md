# Projektprüfung Fundus2 – 04.11.2026

## Nachtrag 22.11.2026 – Umsetzung der priorisierten Befunde

Die folgenden Änderungen wurden nach diesem historischen Prüfstand umgesetzt.
Die Fehlerbeschreibungen weiter unten beziehen sich ausdrücklich auf Commit
`45bb2f6`, nicht auf den Stand nach diesem Nachtrag.

| Befund | Korrektur | Nachweis/Grenze |
| --- | --- | --- |
| Windows-Player | `demuxer=auto` und ungültiger `demuxer-lavf-probesize=0` entfernt; normale Medien setzen den Demuxer auf automatische Erkennung zurück. Native Playerfehler werden als sichtbarer Wiedergabefehler behandelt. | Controller-Regression und Windows-nativer GitHub-Smoke-Test für Wiedergabe nach `rawaudio` ergänzt; echtes Video auf dem betroffenen Windows-PC und Wechsel Video → TTS → Video bleiben Geräteabnahme. |
| Schutz-PIN | Bestehende Schutzkonfiguration lässt sich nur nach PIN-/Plattform-Authentifizierung ändern oder entfernen; gesperrte Bedienelemente sind in Einstellungen deaktiviert. | Controller-Regression vorhanden; Widget-/Geräteabnahme bleibt offen. |
| Geräteentzug | Persistenz aller Gerätesnapshots einschließlich Präsenz ist serialisiert; Entzug wartet auf vorangegangene Schreibvorgänge. Datei wird erst vollständig als temporärer Snapshot geschrieben; Windows verwendet jetzt `MoveFileExW` statt eines direkten Schreib-Fallbacks. Fehlgeschlagene Snapshots werden im Wartungstakt erneut versucht. | Verzögerter-Präsenz- und fehlgeschlagener-Entzug-Regressionstest vorhanden; Windows-nativer Replace-Test im Build-Workflow. Ein echter Stromausfall-/Dateisystemtest und mehrtägiger Betrieb stehen noch aus. |
| TTS-Fortschritt/EOF | Keine Fortschrittsbuchung mehr aus Stoppuhr oder `playing`-Status; nur gemeldete Audioposition zählt. Vorzeitiges EOF löst den blockierten Producer, meldet einen Fehler und belässt unbestätigten Text ungelesen. Bei ausbleibender Position und vollem Puffer wird nach zehn Sekunden abgebrochen. | Erfolgs- und vorzeitiger-EOF-Test vorhanden; tatsächliche Windows-PCM-Positionsmeldungen müssen im Build/Gerät geprüft werden. |
| Native Logs | Das Feld `message` wird zentral wie ein Fehlertext bereinigt, sodass native Pfade/Token nicht exportiert werden. | Log-Regression vorhanden. Die Bereinigung opfert Freitext-Details; Diagnosecode und Level bleiben erhalten. |

Diese Korrekturen sind keine Freigabe für einen stabilen Release. Die unter
„Verbleibende Architektur- und Sicherheitsgrenzen“ genannten größeren Arbeiten
bleiben offen, insbesondere die Entkopplung synchroner Netzwerk-/DB-Arbeit
vom UI-Isolate und native Dauerlauftests. Die Windows-Gerätepersistenz ist
seit dem Nachtrag vom 22.11.2026 gegen den direkten Schreib-Fallback
abgesichert; ein nativer Abbruchtest bleibt offen.

## Prüfstand und Ergebnis

Geprüft wurde Commit `45bb2f6160c6dca529acd30d34e9628e5849de84` auf
`claude/media-management-design-h84z84`, Datenbankschema 26. Der Arbeitsbaum
war zu Beginn sauber. Anwendungscode, reale Bibliotheken, Fortschritte,
Einstellungen und GitHub wurden nicht verändert. Neu ist nur dieser Bericht;
zusätzliche Reproduktionen verwendeten isolierte temporäre Testdaten.

**Die Funktionsbasis ist umfangreich, der Stand ist aber nicht als stabil
abgenommen.** Es gibt einen konkreten Fehler in der gemeinsamen
Playerkonfiguration, der zur gemeldeten schwarzen Windows-Videowiedergabe
passt, zwei Zugriffsschutzprobleme und weitere TTS-/Datenschutzfehler.
Grüne Unit-Tests und erfolgreiche Builds schließen diese Fehler nicht aus.

Prioritäten: P1 vor der nächsten stabilen Veröffentlichung, P2 anschließend.
Dies sind Entwicklungsprioritäten, keine CVSS-Bewertungen.

## Verifikation und Grenzen

| Prüfung | Ergebnis |
| --- | --- |
| Statische Analyse | Keine Befunde |
| Formatprüfung | 337 Dateien, keine Änderungen notwendig |
| Core | 360 Tests erfolgreich |
| Server | 48 Tests erfolgreich |
| Client | 49 Tests erfolgreich |
| Design | 3 Tests erfolgreich |
| App | 556 erfolgreich, 8 übersprungen |
| Zusätzliche Fehlerreproduktionen | 5 Szenarien bestätigen die unten beschriebenen Fehler |
| OSV-Paketprüfung | 160 gehostete Pub-Pakete aus der Lockdatei, keine zugeordneten Advisories |

Insgesamt 1.016 bestehende Tests erfolgreich. Die fünf zusätzlichen Tests
prüfen ausdrücklich, ob sich die problematischen Zustände herstellen lassen;
ihr Bestehen bedeutet **nicht**, dass die Probleme behoben sind.

Temporäre Reproduktion: `/tmp/fundus_audit_20261104_test.dart`;
Ergebnisse: `/tmp/fundus-audit-probes-20261104.log`. Diese Dateien sind keine
eingecheckten Regressionstests. Alle Test-Vaults wurden nur für diese Prüfung
angelegt und anschließend entfernt.

Die zuletzt geprüften Vorschau-Builds desselben Commits sind erfolgreich:
[Windows](https://github.com/Fenron-dev/Fundus2/actions/runs/40233902084),
[macOS](https://github.com/Fenron-dev/Fundus2/actions/runs/40233901988),
[Android](https://github.com/Fenron-dev/Fundus2/actions/runs/40233902263).
Der Windows-Workflow prüft native HTTPS-Abrufe, aber keine echte Videoausgabe.
Die Player-Controller-Tests verwenden überwiegend `FakeEngine`.

Kein lokaler App-Build wurde erzeugt. Echte Windows-Ausgabe, SMB-Ausfälle über
mehrere Tage, Android-Standby/Akku und hörbare TTS-Qualität konnten auf dieser
macOS-Prüfumgebung nicht abgenommen werden. Es lag kein neues Windows-Log vor.
Die Untersuchung ist eine gezielte querschnittliche Code-/Testprüfung, keine
vollständige formale Verifikation oder ein unabhängiger Penetrationstest.

Die [OSV-Abfrage](https://google.github.io/osv.dev/post-v1-querybatch/) erfasst
bekannte Meldungen für die angegebenen Pub-Paketversionen. Sie deckt nicht
automatisch alle eingebetteten mpv-/FFmpeg-/PDFium-/Rust-Komponenten ab.

## P1 – Normale Medien erhalten eine ungültige Playerkonfiguration

**Codefehler bestätigt; sehr starke Übereinstimmung mit dem gemeldeten Symptom.
Ein Lauf auf dem betroffenen Windows-PC steht noch aus.**

In `app/lib/media/playback_engine.dart:354` setzt jeder Nicht-PCM-Aufruf
`demuxer=auto`. Bei mpv bedeutet `demuxer` jedoch einen erzwungenen
Formatleser-Namen; `auto` ist kein solcher Name. Automatische Erkennung wird
durch eine leere Vorgabe ermöglicht, nicht durch diesen Textwert. Sowohl der
[mpv-0.36-Quelltext](https://github.com/mpv-player/mpv/blob/v0.36.0/demux/demux.c#L3154-L3169)
als auch der geprüfte aktuelle Quelltext verwerfen unbekannte Namen.

Zusätzlich wird in Zeile 371 `demuxer-lavf-probesize=0` gesetzt. Die geprüfte
[mpv-Option](https://github.com/mpv-player/mpv/blob/v0.36.0/demux/demux_lavf.c#L83-L90)
verlangt mindestens 32. Ein ungültiger Reset kann nach TTS den dort gesetzten
kleinen Wert stehen lassen. `media_kit` 1.2.6 ignoriert im öffentlichen
`NativePlayer.setProperty` den nativen Rückgabecode.

Die gemeinsame Einstellung wurde im Zuge des TTS-Ausbaus eingeführt und
betrifft nicht nur Videos auf Netzwerkfreigaben, sondern auch normale lokale
Audio-/Videodateien. Der Manga-Reader verwendet diesen Player nicht.
Die gemeldete Kombination „Player schwarz, gespeicherte Zeit 7:25 sichtbar,
keine Wiedergabe; außerhalb von Fundus abspielbar“ passt deshalb sehr gut.
Eine Neuinstallation, Änderung der Medien oder ein Index-Neuaufbau ist daraus
nicht abzuleiten.

Weiteres Problem: `playback_engine.dart:156` protokolliert native Fehler nur.
`PlaybackEngine` reicht keinen Fehlerstrom an den Controller weiter;
`playback_controller.dart:888` behandelt ein zurückgekehrtes `open` bereits
als geladen. Ein asynchron gescheiterter Ladevorgang kann so ohne hilfreiche
Meldung auf schwarzer Fläche stehen bleiben.

**Korrektur:** PCM-spezifische Optionen von regulären Medien trennen,
gültige Ausgangswerte wiederherstellen, native Fehler als Playerzustand
weiterreichen und ein begrenztes Lade-/Fehlerverhalten einführen. Regressionen
für frischen Start sowie Video → TTS → Video und Audio → Video ergänzen.
Ein Windows-Nativtest muss eine kleine Testdatei tatsächlich laden und
fortschreitende Position/Dauer bzw. Videodekodierung bestätigen, nicht nur
kompilieren. Dazu ein manueller Test mit UNC-/Laufwerkspfad, Leerzeichen und
Unicode. Bezug: [#24](https://github.com/Fenron-dev/Fundus2/issues/24).

## P1 – HHH-Schutz lässt sich ohne bisherige PIN abschalten

**Durch Code und isolierten Controller-Test bestätigt.**

Die zugängliche Einstellungsseite setzt bei
`app/lib/features/settings/settings_screen.dart:2440` unmittelbar den
Schutzmodus. Die Aktionen bei Zeile 2493/2502 ersetzen bzw. entfernen die PIN,
ohne vorherige Authentifizierung. Auch die Methoden in
`app/lib/data/protection.dart:64` verlangen keine bestehende Freigabe.

Reproduktion: PIN setzen, Schutz sperren, `setMode(off)` aufrufen → Inhalte
sind freigegeben. Alternativ eine neue PIN setzen → Sitzung ist entsperrt,
ohne die vorherige PIN zu kennen. Die Oberfläche bietet genau diese Wege an.

Das betrifft jemanden, der die bereits geöffnete App bedienen darf, etwa beim
Zeigen des Telefons. Es ist kein anonymer Zugriff auf den Server. Die
serverseitige Geräte-Allowlist ist ein separater Schutz und wird dadurch nicht
automatisch aufgehoben. Der lokale Schutz ist zudem keine Dateiverschlüsselung.

**Korrektur:** Abschalten/Ändern einer bestehenden Schutzkonfiguration und
PIN-Wechsel/-Entfernung erfordern eine zuvor authentifizierte Sitzung. Die
Prüfung muss zentral gelten, nicht nur am sichtbaren Button. Erstmalige
Einrichtung ohne PIN bleibt möglich. Widget-Tests für den gesperrten Zustand
und alle betreffenden Einstellungsaktionen ergänzen.

## P1 – Geräteentzug kann durch eine ältere Speicherung zurückgenommen werden

**Mit kontrolliert verzögerter Persistenz reproduziert.**

`packages/server/lib/src/pairing.dart:246` startet die Speicherung einer
Präsenzaktualisierung unbeobachtet/asynchron. Entzug und Rechteänderungen
starten daneben weitere Speicherungen. Der produktive Callback
`app/lib/data/server_host.dart:848` ruft direkt
`ServerIdentityStore.savePairedDevices` auf. Diese Methode schreibt bei
`app/lib/data/server_identity.dart:149` ohne Schreibqueue und ohne atomaren
Austausch in dieselbe Datei.

Reproduktion: Ein bereits gültiges Testgerät verursacht eine verzögerte
Präsenzspeicherung. Anschließend wird es entzogen und der leere Gerätestand
gespeichert. Danach endet die ältere Speicherung. Nach erneutem Laden der
Datei wird das alte Testtoken wieder akzeptiert. Während des Entzugs im
laufenden Prozess bleibt es dagegen abgewiesen.

Dies belegt ein Reihenfolgeproblem, nicht dass ein bestimmter realer
Geräteentzug bereits verloren ging. Voraussetzung ist ein zuvor gültiges
Token und eine überholende Speicherung; es werden keine neuen Token erraten.
Auch Rechteänderungen und beschädigte Dateien bei Abbruch sind betroffen.

**Korrektur:** eine serialisierte, revisionsbewusste und atomare
Persistenzstrecke für Präsenz, Kopplung, Rechteänderung und Entzug;
Schreibfehler sichtbar behandeln. Die UI darf einen Entzug erst als dauerhaft
bestätigen, wenn er gesichert ist. Überholung/Abbruch/Neustart testen.

## P1 – TTS kann ungehörten Text als gelesen speichern

**Durch isolierten Test bestätigt.**

`app/lib/media/text_speech_controller.dart:594` startet eine Stoppuhr, sobald
der Player `playing` meldet. Zeile 623 verwendet das Maximum aus gemeldeter
Audioposition und geschätzter Zeit für den echten Lesestand. `playing` beweist
aber keine Audioausgabe: die Engine kann laden, puffern oder hängen. Ein
Sicherheitsabstand von 500 ms ist dafür kein Nachweis.

Im Test konsumiert die Engine kein einziges Audiobyte und meldet Position 0.
Nach drei Sekunden springt der Reader trotzdem von `(Absatz 0, Offset 0)`
auf `(Absatz 2, Offset 1)`. Außerdem wird die gesamte bisherige Laufzeit mit
dem jeweils aktuellen Tempo multipliziert: eine spätere Tempoerhöhung wirkt
damit rückwirkend auf den geschätzten Stand.

**Korrektur:** Pufferfreigabe und dauerhaft bestätigten Lesestand trennen.
Nur eine belastbare Ausgabeposition darf Text als gehört bestätigen; bei
unklarer Position konservativ am letzten bestätigten Abschnitt bleiben.
Tempoänderungen, lange Pufferpausen, Audiofokus und Stop/Resume testen.
Die Zusicherungen in `docs/PHONON_TTS_2026-10.md` zur Fortschrittsgarantie
sind für diesen Stand zu weitgehend und müssen bei der Korrektur angepasst
werden. Bezug: [#64](https://github.com/Fenron-dev/Fundus2/issues/64),
[#65](https://github.com/Fenron-dev/Fundus2/issues/65).

## P1 – Vorzeitiges TTS-Audioende lässt die Produktion unbegrenzt warten

**Durch isolierten Test bestätigt.**

Nach Ende von `playSpeechFile` wird der Fortschrittstimer beendet und bei
`text_speech_controller.dart:651` auf den Producer gewartet. Dieser kann
gleichzeitig in `app/lib/media/speech_audio_buffer.dart:80` auf Platz in der
Vier-Abschnitt-Queue warten. Ohne weitere Wiedergabe wird dieser Platz nicht
mehr frei; `buffer.dispose()` steht erst hinter dem Warten im `finally`.

Der Test meldet vorzeitiges Audioende bei vier gepufferten Abschnitten:
keine laufende Sprachausgabe mehr, aber weiterhin vier Einträge, kein
Fehler und kein Abschluss der TTS-Sitzung. Stoppen löst den Zustand.
Das ist ein nachvollziehbarer Hängepfad; ob er den früheren konkreten
Windows-TTS-Abbruch ausgelöst hat, ist ohne passendes Log nicht bewiesen.

**Korrektur:** normales Ende erst bei abgeschlossenem Producer und verbrauchter
Queue akzeptieren. Bei unerwartetem EOF Produktion abbrechen, wartende Gates
freigeben, letzten bestätigten Stand erhalten und Wiederaufnahme/Fehler
anbieten. Kein unbegrenztes Warten auf einen Producer ohne Konsumenten.

## P2 – Native Playerfehler umgehen die Protokollbereinigung

**Durch isolierten Test bestätigt.**

`playback_engine.dart:153/157` schreibt fremden Freitext unter `message`.
`app/lib/app/fundus_log.dart:189` bereinigt bekannte Titel-/Pfad- und
Fehlerfelder, aber nicht `message`. Eine synthetische native Meldung mit
privatem Windows-Pfad erscheint unverändert im exportierbaren Log.
Native Lese-/HTTP-Fehler können Dateinamen, geschützte Titel und URLs enthalten.

**Korrektur:** native Meldungen strukturiert klassifizieren und Freitext
zentral bereinigen. Diagnosecode/Subsystem erhalten; private Pfade und
URL-Geheimnisse nicht übernehmen. Tests müssen auch native `message`-Felder
abdecken, nicht nur das bereits bereinigte Feld `error`.

## Verbleibende Architektur- und Sicherheitsgrenzen

- **Dauerbetrieb/SMB:** Recovery und revisionsabhängige Katalogcaches sind
  vorhanden. Der alte 30-Sekunden-Neuaufbau ist nicht mehr der aktuelle Stand.
  Serverhandler und synchrone SQLite-Zugriffe laufen aber weiterhin auf dem
  UI-Isolate. Der periodische Health-Probe und `/health` sind seit 2026-11-22
  davon ausgenommen: der Probe läuft nur lesend in einem befristeten Worker,
  die Route nutzt den gemerkten Zustand. Der kalte Katalogindex gibt nach 32 Werken,
  Katalogseiten nach 16 Werken den Event-Loop frei und vermeiden wiederholte
  Revisionsabfragen je Werk. Änderungen verwerfen weiterhin den gesamten
  Hashcache. Langsame einzelne Netz-I/O/DB-Sperren können Oberfläche und
  Server gemeinsam blockieren. Ein Dart-Timeout kann eine bereits laufende
  synchrone DB-Operation nicht unterbrechen. Worker/Prozess und lokale
  Arbeitsindizes sind der nachhaltige nächste Schritt, kein weiterer schneller
  Polling-Timer. Aktuell keine neue SMB-Zeitmessung durchgeführt.
- **Mehrere schreibende Desktops:** Die SQLite-Datei liegt weiter im Vault.
  Eine exklusive Host-/Schreiberreservierung fehlt. Bis zu einem abgestimmten
  Verfahren nur einen schreibenden Host je Netzwerk-Vault verwenden.
- **Native Lieferkette:** Das tatsächlich aufgelöste Paket
  `media_kit_libs_windows_video` 1.0.11 lädt laut dessen `windows/CMakeLists.txt`
  einen mpv-Build vom 24.09.2023. Die Pub-Prüfung allein bewertet dessen
  Codecs nicht. Exakte native Versionen erfassen, Advisories separat prüfen
  und Aktualisierungen mit echter Wiedergabe testen. Hier wird keine
  bestimmte ungeprüfte CVE als nachgewiesene Schwachstelle behauptet.
- **Weitergabe/Backup:** Schutzmodus verschlüsselt weder Medien noch Index
  und Backups. Ein bereinigter Weitergabe-Assistent und getrennte Nutzerstände
  fehlen weiterhin (#17/#16). Vor Neuinstallation oder Index-Neuaufbau
  vollständiges Backup anlegen; `index.db` ist nicht nur entbehrlicher Cache.
- **Veröffentlichung:** Artefakte haben 90 Tage Aufbewahrung, aber keine
  dauerhafte Release-/Rollback-Strecke. macOS wird ad hoc signiert;
  Windows-Code-Signierung und eine native Laufzeitabnahme fehlen.

## Was bereits sinnvoll abgesichert ist

Die geprüften Pfade enthalten Zertifikat-Pinning für gekoppelte Geräte,
WinHTTP/Schannel ohne globalen TLS-Bypass, sichere Geheimnisspeicherung,
serverseitige Bibliotheks-/HHH-Freigaben, werkgebundene Annotationen und
beschränkte/validierte Modell- und Archivimporte. Peer-Kataloge werden nicht
ungefragt erneut freigegeben. Modelltransport überträgt keine nativen
Programme. CI-Actions sind auf Commit-IDs fixiert; Plattform-Builds hängen
von erfolgreicher CI ab. Die früheren Stabilisierungsarbeiten sind also
nicht pauschal wieder verloren.

Das schließt die oben neu nachgewiesenen Lücken nicht aus. Insbesondere wird
hier keine Aussage „vollständig sicher“ oder „problemloser Dauerbetrieb“
getroffen. Ein anonymer Zugriff auf Medien wurde in den geprüften
authentifizierten Serverrouten nicht nachgewiesen.

## Offene Funktionen – Code, Roadmap und Issues gemeinsam betrachtet

| Bereich | Aktueller Restumfang |
| --- | --- |
| TTS (#64/#65) | Fehler oben; echte Windows-/Android-Langzeitabnahme; mehrere Server-Sprachmodelle und getrennte Stimmenübertragung; Seed/Temperatur als echte Profileinstellungen statt fester nativer Werte |
| Intelligentes Offline-Mitnehmen (#55) | Implementierte Regeln/Downloads benötigen noch reale Android-Standby-/Akkuabnahme |
| Metadatenverlauf (#57) | Editor/Abgleich und Bildversionen vorhanden; automatische Scanänderungen noch nicht vollständig erfasst |
| Personen/Eigenschaften (#7) | Namensgleichheit wird weiterhin als Identität verwendet (`fundus_database.dart:4840/4998`); externe IDs, Zuordnungsdialog, vollständiger bidirektionaler Feld-/Löschkonfliktabgleich und Teile-Suche fehlen |
| Medienwelten (#60) | Beziehungen zwischen Reihen/Ausgaben und eigene Konsumreihenfolgen offen |
| Regelregale (#58) | Zusammengesetzte UND/ODER-Regeln und eigene Dashboard-Zeilen offen |
| Bibliotheks-Check (#59) | Geführte Lücken-/Dubletten-/Metadatenprüfung offen |
| Empfehlungen (#63) | Erklärbare, bewertungsbasierte lokale Vorschläge offen |
| Inhaltssuche (#62) | Volltextsuche über Buchinhalt, Notizen und Markierungen mit Direkteinstieg offen |
| Betriebsarten (#61) | Separate portable App/Server-Starts und ausdrücklich optionaler Dienst offen; kein automatisches Registrieren externer Archivplatten |
| Bibliotheks-TV (#25) | Konzept vorhanden, noch kein fertiger regelbasierter Senderbereich |
| Formate (#44) | CBR/7z und MOBI/AZW3 nicht durch einen Format-Hinweis zu intern lesbaren Formaten geworden |
| NovelUpdates | Browserprüfung nicht durch die Anmeldung im externen Browser gelöst; integrierter, ausdrücklich bestätigter Browser-/Importweg fehlt |
| Mehrnutzer/Weitergabe (#16/#17) | Getrennte persönliche Stände und bereinigte Bibliothekskopien offen |

Ein offenes Issue bedeutet nicht automatisch „gar nicht umgesetzt“:
Beispielsweise sind Action-Pinning/Dependabot (#34), begrenzte
Ordnerparallelität (#42) und Teile der Release-Anzeige (#46) bereits im Code.
Auch #57/#64 enthalten nicht vollständig nachgeführte Checklisten. Vor dem
Abhaken Code, Tests und Geräteabnahme getrennt festhalten; bestehende Issues
weiterverwenden statt alle alten Beschreibungen als neue Fehler anzulegen.

## Empfohlene Reihenfolge

1. **Abspiel-Hotfix:** gültige mpv-Konfiguration, sichtbare Playerfehler,
   automatisierter Windows-Nativtest. Dann erst einen neuen GitHub-Testbuild.
2. **Schutz und Datenerhalt:** gesperrte Einstellungen absichern,
   Geräte-Persistenz serialisieren, Logs bereinigen, TTS-Fortschritt und
   vorzeitiges Ende reparieren. Negative Regressionstests aufnehmen.
3. **Stabilitätsabnahme:** längere Windows-/SMB- und Android-Standby-Läufe,
   Netzwerkverlust/Wiederkehr, TTS-/Video-Wechsel und wiederholte Neustarts.
   Native Abhängigkeiten separat erfassen und prüfen.
4. **Betriebsqualität:** kompakte Zustands-/Diagnoseseite mit letztem
   erfolgreichen Abgleich, aktuellem Playerfehler und verständlicher
   Wiederherstellungsaktion; dauerhafte getestete Releases/Rollback.
5. **Danach Funktionsroadmap:** Metadatenverlauf vervollständigen,
   Bibliotheks-Check, Personenidentität und Teile-Suche priorisieren; weitere
   Regale, Inhaltssuche und Sender darauf aufbauen.

Für die Reparaturen ist keine Löschung der vorhandenen Medien oder
Fortschrittsdaten vorgesehen. Dieser Prüfauftrag enthält noch keinen Fix,
keinen Push und keinen neuen Build.
