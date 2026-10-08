<#
.SYNOPSIS
    Richtet die Energiesteuerung fuer das Wand-Touchpanel ein.

.DESCRIPTION
    Legt die Konfiguration unter C:\ProgramData\WallDisplayPower ab, setzt die
    Energieoptionen fuer den Dauerbetrieb und registriert drei geplante Aufgaben:

      \WallDisplayPower\Sleep      zur Schlafenszeit, laeuft in der Sitzung des
                                   angemeldeten Benutzers (nur dort kann der
                                   Bildschirm abgeschaltet werden)
      \WallDisplayPower\WakeTimer  eine Minute vor der Weckzeit, laeuft als
                                   SYSTEM und holt das Geraet per
                                   Aufwachzeitgeber aus dem Standby
      \WallDisplayPower\Wake       zur Weckzeit, schaltet den Bildschirm ein

.PARAMETER SleepTime
    Uhrzeit, ab der das Panel schlafen soll, Format HH:mm. Ohne Angabe bleibt
    der Wert aus der Konfiguration erhalten.

.PARAMETER WakeTime
    Uhrzeit, zu der das Panel wieder laufen soll, Format HH:mm.

.PARAMETER Mode
    Combined    Bildschirm aus, danach Standby (Standard)
    DisplayOnly nur Bildschirm aus, kein Standby
    SuspendOnly sofort Standby ohne Vorlauf

.PARAMETER UserId
    Benutzerkonto, in dessen Sitzung das Panel laeuft (das Autologon-Konto).
    Standard ist das Konto, das Install.ps1 ausfuehrt.

.PARAMETER KeepHibernate
    Laesst den Ruhezustand aktiv. Standard ist, ihn abzuschalten, damit das
    Geraet wirklich in den Standby und nicht in den Ruhezustand geht.

.PARAMETER ServerUrl
    Adresse des Steuerungsservers, z. B. https://panel.example.org. Damit
    kommt eine vierte Aufgabe hinzu, die den Zeitplan regelmaessig abholt.
    Ohne diesen Parameter laeuft das Panel rein mit der lokalen Konfiguration.

.PARAMETER PanelId
    Kennung dieses Panels auf dem Server. Standard ist der Computername.

.PARAMETER ApiToken
    Gemeinsames Token der Panel-Schnittstelle (PANEL_TOKEN des Servers).

.PARAMETER PollMinutes
    Abstand der Abfragen. Standard 5 Minuten.

.PARAMETER AllowInsecureHttp
    Erlaubt http statt https. Nur fuer Tests im eigenen Netz.

.EXAMPLE
    .\Install.ps1 -SleepTime 22:00 -WakeTime 06:00

.EXAMPLE
    .\Install.ps1 -SleepTime 21:30 -WakeTime 07:00 -UserId 'PANEL-PC\kiosk'

.EXAMPLE
    .\Install.ps1 -ServerUrl https://panel.example.org -PanelId pfarrheim -ApiToken 'geheim'
#>
[CmdletBinding()]
param(
    [string]$SleepTime,
    [string]$WakeTime,
    [ValidateSet('Combined', 'DisplayOnly', 'SuspendOnly')][string]$Mode,
    [string]$UserId,
    [switch]$KeepHibernate,

    [string]$ServerUrl,
    [string]$PanelId,
    [string]$ApiToken,
    [ValidateRange(1, 60)][int]$PollMinutes = 5,
    [switch]$AllowInsecureHttp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\WallDisplay.Core.psm1') -Force -DisableNameChecking

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
if ($PSBoundParameters.ContainsKey('SleepTime')) { ConvertTo-TimeOfDay $SleepTime | Out-Null; $overrides['SleepTime'] = $SleepTime }
if ($PSBoundParameters.ContainsKey('WakeTime'))  { ConvertTo-TimeOfDay $WakeTime  | Out-Null; $overrides['WakeTime']  = $WakeTime }
if ($PSBoundParameters.ContainsKey('Mode'))      { $overrides['Mode'] = $Mode }

$configFile = Save-WallConfig -Values $overrides
$config = Get-WallConfig

if ($config.SleepTime -eq $config.WakeTime) {
    throw 'Schlafenszeit und Weckzeit duerfen nicht identisch sein.'
}

Write-Host ''
Write-Host '=== Einrichtung Wand-Display Energiesteuerung ===' -ForegroundColor Cyan
Write-Host ('Konfiguration : {0}' -f $configFile)
Write-Host ('Schlafen ab   : {0}' -f $config.SleepTime)
Write-Host ('Aufwachen um  : {0}' -f $config.WakeTime)
Write-Host ('Modus         : {0}' -f $config.Mode)


# ------------------------------------------------------------ 2. Energieoptionen

Set-WallPowerPolicy -DisableHibernate:(-not $KeepHibernate)


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

# New-WallDailyTrigger liegt im Modul, weil der Abgleich (Action Sync) die
# Startzeiten ebenfalls nachzieht.

$sleepAt = ([datetime]::Today).Add($config.SleepTimeOfDay)
$wakeAt  = ([datetime]::Today).Add($config.WakeTimeOfDay)
$prewakeAt = $wakeAt.AddMinutes(-[double]$config.WakePreRollMinutes)

$interactivePrincipal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest
$systemPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

# Nacht-Aufgabe: laeuft moeglicherweise die ganze Nacht (Nachkontrolle des
# Bildschirms), darum kein Zeitlimit und kein Nachholen bei verpasstem Start.
$sleepSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd `
    -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew
$sleepSettings.StartWhenAvailable = $false

Register-ScheduledTask -TaskPath $tasks.Path -TaskName $tasks.Sleep -Force `
    -Description 'Wandpanel: Bildschirm aus und Energiesparmodus zur Nachtzeit' `
    -Action (New-WallInteractiveAction -ActionName 'Sleep') `
    -Trigger (New-WallDailyTrigger -At $sleepAt) `
    -Principal $interactivePrincipal -Settings $sleepSettings | Out-Null
Write-Host ('Aufgabe       : {0}{1} taeglich {2:HH:mm}' -f $tasks.Path, $tasks.Sleep, $sleepAt) -ForegroundColor Green

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
    -Trigger (New-WallDailyTrigger -At $prewakeAt) `
    -Principal $systemPrincipal -Settings $prewakeSettings | Out-Null
Write-Host ('Aufgabe       : {0}{1} taeglich {2:HH:mm} (weckt das Geraet)' -f $tasks.Path, $tasks.Prewake, $prewakeAt) -ForegroundColor Green

# Weck-Aufgabe in der Benutzersitzung: schaltet den Bildschirm ein. Zusaetzlich
# ebenfalls mit Aufwachzeitgeber, als zweite Absicherung. StartWhenAvailable
# bleibt an, damit ein verpasstes Aufwachen erkannt und protokolliert wird.
$wakeSettings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([timespan]::FromMinutes(5)) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskPath $tasks.Path -TaskName $tasks.Wake -Force `
    -Description 'Wandpanel: Bildschirm zur Weckzeit einschalten' `
    -Action (New-WallInteractiveAction -ActionName 'Wake') `
    -Trigger (New-WallDailyTrigger -At $wakeAt) `
    -Principal $interactivePrincipal -Settings $wakeSettings | Out-Null
Write-Host ('Aufgabe       : {0}{1} taeglich {2:HH:mm}' -f $tasks.Path, $tasks.Wake, $wakeAt) -ForegroundColor Green

# Abgleich-Aufgabe als SYSTEM: holt den Zeitplan vom Server und bringt den
# Zustand in Deckung. Als SYSTEM, weil das Aendern der Aufgaben-Startzeiten
# Administratorrechte braucht.
if ($PSBoundParameters.ContainsKey('ServerUrl') -and -not [string]::IsNullOrWhiteSpace($ServerUrl)) {
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

    # Taeglicher Ausloeser um 00:00 mit Wiederholung, damit der Abgleich rund um
    # die Uhr laeuft und einen Neustart ohne Zutun uebersteht.
    $syncTrigger = New-WallDailyTrigger -At ([datetime]::Today)
    $syncTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At ([datetime]::Today) `
        -RepetitionInterval (New-TimeSpan -Minutes $PollMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 1)).Repetition

    $syncSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([timespan]::FromMinutes(10)) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskPath $tasks.Path -TaskName $tasks.Sync -Force `
        -Description 'Wandpanel: Zeitplan vom Server holen und Zustand abgleichen' `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Sync' -f $paths.ScriptFile)) `
        -Trigger $syncTrigger -Principal $systemPrincipal -Settings $syncSettings | Out-Null
    Write-Host ('Aufgabe       : {0}{1} alle {2} Minuten' -f $tasks.Path, $tasks.Sync, $PollMinutes) -ForegroundColor Green
} else {
    $existing = Get-WallTask -Name $tasks.Sync
    if ($existing) {
        Write-Host ('Aufgabe       : {0}{1} bleibt unveraendert (keine -ServerUrl angegeben)' -f $tasks.Path, $tasks.Sync) -ForegroundColor DarkGray
    } else {
        Write-Host 'Fernsteuerung : nicht eingerichtet (ohne -ServerUrl laeuft das Panel rein lokal)' -ForegroundColor DarkGray
    }
}

Write-WallLog ('Einrichtung abgeschlossen: Schlafen {0}, Aufwachen {1}, Modus {2}, Konto {3}.' -f $config.SleepTime, $config.WakeTime, $config.Mode, $UserId)


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
