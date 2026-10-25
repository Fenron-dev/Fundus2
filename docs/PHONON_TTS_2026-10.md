# Phonon-TTS im Textreader – Arbeitsstand

Issue [#64](https://github.com/Fenron-dev/Fundus2/issues/64) ergänzt die
bereits freigegebene Roadmap, ersetzt oder schließt sie aber nicht. Diese Datei
trennt implementierte Grundlage von noch nicht ausgelieferter Sprachausgabe.

## Ziel und Fortschrittsvertrag

Ein Buch oder Novel hat **einen textuellen Medienstand**, gleichgültig ob der
letzte Abschnitt gelesen oder gehört wurde. Er enthält Datei, Kapitel,
Absatzanker und normalisierten Zeichen-Offset. Ein Audio-Zeitstempel wäre kein
dauerhafter Buchstand: Stimme, Tempo, Aussprache und Textregeln ändern seine
Zuordnung zum Text. Geräte behalten ihre eigenen Stände und bestehende
Konfliktentscheidungen; TTS darf keinen fremden Stand automatisch übernehmen.

Die Sprachausgabe wird in kurze Abschnitte mit Originaltext-Anfang und -Ende
aufgeteilt. Nur ein **vollständig vom Audio-Ausgabegerät abgespielter**
Abschnitt darf den Stand bis zu seinem Ende verschieben. Synthese,
Vorausladen und Audio-Queueing allein zählen nicht als gehört. Beim Pausieren,
Stoppen, Verlassen und Weglegen der App muss der letzte tatsächlich gehörte
Stand über den bestehenden Fortschritts-Checkpoint gesichert werden. Eine
veränderte Absatz-ID wird kenntlich gemacht; falsche Datei-/Kapitelanker oder
veraltete Segmente dürfen einen neueren Lesestand nicht überschreiben.

## Implementiert in diesem Zwischenschritt

- `SpeechTextPlan` zerlegt den unveränderten Text eines Reader-Kapitels in
  begrenzte, satzorientierte Segmente. Jeder Abschnitt trägt Original-Offsets
  und Fundus-Medienpositionen. Der Einstieg aus einer Leseposition wiederholt
  höchstens den begonnenen Satz, statt ein Wort abzuschneiden.
- Der Textreader bietet den Plan für die aktuelle Stelle an. Er akzeptiert
  einen abgespielten Abschnitt nur aus dem weiterhin geöffneten Kapitel und
  nur wenn dessen Originaltext noch passt und dessen Ende vorwärts führt.
  Ein separater Checkpoint verwendet den bestehenden Lesestand/Journaleintrag.
- Core- und Reader-Tests prüfen Einstieg, Abkürzungen, lange Absätze,
  Unicode-Zeichengrenzen, geänderte Anker, falsche Kapitel,
  Synthese ohne Fortschrittsänderung,
  bestätigtes Abspielen, Wiederöffnen und veraltete Abschnitte.

**Noch nicht implementiert:** Phonon-Bindings, tatsächliche Audioausgabe,
Vorlese-UI, Modellverwaltung, Stimmen, Textregeln, Hintergrundwiedergabe und
Geräte-Laufzeittests. Dieser Schritt ist ausdrücklich noch nicht benutzbar.

## Engine- und Datenschutzentscheidung für die nächsten Schritte

Das eigenständige Phonon-Studio nutzt Python/`ptts`, Kapitel-WAV und m4b-Export.
Für Fundus ist ein Python-Server im Client weder für Android geeignet noch für
eine schnelle Reader-Umschaltung nötig. Stattdessen soll die native
`ptts-ffi`-Schnittstelle kurze PCM-Abschnitte auf einem Worker erzeugen und
streamen. Android braucht eine geprüfte ARM64-CPU-Bibliothek; das optionale
Snapdragon-NPU-Paket ist kein allgemeiner Ersatz. Die aktuelle Android-Anleitung
des Herstellers bezeichnet das direkte Flutter-FFI-Binding noch als ungetestet;
ein GitHub-Build ist daher keine Geräteabnahme.

Sprachmodelle werden nicht in das öffentliche Git-Repository gelegt und nicht
ohne Nutzerwahl installiert. Modell, Stimme und Audio-Cache sind gerätelokal;
der Buchtext wird nicht an einen Cloud-TTS-Dienst gesendet. Der Cache ist
begrenzt und wird ohne Löschen von Originalmedien bereinigt. Die 40m-Modelle
haben eine nichtkommerzielle Lizenz; Weitergabe, Attribution und
Download-Herkunft müssen vor einem Release gesondert geklärt werden.

Die nächste Implementierungsfolge ist: native Engine-Abstraktion und
GitHub-Builds, Modellinstallation mit Integritätsprüfung, Audioausgabe samt
Fokus/Unterbrechung und Reader-Steuerung, dann Aussprache/Textregeln und
Akku-/Laufzeittest auf echtem Android-Gerät. Der bereits vorhandene
`audio_service`-/`audio_session`-Pfad darf nicht mit einer zweiten,
gleichzeitig spielenden Fundus-Audiositzung konkurrieren.
