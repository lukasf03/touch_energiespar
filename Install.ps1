<#
.SYNOPSIS
    Richtet die Energiesteuerung fuer das Wand-Touchpanel ein.

.DESCRIPTION
    Legt die Konfiguration unter C:\ProgramData\WallDisplayPower ab, setzt die
    Energieoptionen fuer den Dauerbetrieb und registriert die geplanten Aufgaben:

      \WallDisplayPower\Sleep      zur Schlafenszeit, laeuft in der Sitzung des
                                   angemeldeten Benutzers (nur dort kann der
                                   Bildschirm abgeschaltet werden)
      \WallDisplayPower\WakeTimer  eine Minute vor jedem Fensterbeginn, laeuft als
                                   SYSTEM und holt das Geraet per
                                   Aufwachzeitgeber aus dem Standby
      \WallDisplayPower\Wake       zur Weckzeit, schaltet den Bildschirm ein
      \WallDisplayPower\Sync       regelmaessiger Abgleich: holt - sofern
                                   eingerichtet - den Zeitplan vom Server und
                                   zieht in jedem Fall den tatsaechlichen
                                   Zustand auf den Wochenplan nach
      \WallDisplayPower\Kiosk      startet die Strichliste im Vollbild, bei
                                   jeder Anmeldung und danach regelmaessig -
                                   damit die Anzeige nach einem Neustart oder
                                   einem Browserabsturz von selbst wiederkommt

.PARAMETER Mode
    Betriebsart ausserhalb der Aktiv-Fenster.

    Die Zeiten selbst stehen im Wochenplan in config.json (Abschnitt
    "Schedule") beziehungsweise kommen vom Steuerungsserver.

    Combined    Bildschirm aus, danach Standby (Standard)
    DisplayOnly nur Bildschirm aus, kein Standby
    SuspendOnly sofort Standby ohne Vorlauf

.PARAMETER UserId
    Benutzerkonto, in dessen Sitzung das Panel laeuft (das Autologon-Konto).
    Standard ist das Konto, das Install.ps1 ausfuehrt.

.PARAMETER KeepHibernate
    Laesst den Ruhezustand aktiv. Standard ist, ihn abzuschalten, damit das
    Geraet wirklich in den Standby und nicht in den Ruhezustand geht.

.PARAMETER KeepDeviceWake
    Laesst allen Geraeten ihr Weckrecht. Standard ist, es ihnen zu nehmen,
    damit nicht jede Beruehrung des Touchscreens das Panel nachts aus dem
    Standby holt. Netzwerkadapter sind davon ohnehin ausgenommen, damit
    Wake-on-LAN weiter funktioniert.

.PARAMETER KioskUrl
    Adresse, die im Vollbild angezeigt wird. Standard ist der Wert aus
    config.json ("KioskUrl"). Bleibt sie leer, startet die Steuerung keinen
    Browser.

.PARAMETER BrowserPath
    Pfad zu chrome.exe. Standard ist, die Datei selbst zu suchen (Registry
    und die ueblichen Verzeichnisse).

.PARAMETER NoKiosk
    Richtet keinen Vollbild-Start ein und entfernt eine vorhandene
    Kiosk-Aufgabe. Fuer Panels, auf denen die Anzeige anders startet.

.PARAMETER ServerUrl
    Adresse des Steuerungsservers, z. B. https://panel.example.org. Damit
    holt die Abgleich-Aufgabe zusaetzlich den Zeitplan von dort. Ohne diesen
    Parameter laeuft das Panel rein mit der lokalen Konfiguration.

.PARAMETER PanelId
    Kennung dieses Panels auf dem Server. Standard ist der Computername.

.PARAMETER ApiToken
    Gemeinsames Token der Panel-Schnittstelle (PANEL_TOKEN des Servers).

.PARAMETER PollMinutes
    Abstand der Abgleiche. Standard 5 Minuten mit Server, sonst 15 - ohne
    Server ist der Abgleich nur ein Sicherheitsnetz und muss nicht so oft
    laufen.

.PARAMETER AllowInsecureHttp
    Erlaubt http statt https. Nur fuer Tests im eigenen Netz.

.EXAMPLE
    .\Install.ps1

.EXAMPLE
    .\Install.ps1 -UserId 'PANEL-PC\kiosk'

.EXAMPLE
    .\Install.ps1 -ServerUrl https://panel.example.org -PanelId pfarrheim -ApiToken 'geheim'

.EXAMPLE
    .\Install.ps1 -KioskUrl 'https://strichliste.example.org/#/monitor'

.EXAMPLE
    .\Install.ps1 -NoKiosk
#>
[CmdletBinding()]
param(
    [ValidateSet('Combined', 'DisplayOnly', 'SuspendOnly')][string]$Mode,
    [string]$UserId,
    [switch]$KeepHibernate,
    [switch]$KeepDeviceWake,

    [string]$KioskUrl,
    [string]$BrowserPath,
    [switch]$NoKiosk,

    [string]$ServerUrl,
    [string]$PanelId,
    [string]$ApiToken,
    [ValidateRange(1, 60)][int]$PollMinutes = 5,
    [switch]$AllowInsecureHttp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\WallDisplay.Core.psm1') -Force -DisableNameChecking

if ($NoKiosk -and $PSBoundParameters.ContainsKey('KioskUrl')) {
    throw '-NoKiosk und -KioskUrl widersprechen sich: entweder kein Vollbild-Start oder eine Adresse.'
}

if (-not (Test-WallAdmin)) {
    throw 'Install.ps1 muss in einer PowerShell mit Administratorrechten laufen.'
}

$paths = Get-WallPaths
$tasks = Get-WallTaskNames

if (-not (Test-Path -LiteralPath $paths.ScriptFile)) {
    throw "WallDisplay.ps1 wurde nicht gefunden: $($paths.ScriptFile)"
}
if (-not (Test-Path -LiteralPath $paths.LauncherVbs)) {
    throw "run-hidden.vbs wurde nicht gefunden: $($paths.LauncherVbs)"
}

Confirm-WallDataRoot | Out-Null


# ------------------------------------------------------------- 1. Konfiguration

$overrides = @{}

if ($PSBoundParameters.ContainsKey('Mode'))        { $overrides['Mode'] = $Mode }
if ($PSBoundParameters.ContainsKey('KioskUrl'))    { $overrides['KioskUrl'] = $KioskUrl }
if ($PSBoundParameters.ContainsKey('BrowserPath')) { $overrides['KioskBrowser'] = $BrowserPath }

# -NoKiosk heisst: keine Adresse. Damit entscheidet allein die Konfiguration
# darueber, ob ein Browser gestartet wird - auch beim Aufwachen, das die
# Anzeige ebenfalls nachsieht.
if ($NoKiosk) { $overrides['KioskUrl'] = '' }

$configFile = Save-WallConfig -Values $overrides
$config = Get-WallConfig



Write-Host ''
Write-Host '=== Einrichtung Wand-Display Energiesteuerung ===' -ForegroundColor Cyan
Write-Host ('Konfiguration : {0}' -f $configFile)
Write-Host ('Modus         : {0}' -f $config.Mode)
Write-Host 'Wochenplan    : Zeiten, zu denen das Panel AN ist'
$kurz = @{ Monday = 'Mo'; Tuesday = 'Di'; Wednesday = 'Mi'; Thursday = 'Do'; Friday = 'Fr'; Saturday = 'Sa'; Sunday = 'So' }
foreach ($day in @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')) {
    $window = $config.Windows[$day]
    if ($window) {
        $hinweis = if ($window.CrossesMidnight) { ' (bis zum Folgetag)' } else { '' }
        Write-Host ('                {0}  {1:hh\:mm} - {2:hh\:mm}{3}' -f $kurz[$day], $window.On, $window.Off, $hinweis)
    } else {
        Write-Host ('                {0}  aus' -f $kurz[$day]) -ForegroundColor DarkGray
    }
}


# ------------------------------------------------------------ 2. Energieoptionen

Set-WallPowerPolicy -DisableHibernate:(-not $KeepHibernate)

# Weckrecht der Eingabegeraete entziehen. Ohne diesen Schritt holt eine
# Beruehrung des Touchscreens das Panel nachts aus dem Standby - die Steuerung
# legt es zwar wieder hin, aber jeder Vorgang kostet Strom und zeigt die Seite
# kurz an. Netzwerkadapter bleiben weckberechtigt (Wake-on-LAN).
if ($KeepDeviceWake) {
    $armed = @(Get-WakeArmedDevices -Map (Get-WallPnpClassMap))
    Write-Host ('Weckrecht     : unveraendert (-KeepDeviceWake), weckberechtigt: {0}' -f
        $(if ($armed.Count) { $armed -join ', ' } else { 'keine' })) -ForegroundColor DarkGray
} else {
    $disabledWake = @(Disable-WallDeviceWake)
    if ($disabledWake.Count) {
        $state = Get-WallState
        # Zusammenfuehren, damit ein zweiter Lauf frueher entzogene Rechte
        # nicht aus der Liste verliert - die Deinstallation gibt nur zurueck,
        # was hier steht.
        $state.DisabledWakeDevices = @(@($state.DisabledWakeDevices) + $disabledWake |
            Where-Object { $_ } | Select-Object -Unique)
        Save-WallState $state
        Write-Host ('Weckrecht     : {0} Geraet(en) entzogen ({1})' -f $disabledWake.Count,
            ($disabledWake -join ', ')) -ForegroundColor Green
    } else {
        Write-Host 'Weckrecht     : kein Geraet musste geaendert werden' -ForegroundColor DarkGray
    }
}


# --------------------------------------------------------------- 3. Benutzerkonto

if (-not $PSBoundParameters.ContainsKey('UserId') -or [string]::IsNullOrWhiteSpace($UserId)) {
    $UserId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Host ('Anzeige-Konto : {0} (aktuelles Konto)' -f $UserId)
} else {
    Write-Host ('Anzeige-Konto : {0}' -f $UserId)
}

# Sleep und Wake laufen in der Sitzung dieses Kontos und schreiben dort
# Konfiguration und Zustand - unter C:\ProgramData braucht es dafuer ein
# ausdrueckliches Schreibrecht.
Grant-WallDataAccess -UserId $UserId | Out-Null


# ------------------------------------------------------------------ 4. Aufgaben

function New-WallInteractiveAction {
    param([Parameter(Mandatory)][string]$ActionName)

    # Der Umweg ueber wscript.exe haelt das Konsolenfenster unsichtbar.
    New-ScheduledTaskAction -Execute 'wscript.exe' `
        -Argument ('"{0}" "{1}" {2}' -f (Get-WallPaths).LauncherVbs, (Get-WallPaths).ScriptFile, $ActionName)
}

# Get-WallScheduleTriggers liegt im Modul, weil der Abgleich (Action Sync) die
# Ausloeser ebenfalls nachzieht.

$interactivePrincipal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest
$systemPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

# Nacht-Aufgabe: laeuft moeglicherweise die ganze Nacht (Nachkontrolle des
# Bildschirms), darum kein Zeitlimit und kein Nachholen bei verpasstem Start.
$sleepSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd `
    -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew
$sleepSettings.StartWhenAvailable = $false

Register-ScheduledTask -TaskPath $tasks.Path -TaskName $tasks.Sleep -Force `
    -Description 'Wandpanel: Bildschirm aus und Energiesparmodus am Fensterende' `
    -Action (New-WallInteractiveAction -ActionName 'Sleep') `
    -Trigger (Get-WallScheduleTriggers -Config $config -Kind 'Sleep') `
    -Principal $interactivePrincipal -Settings $sleepSettings | Out-Null
Write-Host ('Aufgabe       : {0}{1} ({2} Ausloeser)' -f $tasks.Path, $tasks.Sleep, @(Get-WallScheduleTriggers -Config $config -Kind 'Sleep').Count) -ForegroundColor Green

# Aufwachzeitgeber als SYSTEM: holt das Geraet unabhaengig von der
# Benutzersitzung aus dem Standby.
$prewakeSettings = New-ScheduledTaskSettingsSet -WakeToRun `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([timespan]::FromMinutes(5)) -MultipleInstances IgnoreNew
$prewakeSettings.StartWhenAvailable = $false

Register-ScheduledTask -TaskPath $tasks.Path -TaskName $tasks.Prewake -Force `
    -Description 'Wandpanel: holt das Geraet per Aufwachzeitgeber aus dem Energiesparmodus' `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Prewake' -f $paths.ScriptFile)) `
    -Trigger (Get-WallScheduleTriggers -Config $config -Kind 'Prewake') `
    -Principal $systemPrincipal -Settings $prewakeSettings | Out-Null
Write-Host ('Aufgabe       : {0}{1} ({2} Ausloeser, weckt das Geraet)' -f $tasks.Path, $tasks.Prewake, @(Get-WallScheduleTriggers -Config $config -Kind 'Prewake').Count) -ForegroundColor Green

# Weck-Aufgabe in der Benutzersitzung: schaltet den Bildschirm ein. Zusaetzlich
# ebenfalls mit Aufwachzeitgeber, als zweite Absicherung. StartWhenAvailable
# bleibt an, damit ein verpasstes Aufwachen erkannt und protokolliert wird.
$wakeSettings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([timespan]::FromMinutes(5)) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskPath $tasks.Path -TaskName $tasks.Wake -Force `
    -Description 'Wandpanel: Bildschirm zum Fensterbeginn einschalten' `
    -Action (New-WallInteractiveAction -ActionName 'Wake') `
    -Trigger (Get-WallScheduleTriggers -Config $config -Kind 'Wake') `
    -Principal $interactivePrincipal -Settings $wakeSettings | Out-Null
Write-Host ('Aufgabe       : {0}{1} ({2} Ausloeser)' -f $tasks.Path, $tasks.Wake, @(Get-WallScheduleTriggers -Config $config -Kind 'Wake').Count) -ForegroundColor Green

# Festhalten, zu welchem Wochenplan die Ausloeser gesetzt wurden. Stimmt das
# spaeter nicht mehr, wagt das Panel keinen Standby.
$state = Get-WallState
$state.TaskScheduleFingerprint = Get-ScheduleFingerprint -Config $config
Save-WallState $state

# Abgleich-Aufgabe als SYSTEM. Sie hat zwei Aufgaben in einer, und die zweite
# ist auch ohne Server noetig:
#
#   1. Mit Server holt sie den Zeitplan und meldet den Zustand zurueck.
#   2. Immer prueft sie, ob das Panel gerade an oder aus sein soll, und zieht
#      nach. Das ist das Netz fuer jeden verpassten Ausloeser - Stromausfall
#      ausserhalb der Fenster, beim Fensterende noch kein angemeldeter
#      Benutzer, oder die Nacht der Zeitumstellung im Maerz, in der es die
#      Ortszeit 02:00 gar nicht gibt. Ohne dieses Netz liefe das Panel in
#      solchen Faellen bis zum naechsten Abend durch, ohne dass es auffaellt.
#
# Als SYSTEM, weil das Aendern der Aufgaben-Startzeiten Administratorrechte
# braucht.

$hasServer = $PSBoundParameters.ContainsKey('ServerUrl') -and -not [string]::IsNullOrWhiteSpace($ServerUrl)

if ($hasServer) {
    if ([string]::IsNullOrWhiteSpace($ApiToken)) {
        throw '-ServerUrl ohne -ApiToken: das Panel koennte sich nicht anmelden.'
    }
    if ([string]::IsNullOrWhiteSpace($PanelId)) {
        $PanelId = $env:COMPUTERNAME.ToLowerInvariant()
        Write-Host ('Panel-Kennung : {0} (aus dem Computernamen)' -f $PanelId)
    }

    $syncFile = Save-SyncConfig -ServerUrl $ServerUrl -PanelId $PanelId -ApiToken $ApiToken `
        -AllowInsecureHttp:$AllowInsecureHttp
    Write-Host ('Fernsteuerung : {0} (Zugriff nur fuer SYSTEM und Administratoren)' -f $syncFile) -ForegroundColor Green

    if (-not (Get-SyncConfig)) {
        throw 'Die Fernsteuerungs-Einstellungen wurden abgelehnt, siehe Protokoll. Bitte ServerUrl und Token pruefen.'
    }
} elseif (Test-Path -LiteralPath $paths.SyncFile) {
    Write-Host 'Fernsteuerung : bleibt wie eingerichtet (sync.json unveraendert)' -ForegroundColor DarkGray
} else {
    Write-Host 'Fernsteuerung : nicht eingerichtet (Panel arbeitet rein mit der lokalen Konfiguration)' -ForegroundColor DarkGray
}

# Ohne Server ist der Abgleich nur ein Netz und muss nicht alle 5 Minuten
# laufen. Ein ausdruecklich angegebenes -PollMinutes gilt in jedem Fall.
$syncConfigured = $hasServer -or (Test-Path -LiteralPath $paths.SyncFile)
$pollMinutes = if ($syncConfigured -or $PSBoundParameters.ContainsKey('PollMinutes')) { $PollMinutes } else { 15 }

# Taeglicher Ausloeser um 00:00 mit Wiederholung, damit der Abgleich rund um
# die Uhr laeuft und einen Neustart ohne Zutun uebersteht.
$syncTrigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today)
$syncTrigger.StartBoundary = ([datetime]::Today).ToString('yyyy-MM-ddTHH:mm:ss')
$syncTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At ([datetime]::Today) `
    -RepetitionInterval (New-TimeSpan -Minutes $pollMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 1)).Repetition

# Zweiter Ausloeser: einmal beim Hochlaufen. Ohne ihn liefe das Panel nach
# einem Neustart bis zum naechsten Wiederholungstermin im falschen Zustand
# weiter, nachts also mit eingeschaltetem Bildschirm. Die Minute Verzoegerung
# gibt der automatischen Anmeldung Zeit: der Abgleich startet im Zweifel die
# Nacht- oder die Weck-Aufgabe, und die laufen in der Benutzersitzung.
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootTrigger.Delay = 'PT1M'

$syncSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([timespan]::FromMinutes(10)) -MultipleInstances IgnoreNew

$syncDescription = if ($syncConfigured) {
    'Wandpanel: Zeitplan vom Server holen und Zustand abgleichen'
} else {
    'Wandpanel: Zustand mit dem Wochenplan abgleichen (Netz fuer verpasste Ausloeser)'
}

Register-ScheduledTask -TaskPath $tasks.Path -TaskName $tasks.Sync -Force `
    -Description $syncDescription `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Sync' -f $paths.ScriptFile)) `
    -Trigger @($syncTrigger, $bootTrigger) -Principal $systemPrincipal -Settings $syncSettings | Out-Null
Write-Host ('Aufgabe       : {0}{1} alle {2} Minuten und beim Systemstart{3}' -f $tasks.Path, $tasks.Sync, $pollMinutes,
    $(if ($syncConfigured) { '' } else { ' (nur Abgleich, kein Server)' })) -ForegroundColor Green


# Kiosk-Aufgabe: zeigt die Strichliste im Vollbild. Sie hat zwei Ausloeser,
# denn beides soll ohne Zutun geschehen:
#
#   1. bei jeder Anmeldung - nach einem Neustart ist die Anzeige damit von
#      selbst wieder da. Die paar Sekunden Verzoegerung geben dem Desktop
#      Zeit, sonst startet der Browser in ein noch leeres Profil.
#   2. alle 5 Minuten als Nachkontrolle, falls der Browser abgestuerzt oder
#      versehentlich geschlossen wurde. Laeuft er, tut die Aufgabe nichts.
#
# Bewusst ohne erhoehte Rechte: ein Browser hat als Administrator nichts zu
# suchen.

if ([string]::IsNullOrWhiteSpace([string]$config.KioskUrl)) {
    if (Get-WallTask -Name $tasks.Kiosk) {
        Unregister-ScheduledTask -TaskPath $tasks.Path -TaskName $tasks.Kiosk -Confirm:$false
        Write-Host ('Aufgabe       : {0}{1} entfernt (kein Vollbild-Start)' -f $tasks.Path, $tasks.Kiosk) -ForegroundColor Yellow
    } else {
        Write-Host 'Anzeige       : kein Vollbild-Start (KioskUrl ist leer)' -ForegroundColor DarkGray
    }
} else {
    $kioskLogon = New-ScheduledTaskTrigger -AtLogOn -User $UserId
    $kioskLogon.Delay = 'PT15S'

    $kioskWatch = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today)
    $kioskWatch.StartBoundary = ([datetime]::Today).ToString('yyyy-MM-ddTHH:mm:ss')
    $kioskWatch.Repetition = (New-ScheduledTaskTrigger -Once -At ([datetime]::Today) `
        -RepetitionInterval (New-TimeSpan -Minutes 5) `
        -RepetitionDuration (New-TimeSpan -Days 1)).Repetition

    $kioskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([timespan]::FromMinutes(5)) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskPath $tasks.Path -TaskName $tasks.Kiosk -Force `
        -Description 'Wandpanel: Strichliste im Vollbild anzeigen' `
        -Action (New-WallInteractiveAction -ActionName 'Kiosk') `
        -Trigger @($kioskLogon, $kioskWatch) `
        -Principal (New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited) `
        -Settings $kioskSettings | Out-Null

    Write-Host ('Aufgabe       : {0}{1} (bei Anmeldung und alle 5 Minuten)' -f $tasks.Path, $tasks.Kiosk) -ForegroundColor Green
    Write-Host ('Anzeige       : {0}' -f $config.KioskUrl) -ForegroundColor Green

    $kioskBrowser = Get-KioskBrowserPath -Preferred ([string]$config.KioskBrowser)
    if ($kioskBrowser) {
        Write-Host ('Browser       : {0}' -f $kioskBrowser) -ForegroundColor Green
    } else {
        Write-Host 'Browser       : chrome.exe nicht gefunden. Chrome installieren oder -BrowserPath angeben.' -ForegroundColor Red
    }
}

Write-WallLog ('Einrichtung abgeschlossen: Modus {0}, Konto {1}.' -f $config.Mode, $UserId)


# -------------------------------------------------------------------- 5. Pruefung

Write-Host ''
$states = Get-SleepStateSupport
Write-Host ('Schlafzustaende laut powercfg /a : {0}' -f $(if (@($states.Available).Count) { ($states.Available -join ', ') } else { 'unbekannt' }))
if ($states.SupportsStandby -eq $false) {
    Write-Host 'WARNUNG: Das Geraet meldet keinen verfuegbaren Standby-Zustand. Bitte im BIOS/UEFI S3 freigeben, sonst bleibt es beim ausgeschalteten Bildschirm.' -ForegroundColor Red
}
if ($states.ModernStandby) {
    Write-Host 'HINWEIS: Das Geraet nutzt Modern Standby (S0). Der Selbsttest ist hier besonders wichtig.' -ForegroundColor Yellow
}

$wakeTimers = Get-WakeTimerSetting
if ($wakeTimers -eq $false) {
    Write-Host 'WARNUNG: Aufwachzeitgeber sind deaktiviert, obwohl sie gerade gesetzt wurden. Bitte Gruppenrichtlinien pruefen.' -ForegroundColor Red
}

Write-Host ''
Write-Host 'Naechster Schritt: Selbsttest ausfuehren, um das Aufwachen zu pruefen.' -ForegroundColor Cyan
Write-Host ('  powershell -ExecutionPolicy Bypass -File "{0}" -Action SelfTest' -f $paths.ScriptFile)
Write-Host ''
Write-Host 'Status jederzeit abrufen:' -ForegroundColor Cyan
Write-Host ('  powershell -ExecutionPolicy Bypass -File "{0}" -Action Status' -f $paths.ScriptFile)
Write-Host ''
