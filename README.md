# Wand-Display Energiesteuerung

Steuerung für ein an der Wand montiertes Windows-Touchpanel, das dauerhaft eine
Seite anzeigt (hier: `https://strichliste.dpsg-franziskus.de/#/monitor`).

Ein Wochenplan legt fest, wann das Panel **an** ist. Außerhalb dieser Fenster
geht der Bildschirm aus und das Gerät in den Energiesparmodus; zum nächsten
Fensterbeginn wacht es von selbst wieder auf.

Rein zeitgesteuert: Die Einrichtung nimmt Touchscreen, Tastatur und Maus das
Weckrecht, eine Berührung holt das Panel außerhalb der Fenster also nicht aus
dem Energiesparmodus. Netzwerkadapter bleiben ausgenommen, damit Wake-on-LAN
weiter möglich ist (abschaltbar mit `-KeepDeviceWake`).

Standardplan:

| Tag | an ab | aus um |
| --- | --- | --- |
| Montag bis Donnerstag | 18:00 | 22:00 |
| Freitag | 17:00 | 02:00 (Samstag) |
| Samstag | 17:00 | 02:00 (Sonntag) |
| Sonntag | 16:00 | 23:00 |

Freitag und Samstag laufen über Mitternacht. Sonntag ist das Panel dadurch
zweimal an: 00:00–02:00 aus dem Samstags-Fenster und dann wieder ab 16:00.

Getestet für **Windows 10 IoT Enterprise** (funktioniert ebenso unter Windows 10
und 11 Pro/Enterprise).

Die **Systemsprache spielt keine Rolle**: Konten werden über SIDs angesprochen,
Energieoptionen über GUIDs, und die Schlafzustände werden über die Kennungen
`S0`–`S4` sowie die Struktur der Ausgabe erkannt, nicht über übersetzten Text.
Englisch, Deutsch und jede andere Sprache verhalten sich identisch. `-Action
Status` zeigt die erkannte Sprache rein zur Information an.

---

## Wie es funktioniert

Fünf geplante Aufgaben greifen ineinander:

| Aufgabe | Zeitpunkt | Konto | Zweck |
| --- | --- | --- | --- |
| `\WallDisplayPower\Sleep` | Fensterende | angemeldeter Benutzer | Bildschirm aus, danach Standby |
| `\WallDisplayPower\WakeTimer` | Fensterbeginn − 1 min | SYSTEM | holt das Gerät per Aufwachzeitgeber aus dem Standby |
| `\WallDisplayPower\Wake` | Fensterbeginn | angemeldeter Benutzer | Bildschirm ein, Ruhe-Aufgabe beenden |
| `\WallDisplayPower\Sync` | alle 5 bzw. 15 Minuten, dazu Systemstart | SYSTEM | Auslöser und Zustand mit dem Wochenplan abgleichen, mit Server zusätzlich den Zeitplan holen |
| `\WallDisplayPower\Kiosk` | Anmeldung, dann alle 5 Minuten | angemeldeter Benutzer | Strichliste im Vollbild starten, falls sie nicht läuft |

Warum diese Aufteilung:

- **Den Bildschirm abschalten** kann nur ein Prozess in der Sitzung des
  angemeldeten Benutzers. Eine Aufgabe als `SYSTEM` läuft in Sitzung 0 und
  erreicht das Panel nicht. Deshalb laufen `Sleep` und `Wake` als Benutzer.
- **Das Gerät aufwecken** ist dagegen als `SYSTEM` am verlässlichsten, weil der
  Aufwachzeitgeber dann unabhängig vom Zustand der Benutzersitzung gesetzt
  wird. `Wake` hat denselben Zeitgeber zusätzlich als zweite Absicherung.
- Die Auslösezeiten sind als **Ortszeit** eingetragen, nicht als UTC. Damit
  bleiben 22:00 und 06:00 auch nach der Zeitumstellung 22:00 und 06:00.
- **Die Anzeige selbst** startet die Aufgabe `Kiosk`: bei jeder Anmeldung und
  danach alle fünf Minuten als Nachkontrolle. Damit kommt die Strichliste nach
  einem Neustart von selbst zurück, auch wenn der Browser abgestürzt oder
  versehentlich geschlossen wurde. Läuft sie schon, tut die Aufgabe nichts.

### Das Sicherheitsnetz

Die Abgleich-Aufgabe `Sync` wird **immer** eingerichtet, auch ohne Server. Sie
vergleicht regelmäßig, ob das Panel gerade an oder aus sein soll, und zieht
nach. Das fängt jeden verpassten Auslöser auf:

- Stromausfall außerhalb der Fenster – das Gerät bootet um 23:00, der
  Sleep-Auslöser von 22:00 ist längst vorbei
- beim Fensterende war noch kein Benutzer angemeldet, die Sleep-Aufgabe konnte
  also nicht starten
- die Nacht der Zeitumstellung im März: die Ortszeit 02:00 gibt es nicht, der
  Auslöser für Freitag- und Samstagnacht zündet daher nicht

Dazu läuft der Abgleich **einmal beim Hochlaufen**, eine Minute nach dem Start,
damit die automatische Anmeldung durch ist. Ohne diesen Auslöser liefe das
Panel nach einem Neustart bis zum nächsten Wiederholungstermin im falschen
Zustand weiter – nach einem nächtlichen Update-Neustart also mit
eingeschaltetem Bildschirm.

Ohne dieses Netz würde das Panel in solchen Fällen bis zum nächsten Abend
durchlaufen, ohne dass es auffällt. Mit Server läuft der Abgleich alle 5
Minuten, ohne Server alle 15 – dort ist er nur Reserve und muss nicht so oft
laufen (`-PollMinutes` überschreibt beides).

Dieselbe Aufgabe hält auch die **Auslösezeiten** auf dem Wochenplan: Wurde
`config.json` von Hand bearbeitet, zieht sie die Aufgaben nach, sodass eine
Änderung ohne `Install.ps1` vollständig wirkt – siehe
[Zeiten nachträglich ändern](#zeiten-nachträglich-ändern).

### Betriebsmodi

- **`Combined`** (Standard): Bildschirm aus, nach 60 Sekunden Standby. Wacht das
  Gerät vor dem nächsten Fenster unerwartet auf (z. B. durch Windows-Wartung),
  schaltet es den Bildschirm sofort wieder aus und geht erneut in den Standby.
- **`DisplayOnly`**: nur Bildschirm aus, kein Standby. Das Gerät bleibt im Netz
  erreichbar, die angezeigte Seite bleibt geladen. Ein Wächter schaltet den
  Bildschirm alle 20 Sekunden erneut aus, damit Streu-Eingaben des
  Touchscreens ihn nicht wieder anschalten.
- **`SuspendOnly`**: ohne Vorlauf direkt in den Standby.

### Automatischer Rückfall

Nicht jede Hardware wacht per Zeitgeber verlässlich auf. Deshalb prüft die
Steuerung sich selbst:

- Vor dem ersten Standby wird geprüft, ob eine Aufgabe mit Aufwachzeitgeber
  existiert, ob Aufwachzeitgeber im Energieschema erlaubt sind und ob
  `powercfg /a` überhaupt einen Standby-Zustand meldet. Fehlt etwas, bleibt es
  bei **Bildschirm aus** – aber nicht endgültig: Die Nachkontrolle prüft alle
  5 Minuten, ob die Voraussetzung inzwischen erfüllt ist, und holt den Standby
  dann noch in derselben Nacht nach.
- Verweigert das Gerät den Standby, wird sofort auf `DisplayOnly` zurückgestuft.
- Wacht das Gerät mehr als 10 Minuten zu spät auf, zählt das als Fehlversuch.
  Nach 2 Fehlversuchen in Folge läuft die Steuerung dauerhaft in `DisplayOnly`
  weiter, damit das Panel morgens auf jeden Fall etwas anzeigt.
- Zurücksetzen nach einer Rückstufung: `WallDisplay.ps1 -Action Reset`.

---

## Steuerung von außen (optional)

Im Ordner `server/` liegt ein kleiner Docker-Dienst mit Weboberfläche. Dort
lassen sich Zeiten, Modus und Ausnahmen für jedes Panel einstellen; die Panels
holen sich das alle 5 Minuten ab und melden ihren Zustand zurück.

### Server starten

```bash
cd server && cp .env.example .env
```

In `.env` `PANEL_TOKEN` und `ADMIN_PASSWORD` durch Zufallswerte ersetzen, dann:

```bash
docker compose up -d --build
```

Der Container lauscht standardmäßig nur auf `127.0.0.1:8080`. Für den Zugriff
aus dem Netz einen Reverse-Proxy mit HTTPS davorsetzen (Caddy, nginx, Traefik)
und in `.env` `TRUST_PROXY=1` setzen – dann wird das Sitzungs-Cookie als
`Secure` markiert.

### Panel anbinden

```bash
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\Install.ps1 -ServerUrl https://panel.example.org -PanelId pfarrheim -ApiToken "<PANEL_TOKEN>"
```

Das Panel erscheint nach dem ersten Abruf automatisch in der Weboberfläche. Die
Zugangsdaten landen in `C:\ProgramData\WallDisplayPower\sync.json`, lesbar nur
für SYSTEM und Administratoren.

Ohne `-ServerUrl` arbeitet das Panel rein mit seiner lokalen `config.json`. Die
Abgleich-Aufgabe läuft dann trotzdem, fragt aber nichts ab – sie dient nur als
[Sicherheitsnetz](#das-sicherheitsnetz).

### Was sich einstellen lässt

- Wochenplan: je Tag an/aus mit Uhrzeiten, einzelne Tage abwählbar
- Modus
- Zeitplan aktiv / aus (`enabled`)
- **Wach bleiben bis** – einmalige Ausnahme, z. B. für eine Gruppenstunde
- **Jetzt aufwecken** – an bis zum Ende des laufenden bzw. nächsten Fensters
- **Jetzt schlafen** – aus bis zum Beginn des nächsten Fensters

### Letzte Abfrage vor dem Standby

Zusätzlich zum 5-Minuten-Takt fragt das Panel **unmittelbar vor dem
Einschlafen** noch einmal nach – also rund eine Minute vorher, wenn der
Bildschirm schon aus ist. Ohne das würde eine Änderung um 21:58 verschlafen,
wenn der letzte reguläre Abruf um 21:57 lief: danach ist das Gerät bis zum
nächsten Fenster nicht mehr erreichbar.

Kommt dabei ein neuer Wochenplan an, wird vor dem Standby geprüft, ob die
Aufwach-Auslöser auch wirklich dazu passen. Passen sie nicht, bleibt es bei
**Bildschirm aus** statt Standby – sonst würde das Panel zur alten Zeit
aufwachen.

Wacht das Gerät außerplanmäßig auf, fragt es vor dem erneuten Einschlafen
noch einmal nach, weil es in der Zwischenzeit jeden regulären Abruf verpasst
hat.

Diese Abfrage läuft über die Abgleich-Aufgabe als SYSTEM, denn die
Zugangsdaten sind absichtlich nur für SYSTEM und Administratoren lesbar und
das Ändern der Aufgaben-Auslöser braucht ohnehin erhöhte Rechte.

### Wann eine Änderung greift

Der Agent ist als *Zustandsabgleich* gebaut, nicht als reine Zeitsteuerung. Er
vergleicht bei jedem Abruf, ob das Panel gerade an sein soll oder nicht, und
zieht nach. Ein vorgezogener Fensterbeginn wirkt deshalb sofort beim nächsten
Abruf, ohne auf den nächsten Auslöser zu warten.

**Die eine Ausnahme:** Während das Panel im Standby liegt, kann es nichts
abfragen. Die Aufwach-Auslöser stehen dann noch auf den alten Zeiten.

- Fensterbeginn **nach hinten** verschoben: funktioniert auch im Schlaf. Das
  Panel wacht zur alten Zeit auf, merkt beim Abruf, dass es noch zu früh ist,
  und legt sich wieder hin.
- Fensterbeginn **nach vorne** gezogen: wirkt erst beim nächsten Aufwachen.
  Wer das sofort braucht, nutzt „Jetzt aufwecken" vorher oder Wake-on-LAN.

Fällt der Server aus, behält das Panel den letzten gültigen Zeitplan. Es gibt
bewusst keinen Rückfall auf „immer an" – das wäre genau der Zustand, der
vermieden werden soll.

### Sicherheit

Die Serverantwort entscheidet, wann ein Rechner schlafen geht. Der Agent
behandelt sie deshalb ausschließlich als Daten: jedes Feld wird gegen ein
festes Muster geprüft (Uhrzeiten, Modus und Befehle nur aus einer festen
Liste), unbekannte Felder werden verworfen, und es wird nichts aus der Antwort
ausgeführt – kein Pfad, kein Befehlstext, kein Skript. Ein ungültiges Feld
lässt den ganzen Abruf scheitern, dann bleibt der letzte gültige Zeitplan
gültig. `http` wird abgelehnt, solange nicht ausdrücklich `AllowInsecureHttp`
gesetzt ist.

Das Panel-Token ist für alle Panels gleich – das genügt, wenn der Server nicht
öffentlich erreichbar ist. Für mehr Trennung bräuchte es Token pro Panel; das
ist bewusst nicht gebaut, weil es die Einrichtung je Gerät verkompliziert.

### Server-Tests

```bash
cd server && npm install && npm test
```

---

## Fernwartung (optional)

Um sich aus der Ferne auf das Panel zu schalten, liegt in `rustdesk/` ein
selbst gehosteter RustDesk-Server. Das Panel baut nur **ausgehende**
Verbindungen auf – im fremden Netz braucht es damit weder eine Portfreigabe
noch Zugriff auf den Router.

### Warum RustDesk und nicht RDP

Remotedesktop würde die Konsolensitzung übernehmen: Das Panel an der Wand
zeigt dann den Sperrbildschirm statt der Strichliste, auch nach dem Trennen.
RustDesk teilt die **bestehende** Sitzung, die Anzeige bleibt also unberührt.

### Server starten

```bash
cd rustdesk && cp .env.example .env
```

In `.env` den öffentlich erreichbaren Namen eintragen, dann:

```bash
docker compose up -d
```

Diese Ports müssen von außen erreichbar sein:

| Port | Protokoll | Dienst |
| --- | --- | --- |
| 21115 | TCP | hbbs, NAT-Typ-Test |
| 21116 | **TCP und UDP** | hbbs, Anmeldung und Verbindungsaufbau |
| 21117 | TCP | hbbr, Relay |
| 21118 / 21119 | TCP | nur für den Web-Client, sonst zulassen weglassen |

Die UDP-Regel für 21116 wird am häufigsten vergessen – ohne sie funktioniert
der Verbindungsaufbau nicht.

Beim ersten Start erzeugt hbbs ein Schlüsselpaar in `./data`. Den öffentlichen
Schlüssel brauchst du für die Clients:

```bash
cat rustdesk/data/id_ed25519.pub
```

`-k _` ist in beiden Diensten gesetzt: ohne diese Angabe könnte jeder, der
Port 21117 erreicht, dein Relay als offenen Proxy mitbenutzen.

### Panel einrichten

RustDesk auf dem Panel installieren, dann unter *Einstellungen → Netzwerk*
eintragen:

- **ID-Server** und **Relay-Server**: dein Servername
- **Schlüssel**: Inhalt von `id_ed25519.pub`

Für unbeaufsichtigten Zugriff zusätzlich ein **festes Kennwort** setzen und
RustDesk als Dienst starten lassen, damit es auch ohne angemeldeten Benutzer
erreichbar ist.

Meldet sich das Panel danach beim Steuerungsserver, zeigt die Weboberfläche
seine RustDesk-Kennung samt Kopier-Knopf an – du musst sie dir also nicht
merken.

### Wach halten für die Wartung

In der Weboberfläche gibt es je Panel **„Für Wartung wach halten"** mit 30
Minuten bis 4 Stunden. Das Panel bleibt dann wach, der Bildschirm geht an,
danach gilt automatisch wieder der Zeitplan. **„Wartung beenden"** bricht es
vorzeitig ab.

**Die Einschränkung, die man kennen muss:** Liegt das Panel bereits im
Energiesparmodus, erreicht es kein Befehl – es ist schlicht aus. Das
Wartungsfenster greift dann erst, wenn das Gerät durch seinen
Aufwachzeitgeber von selbst hochkommt. Wer außerhalb der Fenster dran will,
setzt das Wartungsfenster also **vor** dem Fensterende. Im Modus `DisplayOnly`
entfällt das Problem, weil das Gerät durchläuft.

---

## Installation

> **Vollständige Schritt-für-Schritt-Anleitung:** [INSTALLATION.md](INSTALLATION.md)
> – inklusive BIOS, Autologon, Kiosk-Browser und Checkliste zum Abhaken.
> Die folgende Kurzfassung setzt voraus, dass das Panel bereits vorbereitet ist.

1. Den Ordner auf das Panel kopieren, z. B. nach `C:\Tools\WindowsEnergie`.
2. PowerShell **als Administrator** öffnen und einrichten:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\Install.ps1
```

Läuft das Panel unter einem eigenen Autologon-Konto, dieses mit angeben:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\Install.ps1 -UserId "PANEL-PC\kiosk"
```

`Install.ps1` erledigt dabei:

- Konfiguration samt Wochenplan nach
  `C:\ProgramData\WallDisplayPower\config.json` schreiben
- Bildschirm- und Standby-Zeitüberschreitungen auf „nie" setzen (die Steuerung
  übernimmt das selbst)
- Aufwachzeitgeber erlauben, Hybrid-Standby abschalten
- Ruhezustand abschalten, damit das Gerät wirklich in den Standby (S3) geht und
  nicht in den Ruhezustand (S4) – das schaltet gleichzeitig den Schnellstart ab
  (mit `-KeepHibernate` unterdrückbar)
- Touchscreen, Tastatur und Maus das Weckrecht nehmen, damit eine Berührung das
  Panel nachts nicht aus dem Standby holt; Netzwerkadapter behalten es (mit
  `-KeepDeviceWake` unterdrückbar)
- die Strichliste im Vollbild einrichten: Chrome startet bei jeder Anmeldung
  mit `--kiosk` (Adresse aus `KioskUrl`, mit `-KioskUrl` überschreibbar, mit
  `-NoKiosk` abschaltbar)
- die fünf Aufgaben registrieren

3. **Selbsttest ausführen** – das ist der entscheidende Schritt:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\src\WallDisplay.ps1 -Action SelfTest
```

Das Gerät geht für drei Minuten in den Standby und soll von selbst aufwachen.
Während des Tests nichts berühren. Danach steht im Klartext, ob der Modus
`Combined` tragfähig ist oder ob auf `DisplayOnly` umgestellt werden sollte.

---

## Konfiguration

`C:\ProgramData\WallDisplayPower\config.json`:

| Schlüssel | Standard | Bedeutung |
| --- | --- | --- |
| `Schedule` | siehe oben | Wochenplan: je Tag `{ "On": "HH:mm", "Off": "HH:mm" }` oder `null` |
| `Mode` | `Combined` | `Combined`, `DisplayOnly` oder `SuspendOnly` |
| `DisplayOffDelaySeconds` | `60` | Wartezeit zwischen Bildschirm aus und Standby |
| `WakePreRollMinutes` | `1` | Vorlauf des Aufwachzeitgebers vor dem Fensterbeginn |
| `WakeToleranceMinutes` | `10` | erlaubte Verspätung beim Aufwachen |
| `MaxWakeFailures` | `2` | Fehlversuche bis zum Rückfall auf `DisplayOnly` |
| `MinimumSuspendSeconds` | `30` | kürzerer „Standby" gilt als gescheitert |
| `MaxSuspendRetries` | `20` | Grenze für erneute Standby-Versuche je Ruhephase |
| `KeepDisplayOffIntervalSeconds` | `20` | Takt des Bildschirm-Wächters |
| `StandbyRetryProbeSeconds` | `300` | Takt, in dem der Wächter prüft, ob ein übersprungener Standby wieder möglich ist |
| `Enabled` | `true` | Zeitplan aktiv; `false` lässt das Panel durchlaufen |
| `KioskUrl` | Strichliste | Seite, die im Vollbild erscheint; leer = die Steuerung startet keinen Browser |
| `KioskBrowser` | leer | Pfad zu `chrome.exe`; leer = selbst suchen (Registry und übliche Verzeichnisse) |

Im Wochenplan gilt: Ist `Off` kleiner als `On`, reicht das Fenster über
Mitternacht in den Folgetag. Sind beide gleich oder steht statt des Eintrags
`null`, bleibt der Tag ganz aus. Mindestens ein Fenster muss übrig bleiben.

**Alle Tage aufführen**, die an sein sollen: Der Abschnitt `Schedule` wird als
Ganzes übernommen, nicht mit dem Standardplan gemischt. Ein fehlender Tag gilt
damit als aus.

### Zeiten nachträglich ändern

Die maßgebliche Datei ist `C:\ProgramData\WallDisplayPower\config.json` – nicht
die `config.json` im Projektordner. Die ist nur die Vorlage für die erste
Einrichtung und bleibt danach wirkungslos.

Nach dem Speichern passiert der Rest von selbst: Die Abgleich-Aufgabe merkt
beim nächsten Durchlauf, dass die Auslöser der Aufgaben nicht mehr zum Plan
passen, und zieht sie nach – spätestens nach 15 Minuten, ohne Server, ohne
`Install.ps1`. Sie läuft als SYSTEM und hat die dafür nötigen Rechte. Im
Protokoll steht dann:

```
[INFO] Wochenplan wurde oertlich geaendert (Mo-Do 19:00-22:30, ...), die Aufgaben-Ausloeser werden nachgezogen.
[INFO] Ausloeser passen wieder zum Wochenplan, der Standby ist damit moeglich.
```

Ob es geklappt hat, zeigt `-Action Status` in der Zeile
„Ausloeser passen zum Wochenplan". Steht dort **NEIN**, schaltet das Panel nur
den Bildschirm aus und geht nicht in den Standby – so ist es gewollt, denn mit
veralteten Auslösern würde es zur falschen Zeit aufwachen. Gelingt das
Nachziehen dreimal nicht (etwa weil eine Aufgabe fehlt), steht das als `ERROR`
im Protokoll und `Install.ps1` muss von Hand laufen.

Das gilt auch, wenn die Änderung mitten in den Fensterwechsel fällt: Hat das
Panel den Standby schon übersprungen und hält nur den Bildschirm aus, prüft es
alle 5 Minuten nach und legt sich noch in derselben Nacht hin, sobald die
Auslöser passen. Es kostet also keine Nacht mehr, kurz vor Feierabend noch die
Zeiten zu ändern.

Mit angebundenem Server werden `Schedule`, `Mode` und `Enabled` bei jedem
Abruf überschrieben – dort ist der Server die Quelle, und eine örtliche
Bearbeitung ist nach wenigen Minuten wieder weg. Zeiten also in der
Weboberfläche ändern.

---

## Betrieb und Fehlersuche

Status mit Konfiguration, Zustand, Aufgaben und den letzten Protokollzeilen:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\src\WallDisplay.ps1 -Action Status
```

Ausführliche Analyse (`powercfg /a`, `/waketimers`, `/lastwake`, `/requests`,
armierte Geräte, Ereignisprotokoll):

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\src\WallDisplay.ps1 -Action Diagnose
```

Weitere Aktionen: `-Action DisplayOff`, `-Action DisplayOn`, `-Action Kiosk`,
`-Action Reset`.

Protokoll: `C:\ProgramData\WallDisplayPower\walldisplay.log`

### Typische Ursachen, wenn das Gerät nicht aufwacht

- **BIOS/UEFI**: „Wake on RTC" bzw. „RTC Alarm" muss aktiv sein, „ErP Ready"
  oder „Deep Sleep" müssen aus sein. Beides kappt sonst die Stromversorgung so
  weit, dass kein Zeitgeber mehr zündet.
- **Modern Standby (S0)**: Zeigt `powercfg /a` „S0 Low Power Idle", ist das
  Verhalten stark geräteabhängig. Hier ist der Selbsttest Pflicht; im
  Zweifelsfall `DisplayOnly` verwenden.
- **Gruppenrichtlinie**: Setzt eine Richtlinie „Aufwachzeitgeber zulassen" auf
  deaktiviert, überschreibt sie die Einstellung von `Install.ps1`. Der Status
  zeigt das als „DEAKTIVIERT" an.
- **Ruhezustand aktiv**: Geht das Gerät in S4 statt S3, dauert das Aufwachen
  lange und die Sitzung kann wegbrechen. `Install.ps1` schaltet ihn deshalb ab.

### Wenn das Panel nachts von selbst aufwacht

`-Action Status` zeigt unter „Weckberechtigte Geräte", wer das Gerät aus dem
Standby holen darf. Steht dort ein Touchscreen, eine Tastatur oder eine Maus,
hat das Gerät sein Weckrecht zurückbekommen – das passiert nach manchen
Treiber- und Windows-Updates. Abhilfe: `Install.ps1` erneut laufen lassen.

Im Protokoll steht das Gegenstück dazu: „Unerwartetes Aufwachen vor der
Weckzeit, erneuter Standby in 15 s." Die Steuerung legt das Gerät also von
selbst wieder hin, aber jeder Vorgang kostet Strom und zeigt die Seite kurz an.

### Wenn das Bild nach dem Aufwachen schwarz bleibt

`Wake` schaltet das Panel über drei Wege ein (Leerlaufzähler zurücksetzen,
Monitor-Einschaltbefehl, minimale Mausbewegung). Bleibt es trotzdem dunkel,
liegt es meist am Grafiktreiber nach Resume – dann ist `DisplayOnly` die
robustere Wahl, weil das Gerät durchläuft.

### Anzeige der Strichliste

Die Aufgabe `Kiosk` startet Chrome im Vollbild: bei jeder Anmeldung und danach
alle fünf Minuten als Nachkontrolle. Ein laufendes Fenster erkennt sie an
`--kiosk` in der Befehlszeile – läuft eines, tut sie nichts. Chrome bekommt ein
eigenes Profil unter `%LOCALAPPDATA%\WallDisplayKiosk`, damit ein verstelltes
Alltagsprofil die Anzeige nicht mitnimmt.

`-Action Status` zeigt unter „Anzeige", welche Adresse gilt, welcher Browser
gefunden wurde und ob er gerade läuft. Von Hand starten:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\src\WallDisplay.ps1 -Action Kiosk
```

Die Steuerung lädt die Seite nicht neu. Wenn der Browser nach einer Nacht im
Standby eine veraltete Ansicht zeigt, empfiehlt sich im Browser selbst ein
periodischer Reload (z. B. Kiosk-Erweiterung oder eine Meta-Refresh-Hülle).
Unter `DisplayOnly` tritt das Problem praktisch nicht auf.

---

## Deinstallation

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\Uninstall.ps1
```

Mit `-RemoveData` werden zusätzlich Konfiguration, Zustand und Protokoll
gelöscht, mit `-RestorePowerDefaults` die Energieoptionen auf übliche Werte
zurückgesetzt – dazu gehört das Weckrecht der Eingabegeräte. Ohne diesen
Schalter bleibt es entzogen, und das Gerät lässt sich weiterhin nicht per Touch
aufwecken; die Deinstallation weist darauf hin.

---

## Dateien

| Datei | Zweck |
| --- | --- |
| `INSTALLATION.md` | Schritt-für-Schritt-Anleitung mit Checkliste |
| `Install.ps1` | Einrichtung: Konfiguration, Energieoptionen, Aufgaben |
| `Uninstall.ps1` | Entfernen |
| `config.json` | Vorlage der Konfiguration |
| `src/WallDisplay.ps1` | Hauptskript mit allen Aktionen |
| `src/WallDisplay.Core.psm1` | Kernfunktionen inkl. Win32-Aufrufen und Sync |
| `src/run-hidden.vbs` | Starter ohne sichtbares Konsolenfenster |
| `server/src/index.js` | Steuerungsserver (Express) |
| `server/src/db.js` | Datenhaltung über `node:sqlite` |
| `server/src/validate.js` | Prüfung aller Eingaben |
| `server/public/` | Weboberfläche (ohne Framework) |
| `server/test/api.test.js` | Tests der Schnittstelle |
| `server/Dockerfile`, `server/docker-compose.yml` | Container |
| `rustdesk/docker-compose.yml` | selbst gehosteter Fernwartungs-Server |

Eine Anmerkung zum Server: `node:sqlite` ist in Node noch als experimentell
markiert und würde eine Warnung ausgeben. Im Container ist sie über
`NODE_NO_WARNINGS=1` unterdrückt; funktional ist das Modul stabil.
