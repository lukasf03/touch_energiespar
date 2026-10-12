# Installation und Inbetriebnahme

Schritt-für-Schritt-Anleitung für das Wand-Touchpanel mit der Strichliste.

Die Anleitung hat vier Teile. **Teil 1 und 2 sind Pflicht**, Teil 3 und 4 sind
optional und können auch später nachgezogen werden:

| Teil | Was | Pflicht? | Dauer |
| --- | --- | --- | --- |
| 1 | Panel vorbereiten (BIOS, Autologon, Chrome) | ja | ca. 45 min |
| 2 | Energiesteuerung installieren | ja | ca. 15 min |
| 3 | Steuerungsserver (Zeiten von außen ändern) | optional | ca. 30 min |
| 4 | Fernwartung mit RustDesk | optional | ca. 30 min |

> **Reihenfolge beachten.** Teil 1 vor Teil 2: Die Installation prüft
> Voraussetzungen, die erst im BIOS gesetzt werden müssen. Ohne Teil 1 meldet
> der Selbsttest einen Fehler, und das Panel läuft dauerhaft im Sparmodus
> „nur Bildschirm aus" statt im Standby.

---

## Teil 1: Panel vorbereiten

### 1.1 BIOS/UEFI einstellen

Beim Hochfahren ins BIOS/UEFI (meist `Entf`, `F2` oder `F10`). Diese drei
Punkte entscheiden darüber, ob das Gerät später von selbst aufwacht:

| Einstellung | Wert | Warum |
| --- | --- | --- |
| **Wake on RTC** / „RTC Alarm" / „Resume by Alarm" | **aktiviert** | Ohne das zündet kein Zeitgeber, das Panel bleibt aus |
| **ErP Ready** / „ErP Support" | **deaktiviert** | Kappt sonst im Standby die Stromversorgung so weit, dass keine Uhr mehr läuft |
| **Deep Sleep** / „Deep Sx" | **deaktiviert** | Gleiche Wirkung wie ErP |

Nicht jedes Board hat alle drei Punkte; such nach dem, was vorhanden ist.
Finden sich die Einträge gar nicht, mach trotzdem weiter – der Selbsttest in
Schritt 2.4 sagt dir, ob es funktioniert.

Zusätzlich sinnvoll, falls vorhanden: **„Restore on AC Power Loss" → Power On**.
Damit fährt das Panel nach einem Stromausfall von selbst wieder hoch.

### 1.2 Benutzerkonto und automatische Anmeldung

Das Panel braucht ein Konto, das **automatisch angemeldet** wird. Das ist nicht
optional: Zwei der Aufgaben laufen in der Benutzersitzung, weil nur von dort
der Bildschirm geschaltet werden kann. Ohne angemeldeten Benutzer passiert
schlicht nichts.

1. Konto anlegen oder das vorhandene verwenden. Den vollständigen Namen
   notieren, du brauchst ihn in Schritt 2.3:

   ```bash
   whoami
   ```

   Ausgabe z. B. `panel-pc\kiosk` – genau das ist der Wert für `-UserId`.

2. Automatische Anmeldung einrichten. **Empfohlen:** Sysinternals Autologon
   (<https://learn.microsoft.com/sysinternals/downloads/autologon>). Das
   Programm legt das Kennwort verschlüsselt ab.

   > Trag das Kennwort **nicht** von Hand in die Registry unter
   > `Winlogon\DefaultPassword` ein – dort steht es im Klartext und ist für
   > jeden lesbar, der an das Gerät kommt.

3. Neu starten und prüfen, dass das Panel ohne Zutun auf dem Desktop landet.

### 1.3 Sperrbildschirm und Bildschirmschoner abschalten

Sonst zeigt das Panel irgendwann den Sperrbildschirm statt der Strichliste.

> Die Menüpfade stehen in **Englisch**, weil das Panel auf Englisch läuft. Die
> deutsche Entsprechung steht in Klammern.

- **Bildschirmschoner:** Rechtsklick auf den Desktop → *Personalize* →
  *Lock screen* → *Screen saver settings* → **(None)**.
  (Anpassen → Sperrbildschirm → Bildschirmschonereinstellungen → Kein)
- **Automatische Sperre:** *Settings* → *Accounts* → *Sign-in options* →
  *Require sign-in* → **Never**.
  (Einstellungen → Konten → Anmeldeoptionen)

  Schneller geht es über die Kommandozeile – das wirkt sofort und ist
  sprachunabhängig:

  ```bash
  reg add "HKCU\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 0 /f
  ```

- **Anmeldung nach dem Aufwachen:** erledigt `Install.ps1` in Teil 2 für dich.
  Du kannst es danach in der Statusausgabe nachsehen.

### 1.4 Chrome installieren

Die Strichliste zeigt später **Chrome im Vollbild** an. Den Vollbild-Start
richtet `Install.ps1` in Teil 2 selbst ein (Aufgabe `Kiosk`: bei jeder
Anmeldung und danach alle fünf Minuten als Nachkontrolle) – hier muss Chrome
nur vorhanden sein.

1. Chrome installieren, am besten **für alle Benutzer**
   (<https://google.com/chrome>). `Install.ps1` findet die Datei über die
   Registry und die üblichen Verzeichnisse; liegt sie woanders, hilft
   `-BrowserPath`.

2. Chrome **einmal von Hand starten** und eine eventuelle Ersteinrichtung
   wegklicken.

Das Browserprofil für die Anzeige legt die Steuerung selbst an, unter
`%LOCALAPPDATA%\WallDisplayKiosk`. Damit nimmt die Strichliste nichts mit,
was im Alltagsprofil verstellt wurde.

> **Tipp:** Browser laden die Seite nach langem Standby manchmal nicht neu.
> Falls die Anzeige veraltet wirkt, hilft eine Kiosk-Erweiterung mit
> periodischem Neuladen oder eine kleine HTML-Hülle mit
> `<meta http-equiv="refresh" content="900">`.

### 1.5 Windows Update zähmen

Ein Neustart mitten in der Nacht ist unkritisch, einer während der Öffnungszeit
nicht. Stell die **aktiven Stunden** auf die Zeiten, zu denen das Panel an ist:
*Settings* → *Windows Update* → *Advanced options* → *Active hours*, z. B.
16:00–02:00. (Einstellungen → Windows Update → Nutzungszeit ändern)

Nach einem Neustart kommt ohnehin alles von selbst zurück: Die geplanten
Aufgaben überleben ihn, der Abgleich läuft eine Minute nach dem Hochlaufen und
zieht den Zustand auf den Wochenplan nach, und die Strichliste startet mit der
automatischen Anmeldung wieder im Vollbild. Von Hand ist nichts zu tun.

---

## Teil 2: Energiesteuerung installieren

### 2.1 Dateien auf das Panel kopieren

Den gesamten Projektordner kopieren, zum Beispiel nach `C:\Tools\WindowsEnergie`.
Der Ordner `server` und `rustdesk` werden auf dem Panel nicht gebraucht, stören
dort aber auch nicht.

Bezugsquelle: <https://github.com/lukasf03/touch_energiespar>

### 2.2 Zeiten prüfen

Die Standardzeiten stehen in `config.json`. Sie sind so vorbelegt:

| Tag | an ab | aus um |
| --- | --- | --- |
| Montag bis Donnerstag | 18:00 | 22:00 |
| Freitag | 17:00 | 02:00 (Samstag) |
| Samstag | 17:00 | 02:00 (Sonntag) |
| Sonntag | 16:00 | 23:00 |

Passt das, ändere nichts. Andernfalls jetzt anpassen – vor der Installation ist
es am einfachsten.

Spätere Änderungen gehören in die Arbeitskopie
`C:\ProgramData\WallDisplayPower\config.json`, die die Installation anlegt;
diese Vorlage hier wird danach nicht mehr gelesen. Die Abgleich-Aufgabe zieht
die Auslösezeiten dann innerhalb von 15 Minuten selbst nach.

### 2.3 Installation ausführen

PowerShell **als Administrator** öffnen (Startmenü → „PowerShell" → Rechtsklick
→ *Run as administrator* / *Als Administrator ausführen*) und ausführen:

```bash
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\Install.ps1 -UserId "PANEL-PC\kiosk"
```

`-UserId` ist der Wert aus Schritt 1.2. Läufst du bereits unter dem Panel-Konto,
kannst du den Parameter weglassen.

Das Skript macht Folgendes:

- schreibt die Konfiguration nach `C:\ProgramData\WallDisplayPower\config.json`
- setzt Bildschirm- und Standby-Zeitüberschreitungen auf „nie" (die Steuerung
  übernimmt das selbst)
- erlaubt Aufwachzeitgeber, schaltet Hybrid-Standby ab
- schaltet den Ruhezustand ab, damit das Gerät wirklich in den Standby (S3)
  geht und nicht in den Ruhezustand (S4) – das deaktiviert zugleich den
  Schnellstart
- schaltet die Anmeldung nach dem Aufwachen ab
- nimmt Touchscreen, Tastatur und Maus das Weckrecht, damit eine Berührung das
  Panel nachts nicht aus dem Standby holt (Netzwerkadapter behalten es, damit
  Wake-on-LAN weiter geht; mit `-KeepDeviceWake` abschaltbar)
- gibt dem Panel-Konto Schreibrecht auf das Datenverzeichnis
- richtet den Vollbild-Start der Strichliste ein: Chrome startet bei jeder
  Anmeldung mit `--kiosk`. Eine andere Adresse mit `-KioskUrl`, gar kein
  Vollbild-Start mit `-NoKiosk`
- legt fünf geplante Aufgaben unter `\WallDisplayPower\` an

Am Ende zeigt es den Wochenplan und die Zahl der Auslöser je Aufgabe. Erwartet
werden beim Standardplan **drei Auslöser pro Aufgabe**.

### 2.4 Selbsttest – der wichtigste Schritt

```bash
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\src\WallDisplay.ps1 -Action SelfTest
```

Das Gerät geht für drei Minuten in den Standby und soll von selbst aufwachen.
**Währenddessen nichts berühren** – keine Maus, keine Tastatur, kein Touch.

Ergebnis:

- **ERFOLGREICH** → fertig, der Modus `Combined` trägt. Weiter mit 2.5.
- **FEHLGESCHLAGEN** → geh zurück zu Schritt 1.1 und prüfe die BIOS-Einstellungen.
  Hilft das nicht, stell in `config.json` `"Mode": "DisplayOnly"` ein. Dann
  bleibt nur der Bildschirm aus, das Gerät läuft durch. Das spart weniger, ist
  aber absolut zuverlässig.

### 2.5 Abschließende Kontrolle

```bash
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\src\WallDisplay.ps1 -Action Status
```

Diese Punkte sollten stimmen:

| Zeile | Erwartet |
| --- | --- |
| Wochenplan | deine Zeiten |
| Panel soll jetzt | passend zur aktuellen Uhrzeit |
| Aufgaben Sleep / WakeTimer / Wake / Sync / Kiosk | alle fünf eingerichtet, „weckt auf: ja" bei WakeTimer |
| Anzeige | Adresse der Strichliste, gefundener Browser, „Laeuft gerade: ja" |
| Auslöser passen zum Wochenplan | ja |
| Schlafzustände | `S3` (oder `S0` bei Modern Standby) |
| Aufwachzeitgeber | erlaubt |
| **Weckberechtigte Geräte** | **keine, oder nur der Netzwerkadapter** – steht dort ein Touchscreen, eine Tastatur oder eine Maus, weckt eine Berührung das Panel nachts auf |
| **Anmeldung nach Wecken** | **nein** |

Steht bei „Anmeldung nach Wecken" ein **JA**, zeigt das Panel nach dem
Aufwachen den Sperrbildschirm. Dann hat eine Gruppenrichtlinie die Einstellung
überschrieben – sprich: am Panel prüfen, ob es einer Domäne angehört.

### 2.6 Erster echter Durchlauf

Warte den nächsten Fensterwechsel ab und sieh danach ins Protokoll:

```bash
notepad C:\ProgramData\WallDisplayPower\walldisplay.log
```

Erwartete Einträge beim Einschlafen:

```
[INFO] Ruhebetrieb beginnt. Modus=Combined, naechstes Fenster ab ...
[INFO] Bildschirm ausgeschaltet.
[INFO] Standby in 60 s.
[INFO] Wechsel in den Energiesparmodus.
```

und beim Aufwachen:

```
[INFO] Aufwachzeitgeber hat ausgeloest, das Geraet ist wach.
[INFO] Bildschirm eingeschaltet.
[INFO] Aufwachen puenktlich, Abweichung 0,2 Minuten.
```

**Damit ist die Pflicht erledigt.** Das Panel schaltet sich jetzt selbständig.

---

## Teil 3: Steuerungsserver (optional)

Damit lassen sich die Zeiten von außen ändern, ohne ans Panel zu müssen. Das
Panel fragt alle 5 Minuten nach.

### 3.1 Voraussetzungen

- Ein Server mit Docker, der **aus dem Netz des Panels erreichbar** ist
- Ein DNS-Name darauf, z. B. `panel.example.org`
- Ein Reverse-Proxy mit HTTPS davor (Caddy, nginx oder Traefik)

### 3.2 Server starten

```bash
cd server && cp .env.example .env
```

In `.env` zwei Werte ersetzen. Zufallswerte erzeugen:

```bash
openssl rand -base64 32
```

- `PANEL_TOKEN` – gemeinsames Token aller Panels, mindestens 16 Zeichen
- `ADMIN_PASSWORD` – Kennwort der Weboberfläche, mindestens 8 Zeichen
- `TRUST_PROXY=1` setzen, weil ein Reverse-Proxy davor steht

Dann:

```bash
docker compose up -d --build
```

Der Container lauscht absichtlich nur auf `127.0.0.1:8080`. Nach außen kommt er
erst über den Reverse-Proxy.

### 3.3 Reverse-Proxy

Mit Caddy genügt eine Zeile in der `Caddyfile`:

```bash
panel.example.org { reverse_proxy 127.0.0.1:8080 }
```

Danach `https://panel.example.org` im Browser aufrufen – es muss die
Anmeldemaske erscheinen.

### 3.4 Panel anbinden

Auf dem Panel, wieder als Administrator:

```bash
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\Install.ps1 -UserId "PANEL-PC\kiosk" -ServerUrl https://panel.example.org -PanelId pfarrheim -ApiToken "<PANEL_TOKEN>"
```

`-PanelId` ist ein frei wählbarer Kurzname (Kleinbuchstaben, Ziffern, Bindestrich).
Bei mehreren Panels gibt jedes einen eigenen an.

Sofort prüfen, ob die Verbindung steht:

```bash
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\src\WallDisplay.ps1 -Action Sync
```

Danach taucht das Panel in der Weboberfläche auf. Erscheint es nicht, zeigt
`-Action Status` unter „Fernsteuerung" den letzten Fehler.

### 3.5 Bedienung

In der Oberfläche je Panel einstellbar:

- **Wochenplan** – je Tag an/aus mit Uhrzeiten, einzelne Tage abwählbar
- **Modus** und **Zeitplan aktiv**
- **Wach bleiben bis** – einmalige Ausnahme, z. B. für eine Gruppenstunde
- **Jetzt aufwecken** / **Jetzt schlafen**
- **Für Wartung wach halten** – 30 Minuten bis 4 Stunden

Änderungen greifen beim nächsten Abruf, also binnen etwa 5 Minuten.

> **Die Einschränkung, die man kennen muss:** Während das Panel schläft, kann
> es nichts abfragen. Einen Fensterbeginn **nach vorne** zu ziehen wirkt
> deshalb erst beim nächsten Aufwachen. Nach hinten verschieben funktioniert
> dagegen jederzeit – das Panel wacht zur alten Zeit auf, merkt beim Abruf,
> dass es noch zu früh ist, und legt sich wieder hin.

---

## Teil 4: Fernwartung mit RustDesk (optional)

Damit kommst du auf das Panel, ohne davor zu stehen – ohne VPN und ohne
Portfreigabe im Netz des Panels, weil es nur ausgehende Verbindungen aufbaut.

> **Warum nicht Remotedesktop?** RDP würde die Konsolensitzung übernehmen. Das
> Panel an der Wand zeigt dann den Sperrbildschirm statt der Strichliste, auch
> nach dem Trennen. RustDesk teilt die bestehende Sitzung.

### 4.1 Server starten

```bash
cd rustdesk && cp .env.example .env
```

In `.env` den öffentlich erreichbaren Namen des Servers eintragen, dann:

```bash
docker compose up -d
```

### 4.2 Ports freigeben

Diese Ports müssen von außen erreichbar sein:

| Port | Protokoll |
| --- | --- |
| 21115 | TCP |
| 21116 | **TCP und UDP** |
| 21117 | TCP |

Die UDP-Regel für 21116 wird am häufigsten vergessen – ohne sie klappt der
Verbindungsaufbau nicht.

### 4.3 Schlüssel auslesen

Beim ersten Start erzeugt der Server ein Schlüsselpaar:

```bash
cat rustdesk/data/id_ed25519.pub
```

Die Zeichenkette brauchst du im nächsten Schritt.

### 4.4 Client auf dem Panel

1. RustDesk installieren (<https://rustdesk.com/>).
2. *Einstellungen* → *Netzwerk* → *ID/Relay-Server*:
   - **ID-Server** und **Relay-Server**: dein Servername
   - **Schlüssel**: die Zeichenkette aus 4.3
3. Ein **festes Kennwort** für unbeaufsichtigten Zugriff setzen.
4. RustDesk als **Dienst** laufen lassen, damit es auch ohne angemeldeten
   Benutzer erreichbar ist.

Beim nächsten Abruf meldet das Panel seine RustDesk-Kennung an den
Steuerungsserver – die Weboberfläche zeigt sie dann mit Kopier-Knopf an.

### 4.5 Zugriff außerhalb der Öffnungszeiten

Liegt das Panel im Standby, erreicht es **kein** Befehl. Wer außerhalb der
Fenster dran will, klickt vorher in der Weboberfläche auf **„Für Wartung wach
halten"**. Im Modus `DisplayOnly` entfällt das, weil das Gerät durchläuft.

---

## Betrieb und Fehlersuche

### Die wichtigsten Befehle

Status mit Wochenplan, Aufgaben und den letzten Protokollzeilen:

```bash
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\src\WallDisplay.ps1 -Action Status
```

Ausführliche Analyse (Schlafzustände, aktive Zeitgeber, letzter Weckgrund,
Sperren, Ereignisprotokoll):

```bash
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\src\WallDisplay.ps1 -Action Diagnose
```

Weitere Aktionen: `-Action DisplayOn`, `-Action DisplayOff`, `-Action Sync`,
`-Action Kiosk` (Strichliste starten, falls sie nicht läuft),
`-Action Reset` (hebt eine automatische Rückstufung auf).

Protokoll: `C:\ProgramData\WallDisplayPower\walldisplay.log`

### Wenn etwas nicht stimmt

| Beobachtung | Ursache und Abhilfe |
| --- | --- |
| Panel geht gar nicht aus | Läuft der angemeldete Benutzer? Autologon prüfen (1.2). `-Action Status` zeigt, ob die Aufgaben eingerichtet sind. |
| Panel wacht nicht auf | BIOS prüfen (1.1), danach Selbsttest wiederholen. Hilft nichts: `"Mode": "DisplayOnly"`. |
| Morgens Sperrbildschirm statt Strichliste | `-Action Status` → „Anmeldung nach Wecken". Steht dort JA, überschreibt eine Gruppenrichtlinie die Einstellung. |
| Bild bleibt nach dem Aufwachen schwarz | Meist der Grafiktreiber nach Resume. `"Mode": "DisplayOnly"` ist dann robuster. |
| Status meldet „Modus (aktiv): DisplayOnly", obwohl `Combined` eingestellt ist | Automatische Rückstufung nach zwei misslungenen Aufwach-Versuchen. Grund steht unter „Hinweis". Nach Behebung: `-Action Reset`. |
| Panel wacht nachts von selbst auf | `-Action Status` → „Weckberechtigte Geräte". Steht dort ein Eingabegerät, hat es nach einem Treiber- oder Windows-Update sein Weckrecht zurück. `Install.ps1` erneut laufen lassen. |
| Geänderte Zeiten wirken nicht | Zeiten müssen in `C:\ProgramData\WallDisplayPower\config.json` stehen, nicht in der Vorlage im Projektordner. Danach bis zu 15 Minuten warten und `-Action Status` prüfen: „Auslöser passen zum Wochenplan" muss **ja** sein. |
| Status: „Auslöser passen zum Wochenplan: NEIN" | Der Abgleich zieht das selbst nach. Bleibt es dabei, steht der Grund als `ERROR` im Protokoll – dann `Install.ps1` als Administrator ausführen. |
| Panel lief eine ganze Nacht durch | Protokoll prüfen. Fehlte der Auslöser (Stromausfall, Zeitumstellung, kein angemeldeter Benutzer), holt die `Sync`-Aufgabe das nach – `-Action Status` muss sie als eingerichtet zeigen. |
| Strichliste erscheint nicht, nur der Desktop | `-Action Status` → Abschnitt „Anzeige". Fehlt der Browser, Chrome installieren oder `Install.ps1 -BrowserPath` angeben. Sonst `-Action Kiosk` von Hand aufrufen und das Protokoll lesen. |
| Zwei Vollbild-Fenster übereinander | Ein von Hand gestartetes Chrome-Fenster ohne `--kiosk` erkennt die Aufgabe nicht. Beide schließen, die Aufgabe holt die Anzeige binnen fünf Minuten zurück. |
| Anzeige veraltet nach langer Pause | Browser lädt nicht neu, siehe Tipp in 1.4. |
| Panel erscheint nicht auf dem Server | `-Action Status` → „Fernsteuerung" zeigt den letzten Fehler. Meist Token oder Adresse falsch. |

### Deinstallation

```bash
powershell -ExecutionPolicy Bypass -File C:\Tools\WindowsEnergie\Uninstall.ps1
```

Mit `-RemoveData` zusätzlich Konfiguration, Zustand und Protokoll löschen, mit
`-RestorePowerDefaults` die Energieoptionen auf übliche Werte zurücksetzen –
dazu gehört das Weckrecht von Touchscreen, Tastatur und Maus. Ohne diesen
Schalter bleibt es entzogen; die Deinstallation weist dann darauf hin.

---

## Checkliste zum Abhaken

**Teil 1 – Vorbereitung**

- [ ] BIOS: Wake on RTC aktiviert, ErP/Deep Sleep deaktiviert
- [ ] Autologon eingerichtet und durch Neustart geprüft
- [ ] Bildschirmschoner und automatische Sperre aus
- [ ] Chrome installiert und einmal gestartet
- [ ] Nutzungszeit für Windows Update gesetzt

**Teil 2 – Energiesteuerung**

- [ ] Dateien kopiert, Zeiten in `config.json` geprüft
- [ ] `Install.ps1` als Administrator gelaufen, drei Auslöser je Aufgabe
- [ ] **Selbsttest erfolgreich** (oder bewusst auf `DisplayOnly` gestellt)
- [ ] `-Action Status` geprüft, „Anmeldung nach Wecken" steht auf nein
- [ ] `-Action Status`: unter „Weckberechtigte Geräte" steht kein Eingabegerät
- [ ] `-Action Status`: im Abschnitt „Anzeige" läuft die Strichliste
- [ ] Ersten echten Fensterwechsel im Protokoll gesehen

**Teil 3 – Steuerungsserver (optional)**

- [ ] `.env` mit eigenen Zufallswerten, `TRUST_PROXY=1`
- [ ] Container läuft, Weboberfläche über HTTPS erreichbar
- [ ] Panel angebunden, taucht in der Übersicht auf
- [ ] Teständerung gemacht und am Panel angekommen

**Teil 4 – Fernwartung (optional)**

- [ ] RustDesk-Server läuft, Ports frei (inkl. **UDP 21116**)
- [ ] Client konfiguriert mit Server, Schlüssel und festem Kennwort
- [ ] RustDesk läuft als Dienst
- [ ] Testverbindung von außen erfolgreich
