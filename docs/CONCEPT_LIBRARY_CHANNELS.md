# Bibliotheks-Sender und lineares Programm

## Ziel

Fundus soll aus vorhandenen Bibliotheksinhalten selbst definierte lineare
Fernsehsender erzeugen können. Ein Sender ist keine neue Kopie der Medien,
sondern eine reproduzierbare Programmregel über den bestehenden Katalog.

Beispiele:

- `Retro Horror`: Genres Horror, Grusel oder Spannung; Erscheinungsjahr
  1980–1989.
- `Anime-Abend`: ausgewählte Anime-Bibliotheken; zwei Folgen derselben Serie
  am Stück, danach Wechsel zu einer anderen Serie.
- `Samstagskino`: nur Filme; feste Startzeit; nach jedem Film ein optionaler
  Retro-Werbeblock.

## Senderdefinition

Ein Sender benötigt mindestens:

- Name, Logo/Farbe und Sichtbarkeit;
- erlaubte Bibliotheken und Medienordner;
- Ein- und Ausschlussregeln für Medientyp, Genre, Tags, Personen, Rollen,
  Erscheinungsjahre, Altersfreigabe, HHH-/Schutzstatus und eigenen Status;
- Regeln für Reihen und Serien: Anzahl aufeinanderfolgender Teile, erlaubte
  Staffeln, Staffelreihenfolge, chronologisch/zufällig und Wiederholsperre;
- Sortierung und Mischung, etwa gewichtet nach Genre, Alter oder noch nicht
  gesehen;
- Tages-/Wochenzeiten sowie optional feste Programmplätze;
- Verhalten bei Lücken, nicht erreichbaren Dateien und ausgeschöpften Regeln.

## Programm und Wiedergabe

- Fundus erzeugt für einen festgelegten Horizont einen Programmlauf und hält
  ihn stabil. Ein erneutes Öffnen desselben Senders zeigt deshalb dasselbe
  laufende Programm statt eine neue Zufallsfolge.
- Der Einstieg erfolgt wahlweise „live“ an der aktuellen Stelle oder am
  Anfang der laufenden Sendung.
- Fortschritt und Bewertungen gehören weiterhin zum abgespielten Werk bzw.
  zur Folge, nicht zum Sender.
- Nicht mehr zugelassene, geschützte oder nicht erreichbare Inhalte werden vor
  der Wiedergabe erneut geprüft und sicher übersprungen.

## Zwischenblöcke und Retro-Modus

Zwischenblöcke sind eigene, optionale Regeln. Sie können lokale Trailer,
Jingles, Sendertrenner oder selbst bereitgestellte Werbeclips enthalten. Die
Häufigkeit kann nach Zeit, Anzahl von Folgen oder Sendungswechseln festgelegt
werden. Fundus lädt keine fremde Werbung nach und spielt nichts außerhalb der
vom Nutzer ausgewählten Bibliotheksdateien.

## Geräte und Schutz

Sender respektieren dieselben Bibliotheks-, Geräte- und Schutzfreigaben wie
die normale Oberfläche. Ein gesperrtes Gerät darf weder im Programmplan noch
über direkte Wiedergabe an ausgeblendete Inhalte gelangen. Senderdefinitionen
können synchronisiert werden; die konkrete Abspielfreigabe wird weiterhin am
Server geprüft.

## Vorgeschlagene Umsetzung

1. Datenmodell für Sender, Filterregeln und Serienrotation.
2. Vorschau „Welche Titel trifft diese Regel?“ mit erklärbaren Treffern und
   Ausschlüssen.
3. Deterministischer Programmplan ohne feste Uhrzeiten.
4. Senderbereich in Desktop und Mobile mit Live-/Von-vorn-Einstieg.
5. Zeitplan und feste Programmplätze.
6. Zwischenblöcke, Jingles und Retro-Werbung.
7. Export/Import von Sendervorlagen.

