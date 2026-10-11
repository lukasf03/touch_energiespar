<#
    WallDisplay.Core
    Kernfunktionen fuer die Energiesteuerung eines Wand-Touchpanels:
    Bildschirm ein/aus, Standby, Konfiguration, Zustand, Protokoll.
#>

Set-StrictMode -Version Latest

$script:TaskPath     = '\WallDisplayPower\'
$script:TaskSleep    = 'Sleep'
$script:TaskWake     = 'Wake'
$script:TaskPrewake  = 'WakeTimer'
$script:TaskSync     = 'Sync'

# GUIDs der Energieoptionen (sprachunabhaengig)
$script:GuidSubSleep    = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
$script:GuidWakeTimers  = 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d'
$script:GuidHybridSleep = '94ac6d29-73ce-41a6-809f-6363ba21b47e'
$script:GuidSubNone     = 'fea3413e-7e05-4911-9a71-700331f1c294'
$script:GuidConsoleLock = '0e796bdb-100d-47d6-a2d5-f7d2daa51f51'

# Geraeteklasse "Netzwerkadapter". Auch das ist eine GUID und damit
# sprachunabhaengig - der angezeigte Klassenname ist uebersetzt.
$script:ClassGuidNet    = '4d36e972-e325-11ce-bfc1-08002be10318'

$script:AgentVersion = '1.1.0'

$script:WeekDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

$script:ScheduleDefault = @{
    Monday    = @{ On = '18:00'; Off = '22:00' }
    Tuesday   = @{ On = '18:00'; Off = '22:00' }
    Wednesday = @{ On = '18:00'; Off = '22:00' }
    Thursday  = @{ On = '18:00'; Off = '22:00' }
    Friday    = @{ On = '17:00'; Off = '02:00' }
    Saturday  = @{ On = '17:00'; Off = '02:00' }
    Sunday    = @{ On = '16:00'; Off = '23:00' }
}

$script:ConfigDefaults = @{
    Schedule                      = $script:ScheduleDefault
    Mode                          = 'Combined'
    Enabled                       = $true
    DisplayOffDelaySeconds        = 60
    WakePreRollMinutes            = 1
    WakeToleranceMinutes          = 10
    MaxWakeFailures               = 2
    MinimumSuspendSeconds         = 30
    MaxSuspendRetries             = 20
    KeepDisplayOffIntervalSeconds = 20
    StandbyRetryProbeSeconds      = 300
    LogRetentionBytes             = 2097152
}


# ---------------------------------------------------------------- Pfade

function Get-WallPaths {
    [CmdletBinding()]
    param()

    $root = Join-Path $env:ProgramData 'WallDisplayPower'
    [pscustomobject]@{
        DataRoot    = $root
        ConfigFile  = Join-Path $root 'config.json'
        SyncFile    = Join-Path $root 'sync.json'
        StateFile   = Join-Path $root 'state.json'
        LogFile     = Join-Path $root 'walldisplay.log'
        SignalFile  = Join-Path $root 'wake.signal'
        Template    = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json'
        ScriptFile  = Join-Path $PSScriptRoot 'WallDisplay.ps1'
        LauncherVbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
    }
}

function Confirm-WallDataRoot {
    $root = (Get-WallPaths).DataRoot
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $root
}


# ------------------------------------------------------------- Protokoll

function Write-WallLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [switch]$NoConsole
    )

    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $NoConsole) { Write-Host $line }

    try {
        $paths = Get-WallPaths
        Confirm-WallDataRoot | Out-Null

        $limit = [int]$script:ConfigDefaults.LogRetentionBytes
        if (Test-Path -LiteralPath $paths.LogFile) {
            $size = (Get-Item -LiteralPath $paths.LogFile).Length
            if ($size -gt $limit) {
                Move-Item -LiteralPath $paths.LogFile -Destination ($paths.LogFile + '.1') -Force
            }
        }
        Add-Content -LiteralPath $paths.LogFile -Value $line -Encoding utf8
    } catch {
        # Protokollieren darf die Steuerung nie zum Scheitern bringen.
    }
}

function Get-WallLogTail {
    [CmdletBinding()]
    param([int]$Lines = 25)

    $file = (Get-WallPaths).LogFile
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    return @(Get-Content -LiteralPath $file -Tail $Lines -Encoding utf8)
}


# ----------------------------------------------------------- Konfiguration

function Get-WallConfig {
    [CmdletBinding()]
    param()

    $cfg = @{}
    foreach ($key in $script:ConfigDefaults.Keys) { $cfg[$key] = $script:ConfigDefaults[$key] }

    $paths = Get-WallPaths
    $source = $null
    foreach ($candidate in @($paths.ConfigFile, $paths.Template)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $source = $candidate; break }
    }

    if ($source) {
        try {
            $json = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) {
                if ($cfg.ContainsKey($prop.Name)) { $cfg[$prop.Name] = $prop.Value }
            }
        } catch {
            Write-WallLog -Level WARN ("Konfiguration '{0}' ist unlesbar, es gelten die Standardwerte: {1}" -f $source, $_.Exception.Message)
        }
    }

    $cfg['SourceFile'] = $source

    try {
        $cfg['Windows'] = ConvertTo-WallSchedule -Raw $cfg['Schedule']
    } catch {
        Write-WallLog -Level ERROR ("Zeitplan unbrauchbar, es gilt der Standard: {0}" -f $_.Exception.Message)
        $cfg['Schedule'] = $script:ScheduleDefault
        $cfg['Windows'] = ConvertTo-WallSchedule -Raw $script:ScheduleDefault
    }

    if ($cfg['Mode'] -notin @('Combined', 'DisplayOnly', 'SuspendOnly')) {
        Write-WallLog -Level WARN ("Unbekannter Modus '{0}', es gilt 'Combined'." -f $cfg['Mode'])
        $cfg['Mode'] = 'Combined'
    }

    return [pscustomobject]$cfg
}

function ConvertTo-WallSchedule {
    <#
        Prueft und normalisiert den Wochenplan.

        Ergebnis ist eine Tabelle Wochentag -> @{ On; Off; CrossesMidnight }
        mit TimeSpan-Werten. Tage ohne Fenster fehlen darin.

        'Off' kleiner oder gleich 'On' bedeutet: das Fenster reicht ueber
        Mitternacht in den Folgetag (Freitag 17:00 bis Samstag 02:00).
        Sind beide gleich, gilt der Tag als aus - ein Fenster der Laenge null
        waere sonst nicht von "den ganzen Tag an" zu unterscheiden.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Raw)

    if ($null -eq $Raw) { throw 'Zeitplan fehlt.' }

    $windows = [ordered]@{}
    foreach ($day in $script:WeekDays) {
        $entry = Get-RawField -Object $Raw -Name $day
        if ($null -eq $entry) { continue }

        $onText = Get-RawField -Object $entry -Name 'On'
        $offText = Get-RawField -Object $entry -Name 'Off'
        if ($null -eq $onText -or $null -eq $offText) {
            throw "Zeitplan fuer $day hat kein On/Off."
        }

        $on = ConvertTo-TimeOfDay ([string]$onText)
        $off = ConvertTo-TimeOfDay ([string]$offText)
        if ($on -eq $off) { continue }

        $windows[$day] = @{
            On              = $on
            Off             = $off
            CrossesMidnight = ($off -lt $on)
        }
    }

    if ($windows.Count -eq 0) { throw 'Zeitplan enthaelt kein einziges Fenster.' }
    return $windows
}

function Test-ActiveWindow {
    <#
        Liegt der Zeitpunkt in einem Aktiv-Fenster, soll das Panel also an sein?
        Beruecksichtigt auch das Fenster des Vortages, wenn es ueber
        Mitternacht reicht.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Windows,
        [datetime]$Now = (Get-Date)
    )

    $time = $Now.TimeOfDay

    $today = $Windows[[string]$Now.DayOfWeek]
    if ($today) {
        if ($today.CrossesMidnight) {
            if ($time -ge $today.On) { return $true }
        } elseif ($time -ge $today.On -and $time -lt $today.Off) {
            return $true
        }
    }

    $yesterday = $Windows[[string]$Now.AddDays(-1).DayOfWeek]
    if ($yesterday -and $yesterday.CrossesMidnight -and $time -lt $yesterday.Off) {
        return $true
    }

    return $false
}

function Get-NextWindowStart {
    <#
        Naechster Zeitpunkt, zu dem das Panel an sein soll. $null, wenn der
        Zeitplan gar kein Fenster enthaelt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Windows,
        [datetime]$From = (Get-Date)
    )

    for ($offset = 0; $offset -le 7; $offset++) {
        $day = $From.Date.AddDays($offset)
        $window = $Windows[[string]$day.DayOfWeek]
        if (-not $window) { continue }

        $candidate = $day.Add($window.On)
        if ($candidate -gt $From) { return $candidate }
    }
    return $null
}

function Get-CurrentWindowEnd {
    <#
        Ende des gerade laufenden Aktiv-Fensters. $null, wenn gerade keines
        laeuft.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Windows,
        [datetime]$Now = (Get-Date)
    )

    $time = $Now.TimeOfDay

    $today = $Windows[[string]$Now.DayOfWeek]
    if ($today) {
        if ($today.CrossesMidnight -and $time -ge $today.On) {
            return $Now.Date.AddDays(1).Add($today.Off)
        }
        if (-not $today.CrossesMidnight -and $time -ge $today.On -and $time -lt $today.Off) {
            return $Now.Date.Add($today.Off)
        }
    }

    $yesterday = $Windows[[string]$Now.AddDays(-1).DayOfWeek]
    if ($yesterday -and $yesterday.CrossesMidnight -and $time -lt $yesterday.Off) {
        return $Now.Date.Add($yesterday.Off)
    }

    return $null
}

function Get-ScheduleFingerprint {
    <#
        Kurzer Fingerabdruck des Wochenplans. Damit laesst sich feststellen, ob
        die Startzeiten der Aufgaben noch zum Zeitplan passen, ohne jeden
        einzelnen Ausloeser vergleichen zu muessen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Config)

    $parts = foreach ($day in $script:WeekDays) {
        $window = $Config.Windows[$day]
        if ($window) { '{0}={1:hh\:mm}-{2:hh\:mm}' -f $day, $window.On, $window.Off } else { "$day=-" }
    }
    $text = ($parts -join ';') + ';preroll=' + [int]$Config.WakePreRollMinutes

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        return ([BitConverter]::ToString($hash) -replace '-').Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}

function Save-WallConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Values)

    Confirm-WallDataRoot | Out-Null
    $paths = Get-WallPaths

    $current = @{}
    if (Test-Path -LiteralPath $paths.ConfigFile) {
        $json = Get-Content -LiteralPath $paths.ConfigFile -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($prop in $json.PSObject.Properties) { $current[$prop.Name] = $prop.Value }
    } elseif (Test-Path -LiteralPath $paths.Template) {
        $json = Get-Content -LiteralPath $paths.Template -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($prop in $json.PSObject.Properties) { $current[$prop.Name] = $prop.Value }
    } else {
        foreach ($key in $script:ConfigDefaults.Keys) { $current[$key] = $script:ConfigDefaults[$key] }
    }

    foreach ($key in $Values.Keys) { $current[$key] = $Values[$key] }

    ([pscustomobject]$current | ConvertTo-Json -Depth 4) |
        Set-Content -LiteralPath $paths.ConfigFile -Encoding utf8
    return $paths.ConfigFile
}

function ConvertTo-TimeOfDay {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $parsed = [datetime]::MinValue
    [string[]]$formats = @('HH:mm', 'H:mm', 'HH:mm:ss', 'H:mm:ss')
    if (-not [datetime]::TryParseExact($Text, $formats, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        throw "Uhrzeit '$Text' ist ungueltig. Erwartet wird das Format HH:mm, zum Beispiel 22:00."
    }
    return $parsed.TimeOfDay
}

function ConvertFrom-WallUtc {
    <#
        Wandelt einen gespeicherten UTC-Zeitstempel (Format 'o') in Ortszeit um.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Text)

    if (-not $Text) { return $null }
    try {
        $parsed = [datetime]::Parse([string]$Text, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $parsed.ToLocalTime()
    } catch {
        return $null
    }
}

function Get-NextOccurrence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][timespan]$TimeOfDay,
        [datetime]$From = (Get-Date)
    )

    $candidate = $From.Date.Add($TimeOfDay)
    if ($candidate -le $From) { $candidate = $candidate.AddDays(1) }
    return $candidate
}

function Test-InsideSleepWindow {
    <#
        Entscheidet, ob das Panel gerade schlafen soll.

        Grundregel: Der Wochenplan beschreibt die Zeiten, zu denen das Panel AN
        ist. Ausserhalb dieser Fenster schlaeft es.

        Reihenfolge der Auswertung (die erste zutreffende Regel gewinnt):
          1. Befehl 'sleep-now' laeuft noch  -> schlafen
          2. Zeitplan ist abgeschaltet       -> wach (Panel laeuft durch)
          3. Befehl 'wake-now' laeuft noch   -> wach
          4. Server-Uebersteuerung aktiv     -> wach
          5. Zeitpunkt liegt in einem Fenster -> wach, sonst schlafen
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][psobject]$State,
        [datetime]$Now = (Get-Date)
    )

    $commandSleep = ConvertFrom-WallUtc $State.CommandSleepUntilUtc
    if ($commandSleep -and $Now -lt $commandSleep) { return $true }

    if (-not $Config.Enabled) { return $false }

    foreach ($value in @($State.CommandAwakeUntilUtc, $State.ForceAwakeUntilUtc)) {
        $until = ConvertFrom-WallUtc $value
        if ($until -and $Now -lt $until) { return $false }
    }

    return (-not (Test-ActiveWindow -Windows $Config.Windows -Now $Now))
}

function Test-WallNightMode {
    <#
        Wie Test-InsideSleepWindow, liest Konfiguration und Zustand aber selbst.
        Dadurch wirkt eine von aussen geaenderte Zeit noch in derselben Nacht,
        weil die laufenden Schleifen in jedem Durchlauf neu nachfragen.
    #>
    [CmdletBinding()]
    param([datetime]$Now = (Get-Date))

    return Test-InsideSleepWindow -Config (Get-WallConfig) -State (Get-WallState) -Now $Now
}


# ---------------------------------------------------------------- Zustand

function Get-WallState {
    [CmdletBinding()]
    param()

    $state = @{
        EffectiveMode           = $null
        ExpectedWakeUtc         = $null
        LastSuspendAttemptUtc   = $null
        LastWakeUtc             = $null
        LastPrewakeUtc          = $null
        LastWakeDelayMinutes    = $null
        ConsecutiveWakeFailures = 0
        FallbackReason          = $null
        DisplayState            = 'unknown'

        # Uebersteuerungen. Reihenfolge der Auswertung siehe Test-InsideSleepWindow.
        ForceAwakeUntilUtc      = $null   # vom Server (keepAwakeUntil)
        CommandAwakeUntilUtc    = $null   # durch Befehl 'wake-now'
        CommandSleepUntilUtc    = $null   # durch Befehl 'sleep-now'
        LastCommandId           = $null

        # Fingerabdruck des Wochenplans, zu dem die Aufgaben-Ausloeser zuletzt
        # gesetzt wurden. Passt er nicht mehr, wird kein Standby gewagt.
        TaskScheduleFingerprint = $null

        # Wochenplan, fuer den der Abgleich zuletzt versucht hat, die
        # Ausloeser nachzuziehen, und wie oft. Damit wird ein dauerhaft
        # misslingender Versuch nicht alle paar Minuten wiederholt.
        TriggerRepairFingerprint = $null
        TriggerRepairAttempts    = 0

        # Geraete, denen die Einrichtung das Weckrecht genommen hat. Nur die
        # gibt die Deinstallation wieder frei - alles andere waere ein Eingriff
        # in Einstellungen, die die Steuerung nie angefasst hat.
        DisabledWakeDevices     = @()

        SyncLastSuccessUtc      = $null
        SyncConsecutiveFailures = 0
        SyncLastError           = $null
    }

    $file = (Get-WallPaths).StateFile
    if (Test-Path -LiteralPath $file) {
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
        } catch {
            Write-WallLog -Level WARN ("Zustandsdatei ist unlesbar und wird neu angelegt: {0}" -f $_.Exception.Message)
        }
    }
    return [pscustomobject]$state
}

function Save-WallState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$State)

    Confirm-WallDataRoot | Out-Null
    $file = (Get-WallPaths).StateFile
    try {
        ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $file -Encoding utf8
    } catch {
        Write-WallLog -Level WARN ("Zustand konnte nicht gespeichert werden: {0}" -f $_.Exception.Message)
    }
}

function Resolve-EffectiveMode {
    <#
        Der konfigurierte Modus gilt, solange er nicht wegen fehlgeschlagener
        Standby-Versuche automatisch auf 'DisplayOnly' zurueckgestuft wurde.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][psobject]$State
    )

    if ($State.EffectiveMode -eq 'DisplayOnly' -and $Config.Mode -ne 'DisplayOnly') {
        return 'DisplayOnly'
    }
    return $Config.Mode
}

function Set-FallbackMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Reason
    )

    $state = Get-WallState
    $state.EffectiveMode = 'DisplayOnly'
    $state.FallbackReason = $Reason
    Save-WallState $state
    Write-WallLog -Level WARN ("Automatische Rueckstufung auf 'Nur Bildschirm aus'. Grund: {0} Zuruecksetzen mit: WallDisplay.ps1 -Action Reset" -f $Reason)
}

function Register-WakeFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][string]$Reason
    )

    $state = Get-WallState
    $count = [int]$state.ConsecutiveWakeFailures + 1
    $state.ConsecutiveWakeFailures = $count
    $state.FallbackReason = $Reason
    Save-WallState $state

    $max = [int]$Config.MaxWakeFailures
    Write-WallLog -Level WARN ("Aufwach-Problem {0}/{1}: {2}" -f $count, $max, $Reason)
    if ($count -ge $max) {
        Set-FallbackMode -Reason ("{0} (nach {1} Versuchen)" -f $Reason, $count)
    }
}

function Register-WakeSuccess {
    [CmdletBinding()]
    param([double]$DelayMinutes = 0)

    $state = Get-WallState
    $state.ConsecutiveWakeFailures = 0
    $state.LastWakeDelayMinutes = [math]::Round($DelayMinutes, 1)
    Save-WallState $state
}


# ------------------------------------------------------- Weck-Signaldatei

function New-WallSignal {
    Confirm-WallDataRoot | Out-Null
    Set-Content -LiteralPath (Get-WallPaths).SignalFile -Value ((Get-Date).ToString('o')) -Encoding utf8
}

function Remove-WallSignal {
    $file = (Get-WallPaths).SignalFile
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

function Test-WallSignal {
    return (Test-Path -LiteralPath (Get-WallPaths).SignalFile)
}

function Wait-WallInterval {
    <#
        Wartet die angegebene Zeit in kleinen Schritten.
        Rueckgabe $false, sobald ein Weck-Signal vorliegt (Warten abgebrochen).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Seconds)

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-WallSignal) { return $false }
        $remaining = ($deadline - (Get-Date)).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([math]::Min(2000, [int]($remaining * 1000)))
    }
    return -not (Test-WallSignal)
}


# ------------------------------------------------------- Win32-Schnittstelle

function Initialize-WallNative {
    [CmdletBinding()]
    param()

    if ('WallDisplay.Native' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WallDisplay
{
    public static class Native
    {
        private const int  HWND_BROADCAST   = 0xFFFF;
        private const uint WM_SYSCOMMAND    = 0x0112;
        private const int  SC_MONITORPOWER  = 0xF170;
        private const int  MONITOR_OFF      = 2;
        private const int  MONITOR_ON       = -1;
        private const uint SMTO_ABORTIFHUNG = 0x0002;

        private const uint ES_DISPLAY_REQUIRED = 0x00000002;

        private const uint INPUT_MOUSE      = 0;
        private const uint MOUSEEVENTF_MOVE = 0x0001;

        private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
        private const uint TOKEN_QUERY             = 0x0008;
        private const uint SE_PRIVILEGE_ENABLED    = 0x0002;

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            public uint type;
            public MOUSEINPUT mi;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID
        {
            public uint LowPart;
            public int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID_AND_ATTRIBUTES
        {
            public LUID Luid;
            public uint Attributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_PRIVILEGES
        {
            public uint PrivilegeCount;
            public LUID_AND_ATTRIBUTES Privileges;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
                                                        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        [DllImport("kernel32.dll")]
        private static extern uint SetThreadExecutionState(uint esFlags);

        [DllImport("powrprof.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(IntPtr tokenHandle, bool disableAllPrivileges,
                                                         ref TOKEN_PRIVILEGES newState, uint bufferLength,
                                                         IntPtr previousState, IntPtr returnLength);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        private static void MonitorPower(int level)
        {
            IntPtr result;
            SendMessageTimeout(new IntPtr(HWND_BROADCAST), WM_SYSCOMMAND, new IntPtr(SC_MONITORPOWER),
                               new IntPtr(level), SMTO_ABORTIFHUNG, 2000, out result);
        }

        public static void DisplayOff()
        {
            MonitorPower(MONITOR_OFF);
        }

        public static void DisplayOn()
        {
            // Erst den Leerlauf-Zaehler des Displays zuruecksetzen, dann das
            // Panel einschalten, danach eine minimale Mausbewegung als Reserve.
            SetThreadExecutionState(ES_DISPLAY_REQUIRED);
            MonitorPower(MONITOR_ON);
            NudgePointer();
        }

        private static void NudgePointer()
        {
            INPUT[] inputs = new INPUT[2];
            inputs[0].type = INPUT_MOUSE;
            inputs[0].mi.dx = 1;
            inputs[0].mi.dwFlags = MOUSEEVENTF_MOVE;
            inputs[1].type = INPUT_MOUSE;
            inputs[1].mi.dx = -1;
            inputs[1].mi.dwFlags = MOUSEEVENTF_MOVE;
            SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
        }

        public static bool Suspend()
        {
            EnableShutdownPrivilege();
            return SetSuspendState(false, false, false);
        }

        private static void EnableShutdownPrivilege()
        {
            IntPtr token = IntPtr.Zero;
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
            {
                return;
            }
            try
            {
                LUID luid;
                if (!LookupPrivilegeValue(null, "SeShutdownPrivilege", out luid))
                {
                    return;
                }
                TOKEN_PRIVILEGES privileges = new TOKEN_PRIVILEGES();
                privileges.PrivilegeCount = 1;
                privileges.Privileges.Luid = luid;
                privileges.Privileges.Attributes = SE_PRIVILEGE_ENABLED;
                AdjustTokenPrivileges(token, false, ref privileges,
                                      (uint)Marshal.SizeOf(typeof(TOKEN_PRIVILEGES)), IntPtr.Zero, IntPtr.Zero);
            }
            finally
            {
                CloseHandle(token);
            }
        }
    }
}
'@
}

function Set-DisplayPower {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('On', 'Off')][string]$State,
        [switch]$Quiet
    )

    Initialize-WallNative
    if ($State -eq 'Off') {
        [WallDisplay.Native]::DisplayOff()
        if (-not $Quiet) { Write-WallLog 'Bildschirm ausgeschaltet.' }
    } else {
        [WallDisplay.Native]::DisplayOn()
        if (-not $Quiet) { Write-WallLog 'Bildschirm eingeschaltet.' }
    }

    # Der Zustand wird festgehalten, damit der Abgleich (Action Sync) erkennt,
    # ob der Bildschirm zur Tageszeit faelschlich aus ist.
    $wanted = $State.ToLowerInvariant()
    $current = Get-WallState
    if ($current.DisplayState -ne $wanted) {
        $current.DisplayState = $wanted
        Save-WallState $current
    }
}

function Invoke-SystemSuspend {
    <#
        Versetzt das Geraet in den Energiesparmodus. Der Aufruf kehrt erst
        zurueck, wenn das Geraet wieder aufgewacht ist.
    #>
    [CmdletBinding()]
    param()

    Initialize-WallNative
    try {
        return [WallDisplay.Native]::Suspend()
    } catch {
        Write-WallLog -Level ERROR ("Standby-Aufruf fehlgeschlagen: {0}" -f $_.Exception.Message)
        return $false
    }
}


# ------------------------------------------------------------- Energieoptionen

function Get-SleepStateSupport {
    <#
        Liest aus 'powercfg /a' die verfuegbaren Schlafzustaende.

        Die Ausgabe von powercfg ist uebersetzt, die Kennungen S0..S4 sind es
        nicht. Ausgewertet wird darum ausschliesslich die Struktur (erster
        Abschnitt = verfuegbar) und diese Kennungen - die Systemsprache spielt
        keine Rolle.

        -Raw dient dem Test: damit laesst sich die Auswertung gegen Ausgaben
        verschiedener Sprachen pruefen, ohne das System umzustellen.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Raw)

    if ($PSBoundParameters.ContainsKey('Raw')) {
        $raw = [string]$Raw
    } else {
        try {
            $raw = (& powercfg.exe /a) -join "`n"
        } catch {
            return [pscustomobject]@{ Raw = ''; Available = @(); SupportsStandby = $null; ModernStandby = $null }
        }
    }

    # Auswertung rein ueber die Struktur, damit die Sprache keine Rolle spielt:
    #
    #   Ueberschrift (nicht eingerueckt)
    #       Standby (S3)                          <- verfuegbar
    #   Ueberschrift (nicht eingerueckt)
    #       Standby (S1)                          <- nicht verfuegbar,
    #           <Begruendung, tiefer eingerueckt>    erkennbar an der
    #                                                Begruendungszeile
    #
    # Beide Merkmale muessen zutreffen: erster Abschnitt UND keine
    # Begruendungszeile. Gibt es gar keinen verfuegbaren Zustand, besteht die
    # Ausgabe nur aus dem zweiten Abschnitt - dann darf nichts als verfuegbar
    # gelten, sonst wuerde das Panel einen Standby versuchen, den das Geraet
    # nicht beherrscht.
    $lines = @($raw -split "`r?`n")
    $available = New-Object System.Collections.Generic.List[string]
    $headerCount = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^\s') { $headerCount++; continue }
        if ($headerCount -ne 1) { continue }

        $indent = $line.Length - $line.TrimStart().Length
        $hasReason = $false
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ([string]::IsNullOrWhiteSpace($lines[$j])) { continue }
            $nextIndent = $lines[$j].Length - $lines[$j].TrimStart().Length
            $hasReason = ($nextIndent -gt $indent)
            break
        }
        if ($hasReason) { continue }

        if ($line -match '\bS([0-4])\b') { $available.Add('S' + $Matches[1]) }
    }

    $modern = $available -contains 'S0'
    $classic = @('S1', 'S2', 'S3') | Where-Object { $available -contains $_ }

    [pscustomobject]@{
        Raw             = $raw
        Available       = @($available | Select-Object -Unique)
        SupportsStandby = ($modern -or @($classic).Count -gt 0)
        ModernStandby   = $modern
    }
}

function Get-WakeTimerSetting {
    <#
        Liest die Einstellung "Aufwachzeitgeber zulassen" des aktiven
        Energieschemas ueber WMI (sprachunabhaengig).
        Rueckgabe: $true / $false / $null (nicht ermittelbar)
    #>
    [CmdletBinding()]
    param()

    try {
        $entries = Get-CimInstance -Namespace 'root\cimv2\power' -ClassName 'Win32_PowerSettingDataIndex' -ErrorAction Stop |
            Where-Object { $_.InstanceID -like ('*' + $script:GuidWakeTimers + '*') -and $_.InstanceID -like '*\AC\*' }

        $active = $null
        try {
            $plan = Get-CimInstance -Namespace 'root\cimv2\power' -ClassName 'Win32_PowerPlan' -Filter 'IsActive = True' -ErrorAction Stop
            if ($plan -and $plan.InstanceID -match '\{([0-9a-fA-F-]+)\}') { $active = $Matches[1] }
        } catch { }

        if ($active) {
            $match = $entries | Where-Object { $_.InstanceID -like ('*' + $active + '*') } | Select-Object -First 1
            if ($match) { return ([int]$match.SettingIndexValue -ne 0) }
        }
        $first = $entries | Select-Object -First 1
        if ($first) { return ([int]$first.SettingIndexValue -ne 0) }
    } catch { }
    return $null
}

function Get-ConsoleLockSetting {
    <#
        Verlangt Windows nach dem Aufwachen eine Anmeldung?
        $true  = ja, das Panel zeigt dann den Sperrbildschirm
        $false = nein (so soll es sein)
        $null  = nicht ermittelbar
    #>
    [CmdletBinding()]
    param()

    try {
        $entry = Get-CimInstance -Namespace 'root\cimv2\power' -ClassName 'Win32_PowerSettingDataIndex' -ErrorAction Stop |
            Where-Object { $_.InstanceID -like ('*' + $script:GuidConsoleLock + '*') -and $_.InstanceID -like '*\AC\*' } |
            Select-Object -First 1
        if ($entry) { return ([int]$entry.SettingIndexValue -ne 0) }
    } catch { }
    return $null
}

function Set-WallPowerPolicy {
    <#
        Legt die Energieoptionen fuer den Dauerbetrieb eines Wandpanels fest:
        keine automatischen Zeitueberschreitungen, Aufwachzeitgeber erlaubt,
        kein Hybrid-Standby.
    #>
    [CmdletBinding()]
    param([switch]$DisableHibernate)

    $commands = @(
        @('/change', 'monitor-timeout-ac', '0'),
        @('/change', 'monitor-timeout-dc', '0'),
        @('/change', 'standby-timeout-ac', '0'),
        @('/change', 'standby-timeout-dc', '0'),
        @('/change', 'hibernate-timeout-ac', '0'),
        @('/change', 'hibernate-timeout-dc', '0'),
        @('/setacvalueindex', 'SCHEME_CURRENT', $script:GuidSubSleep, $script:GuidWakeTimers, '1'),
        @('/setdcvalueindex', 'SCHEME_CURRENT', $script:GuidSubSleep, $script:GuidWakeTimers, '1'),
        @('/setacvalueindex', 'SCHEME_CURRENT', $script:GuidSubSleep, $script:GuidHybridSleep, '0'),
        @('/setdcvalueindex', 'SCHEME_CURRENT', $script:GuidSubSleep, $script:GuidHybridSleep, '0'),

        # Keine Anmeldung nach dem Aufwachen verlangen. Sonst zeigt das Panel
        # morgens den Sperrbildschirm statt der Strichliste, und die Aufgaben
        # in der Benutzersitzung koennen den Bildschirm nicht mehr schalten.
        @('/setacvalueindex', 'SCHEME_CURRENT', $script:GuidSubNone, $script:GuidConsoleLock, '0'),
        @('/setdcvalueindex', 'SCHEME_CURRENT', $script:GuidSubNone, $script:GuidConsoleLock, '0'),

        @('/setactive', 'SCHEME_CURRENT')
    )

    if ($DisableHibernate) {
        # Ruhezustand aus: verhindert, dass SetSuspendState in S4 geht, und
        # schaltet zugleich den Schnellstart ab.
        $commands = @(, @('/hibernate', 'off')) + $commands
    }

    foreach ($argumentList in $commands) {
        $output = & powercfg.exe @argumentList 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-WallLog -Level WARN ("powercfg {0} meldete Code {1}: {2}" -f ($argumentList -join ' '), $LASTEXITCODE, ($output -join ' '))
        }
    }
    Write-WallLog 'Energieoptionen fuer den Dauerbetrieb gesetzt.'
}


# --------------------------------------------------------- Weckrecht Geraete

function Get-WallDeviceQuery {
    <#
        Eine Abfrage 'powercfg /devicequery <Query>' als Liste von Namen.
        Leere Zeilen fallen weg. Scheitert der Aufruf, ist die Liste leer.

        -Raw dient dem Test ohne powercfg-Aufruf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [AllowNull()][string]$Raw,
        [switch]$HasRaw
    )

    if ($HasRaw) {
        $text = [string]$Raw
    } else {
        try {
            $text = (& powercfg.exe /devicequery $Query) -join "`n"
        } catch {
            Write-WallLog -Level WARN ("'powercfg /devicequery {0}' nicht ausfuehrbar: {1}" -f $Query, $_.Exception.Message)
            return @()
        }
    }

    return @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-WakeArmedDevices {
    <#
        Geraete, die das Panel aus dem Energiesparmodus holen duerfen.

        Der Aufwachzeitgeber der geplanten Aufgaben ist davon nicht betroffen:
        Die Uhr des Rechners ist kein Geraet und steht in dieser Liste nicht.

        Ist kein einziges Geraet weckberechtigt, gibt powercfg statt einer
        Liste eine uebersetzte Hinweiszeile aus ("NONE", "KEINE", ...). Sie
        wird auf zwei Wegen ausgesondert, beide ohne Vergleich mit
        uebersetztem Text:

          1. Jeder Name muss auch in 'wake_programmable' stehen - ein
             weckberechtigtes Geraet ist immer auch programmierbar.
          2. Mit -Map muss der Name zusaetzlich einem vorhandenen Geraet
             entsprechen. Noetig fuer den Fall, dass gar kein Geraet
             programmierbar ist: dann steht der Hinweistext in beiden Listen
             und Regel 1 allein greift nicht.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ArmedRaw,
        [AllowNull()][string]$ProgrammableRaw,
        [hashtable]$Map
    )

    $armed = @(Get-WallDeviceQuery -Query 'wake_armed' -Raw $ArmedRaw `
        -HasRaw:($PSBoundParameters.ContainsKey('ArmedRaw')))
    if ($armed.Count -eq 0) { return @() }

    $programmable = @(Get-WallDeviceQuery -Query 'wake_programmable' -Raw $ProgrammableRaw `
        -HasRaw:($PSBoundParameters.ContainsKey('ProgrammableRaw')))
    if ($programmable.Count -eq 0) { return @() }

    $names = @($armed | Where-Object { $programmable -contains $_ })

    # Ohne Geraeteliste bleibt es bei Regel 1 - besser eine unsichere Liste
    # als keine.
    if (-not $PSBoundParameters.ContainsKey('Map') -or $Map.Count -eq 0) { return $names }

    return @($names | Where-Object { Resolve-WallDeviceClass -Name $_ -Map $Map })
}

function Get-WallPnpClassMap {
    <#
        Tabelle Geraetename -> Klassen-GUID (ohne geschweifte Klammern).
        Leer, wenn sich die Geraeteliste nicht lesen laesst.
    #>
    [CmdletBinding()]
    param()

    $map = @{}
    try {
        foreach ($device in (Get-PnpDevice -PresentOnly -ErrorAction Stop)) {
            $name = [string]$device.FriendlyName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (-not $map.ContainsKey($name)) {
                $map[$name] = ([string]$device.ClassGuid).Trim('{', '}')
            }
        }
    } catch {
        Write-WallLog -Level WARN ("Geraeteklassen nicht ermittelbar: {0}" -f $_.Exception.Message)
    }
    return $map
}

function Resolve-WallDeviceClass {
    <#
        Klassen-GUID eines Geraets, $null wenn unbekannt.

        Kommt ein Geraetename mehrfach vor, haengt powercfg eine laufende
        Nummer an ("HID-Tastatur (002)"), die es in der Geraeteverwaltung nicht
        gibt. Fuer die Zuordnung wird sie darum abgeschnitten.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Map
    )

    if ($Map.ContainsKey($Name)) { return $Map[$Name] }

    $base = $Name -replace '\s+\(\d{1,4}\)$', ''
    if ($base -ne $Name -and $Map.ContainsKey($base)) { return $Map[$base] }

    return $null
}

function Disable-WallDeviceWake {
    <#
        Nimmt den weckberechtigten Geraeten das Recht, das Panel aus dem
        Energiesparmodus zu holen.

        Hintergrund: Ein Touchscreen ist in der Regel weckberechtigt. Ohne
        diesen Schritt holt jede Beruehrung das Panel nachts aus dem Standby.
        Die Steuerung legt es zwar wieder hin, aber jede Beruehrung kostet
        einen Aufwach- und Einschlafvorgang und zeigt die Seite dabei ein paar
        Sekunden lang.

        Netzwerkadapter bleiben ausgenommen, damit Wake-on-LAN weiter
        moeglich ist. Der Aufwachzeitgeber ist ohnehin nicht betroffen.

        Rueckgabe: Namen der Geraete, denen das Recht genommen wurde - damit
        die Deinstallation genau diese wieder freigeben kann.
    #>
    [CmdletBinding()]
    param([switch]$IncludeNetwork)

    $map = Get-WallPnpClassMap
    if ($map.Count -eq 0) {
        # Ohne Geraeteliste laesst sich ein Netzwerkadapter nicht erkennen.
        # Das Weckrecht wird trotzdem entzogen - der Zweck der Uebung ist, dass
        # nur der Zeitgeber weckt - aber es steht im Protokoll, weil damit
        # Wake-on-LAN entfallen kann.
        Write-WallLog -Level WARN 'Geraeteklassen nicht verfuegbar: das Weckrecht wird allen Geraeten entzogen, auch Netzwerkadaptern. Wake-on-LAN entfaellt dadurch; einzelne Geraete bei Bedarf mit "powercfg /deviceenablewake" wieder freigeben.'
    }

    $armed = @(Get-WakeArmedDevices -Map $map)
    if ($armed.Count -eq 0) {
        Write-WallLog 'Kein Geraet darf das Panel aufwecken, nichts zu tun.'
        return @()
    }

    $disabled = New-Object System.Collections.Generic.List[string]

    foreach ($name in $armed) {
        $class = Resolve-WallDeviceClass -Name $name -Map $map

        if (-not $IncludeNetwork -and $class -eq $script:ClassGuidNet) {
            Write-WallLog ("Netzwerkadapter '{0}' bleibt weckberechtigt (Wake-on-LAN)." -f $name)
            continue
        }

        $output = & powercfg.exe /devicedisablewake $name
        if ($LASTEXITCODE -eq 0) {
            $disabled.Add($name)
            Write-WallLog ("Geraet '{0}' darf das Panel nicht mehr aufwecken." -f $name)
        } else {
            Write-WallLog -Level WARN ("Weckrecht von '{0}' nicht entziehbar (Code {1}): {2}" -f $name, $LASTEXITCODE, ($output -join ' '))
        }
    }

    return @($disabled)
}

function Enable-WallDeviceWake {
    <#
        Gibt das Weckrecht zurueck. Gegenstueck zu Disable-WallDeviceWake,
        gedacht fuer die Deinstallation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][string[]]$Names)

    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $output = & powercfg.exe /deviceenablewake $name
        if ($LASTEXITCODE -eq 0) {
            Write-WallLog ("Geraet '{0}' darf wieder aufwecken." -f $name)
        } else {
            Write-WallLog -Level WARN ("Weckrecht von '{0}' nicht wiederherstellbar (Code {1}): {2}" -f $name, $LASTEXITCODE, ($output -join ' '))
        }
    }
}


# ------------------------------------------------------------ Aufgabenplanung

function Get-WallTaskNames {
    [pscustomobject]@{
        Path    = $script:TaskPath
        Sleep   = $script:TaskSleep
        Wake    = $script:TaskWake
        Prewake = $script:TaskPrewake
        Sync    = $script:TaskSync
    }
}

function Get-WallTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    try {
        return Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $Name -ErrorAction Stop
    } catch {
        return $null
    }
}

function Stop-WallSleepTask {
    try {
        $task = Get-WallTask -Name $script:TaskSleep
        if ($task -and $task.State -eq 'Running') {
            Stop-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskSleep -ErrorAction Stop
            Write-WallLog 'Laufende Nacht-Aufgabe beendet.'
        }
    } catch {
        Write-WallLog -Level WARN ("Nacht-Aufgabe konnte nicht beendet werden: {0}" -f $_.Exception.Message)
    }
}

function Test-WakeTaskMatchesSchedule {
    <#
        Prueft, ob die Aufwach-Ausloeser noch zum Wochenplan passen.

        Noetig, weil der Zeitplan kurz vor dem Standby noch vom Server kommen
        kann. Liessen sich die Ausloeser dabei nicht nachziehen (etwa mangels
        Administratorrechten), wuerde das Panel schlafen gehen und zur alten
        Zeit aufwachen. Dann ist Durchlaufen die bessere Wahl.

        Verglichen wird ein Fingerabdruck des Wochenplans, der beim Setzen der
        Ausloeser hinterlegt wird - verlaesslicher, als jeden einzelnen
        Ausloeser nachzurechnen.
    #>
    [CmdletBinding()]
    param(
        [psobject]$Config = (Get-WallConfig),
        [psobject]$State = (Get-WallState)
    )

    $task = Get-WallTask -Name $script:TaskPrewake
    if (-not $task) { return $false }
    if (-not @($task.Triggers)) { return $false }

    return ([string]$State.TaskScheduleFingerprint -eq (Get-ScheduleFingerprint -Config $Config))
}

function Test-SuspendPrecondition {
    <#
        Prueft vor dem Standby, ob ein Aufwachen ueberhaupt zu erwarten ist.
        Fehlt eine Voraussetzung, bleibt es beim ausgeschalteten Bildschirm.
    #>
    [CmdletBinding()]
    param(
        [psobject]$Config = (Get-WallConfig),
        [psobject]$State = (Get-WallState)
    )

    $reasons = New-Object System.Collections.Generic.List[string]

    if (-not (Test-WakeTaskMatchesSchedule -Config $Config -State $State)) {
        $reasons.Add('Die Aufwach-Ausloeser passen nicht zum aktuellen Wochenplan.')
    }

    $prewake = Get-WallTask -Name $script:TaskPrewake
    $wake    = Get-WallTask -Name $script:TaskWake
    $wakeCapable = @($prewake, $wake) | Where-Object { $_ -and $_.Settings.WakeToRun }

    if (@($wakeCapable).Count -eq 0) {
        $reasons.Add('Es ist keine Aufgabe mit der Option "Computer zum Ausfuehren der Aufgabe reaktivieren" eingerichtet.')
    }

    $wakeTimers = Get-WakeTimerSetting
    if ($wakeTimers -eq $false) {
        $reasons.Add('Aufwachzeitgeber sind im aktiven Energieschema deaktiviert.')
    }

    $states = Get-SleepStateSupport
    if ($states.SupportsStandby -eq $false) {
        $reasons.Add('Das Geraet meldet keinen verfuegbaren Standby-Zustand (powercfg /a).')
    }

    [pscustomobject]@{
        Ok      = (@($reasons).Count -eq 0)
        Reasons = @($reasons)
    }
}

# --------------------------------------------------------------- Fernsteuerung

function Get-SyncConfig {
    <#
        Liest sync.json. Rueckgabe $null, wenn keine Fernsteuerung eingerichtet
        ist; dann arbeitet das Panel rein mit der lokalen Konfiguration.
    #>
    [CmdletBinding()]
    param()

    $file = (Get-WallPaths).SyncFile
    if (-not (Test-Path -LiteralPath $file)) { return $null }

    try {
        $json = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        # Erwartbar, wenn diese Sitzung keine erhoehten Rechte hat: die Datei
        # ist absichtlich nur fuer SYSTEM und Administratoren lesbar.
        Write-WallLog -Level WARN ("sync.json nicht lesbar: {0}" -f $_.Exception.Message)
        return $null
    }

    $sync = @{
        ServerUrl         = ''
        PanelId           = ''
        ApiToken          = ''
        TimeoutSeconds    = 20
        AllowInsecureHttp = $false
    }
    foreach ($prop in $json.PSObject.Properties) {
        if ($sync.ContainsKey($prop.Name)) { $sync[$prop.Name] = $prop.Value }
    }

    foreach ($required in @('ServerUrl', 'PanelId', 'ApiToken')) {
        if ([string]::IsNullOrWhiteSpace([string]$sync[$required])) {
            Write-WallLog -Level ERROR ("sync.json: Feld '{0}' fehlt." -f $required)
            return $null
        }
    }

    $uri = $null
    if (-not [uri]::TryCreate([string]$sync.ServerUrl, [UriKind]::Absolute, [ref]$uri)) {
        Write-WallLog -Level ERROR ("sync.json: ServerUrl '{0}' ist keine gueltige Adresse." -f $sync.ServerUrl)
        return $null
    }
    if ($uri.Scheme -eq 'http' -and -not $sync.AllowInsecureHttp) {
        Write-WallLog -Level ERROR 'sync.json: http ist nicht erlaubt. Bitte https verwenden oder AllowInsecureHttp setzen (nur fuer Tests im eigenen Netz).'
        return $null
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        Write-WallLog -Level ERROR ("sync.json: Schema '{0}' wird nicht unterstuetzt." -f $uri.Scheme)
        return $null
    }

    return [pscustomobject]$sync
}

function Save-SyncConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerUrl,
        [Parameter(Mandatory)][string]$PanelId,
        [Parameter(Mandatory)][string]$ApiToken,
        [int]$TimeoutSeconds = 20,
        [switch]$AllowInsecureHttp
    )

    Confirm-WallDataRoot | Out-Null
    $file = (Get-WallPaths).SyncFile

    ([pscustomobject]@{
        ServerUrl         = $ServerUrl.TrimEnd('/')
        PanelId           = $PanelId
        ApiToken          = $ApiToken
        TimeoutSeconds    = $TimeoutSeconds
        AllowInsecureHttp = [bool]$AllowInsecureHttp
    } | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $file -Encoding utf8

    Protect-WallFile -Path $file
    return $file
}

function Protect-WallFile {
    <#
        Beschraenkt den Zugriff auf SYSTEM und Administratoren. sync.json
        enthaelt das API-Token, das nicht fuer jeden lesbar sein soll.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        # Bekannte SIDs statt Kontonamen: 'BUILTIN\Administrators' heisst auf
        # einem deutschen Windows anders und liesse sich nicht aufloesen - die
        # Datei bliebe dann ungeschuetzt.
        $system = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $admins = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)

        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($system, $admins)) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'FullControl', 'Allow')))
        }
        # Besitzer bewusst nicht aendern: das braeuchte erhoehte Rechte und
        # bringt nichts - entscheidend ist die Zugriffsliste oben.
        Set-Acl -LiteralPath $Path -AclObject $acl

        # Gegenprobe: eine stillschweigend wirkungslose Absicherung waere
        # schlimmer als gar keine, denn in der Datei steht das API-Token.
        $check = (Get-Acl -LiteralPath $Path).Access |
            Where-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -notin @($system, $admins) }
        if ($check) {
            Write-WallLog -Level WARN ("'{0}' ist weiterhin fuer weitere Konten zugaenglich: {1}" -f $Path,
                (($check | ForEach-Object { $_.IdentityReference.Value }) -join ', '))
        }
    } catch {
        Write-WallLog -Level WARN ("Zugriffsrechte fuer '{0}' konnten nicht gesetzt werden: {1}" -f $Path, $_.Exception.Message)
    }
}

function Grant-WallDataAccess {
    <#
        Gibt dem Panel-Konto Schreibrecht auf das Datenverzeichnis.

        Noetig, weil die Aufgaben Sleep und Wake in der Benutzersitzung laufen
        und dort Konfiguration und Zustand schreiben. Unter C:\ProgramData darf
        ein Standardbenutzer sonst nur eigene Dateien aendern, nicht die von
        SYSTEM angelegten.

        sync.json bleibt davon unberuehrt: Protect-WallFile schaltet dort die
        Vererbung ab, das Token bleibt also SYSTEM und Administratoren
        vorbehalten.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    $root = Confirm-WallDataRoot
    try {
        $acl = Get-Acl -LiteralPath $root
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $UserId, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $root -AclObject $acl
        Write-WallLog ("Schreibrecht auf '{0}' fuer '{1}' gesetzt." -f $root, $UserId)
        return $true
    } catch {
        Write-WallLog -Level WARN ("Schreibrecht fuer '{0}' konnte nicht gesetzt werden: {1}" -f $UserId, $_.Exception.Message)
        return $false
    }
}

function Get-RemoteSchedule {
    <#
        Holt den Zeitplan vom Server. Wirft bei Netz- oder HTTP-Fehlern.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Sync)

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }

    $uri = '{0}/api/v1/panels/{1}/schedule' -f $Sync.ServerUrl.TrimEnd('/'), [uri]::EscapeDataString([string]$Sync.PanelId)
    $headers = @{
        'Authorization' = 'Bearer ' + [string]$Sync.ApiToken
        'Accept'        = 'application/json'
        'User-Agent'    = 'WallDisplayPower/' + $script:AgentVersion
    }

    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec ([int]$Sync.TimeoutSeconds)
}

function Get-RawField {
    <#
        Liest ein Feld aus einer Serverantwort, gleich ob sie als
        PSCustomObject (so liefert es ConvertFrom-Json) oder als Hashtable
        vorliegt. Rueckgabe $null, wenn das Feld fehlt.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-ValidatedSchedule {
    <#
        Prueft die Serverantwort Feld fuer Feld gegen feste Muster.

        WICHTIG: Die Antwort ist ausschliesslich Daten. Es wird nichts daraus
        ausgefuehrt, kein Pfad, kein Befehlstext und kein Skript uebernommen.
        Nur die hier aufgefuehrten Felder werden gelesen, alles andere
        ignoriert. Ein ungueltiges Feld laesst den ganzen Abruf scheitern,
        damit das Panel beim letzten gueltigen Zeitplan bleibt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Raw)

    $knownCommands = @('none', 'sleep-now', 'wake-now')
    $knownModes = @('Combined', 'DisplayOnly', 'SuspendOnly')

    $scheduleValue = Get-RawField -Object $Raw -Name 'schedule'
    if ($null -eq $scheduleValue) { throw 'Antwort ohne Wochenplan.' }

    # Wirft bei jeder unbrauchbaren Uhrzeit; der ganze Abruf scheitert dann und
    # der zuletzt gueltige Zeitplan bleibt in Kraft.
    $windows = ConvertTo-WallSchedule -Raw $scheduleValue

    # Fuer die Ablage in config.json wieder in reine Textwerte umwandeln.
    $schedule = [ordered]@{}
    foreach ($day in $script:WeekDays) {
        if ($windows[$day]) {
            $schedule[$day] = @{
                On  = '{0:hh\:mm}' -f $windows[$day].On
                Off = '{0:hh\:mm}' -f $windows[$day].Off
            }
        }
    }

    $mode = 'Combined'
    $modeValue = Get-RawField -Object $Raw -Name 'mode'
    if ($modeValue) {
        $candidate = [string]$modeValue
        if ($knownModes -notcontains $candidate) { throw "Antwort mit unbekanntem Modus '$candidate'." }
        $mode = $candidate
    }

    $enabled = $true
    $enabledValue = Get-RawField -Object $Raw -Name 'enabled'
    if ($null -ne $enabledValue) { $enabled = [bool]$enabledValue }

    # Uebersteuerung: hoechstens 30 Tage in die Zukunft, sonst bliebe ein
    # Tippfehler im Server monatelang wirksam.
    $keepAwakeUntil = $null
    $keepValue = Get-RawField -Object $Raw -Name 'keepAwakeUntil'
    if ($keepValue) {
        $parsed = ConvertFrom-WallUtc ([string]$keepValue)
        if (-not $parsed) { throw "Antwort mit ungueltigem keepAwakeUntil '$keepValue'." }
        if ($parsed -gt (Get-Date).AddDays(30)) { throw 'keepAwakeUntil liegt mehr als 30 Tage in der Zukunft.' }
        $keepAwakeUntil = $parsed.ToUniversalTime().ToString('o')
    }

    $commandName = 'none'
    $commandId = $null
    $commandValue = Get-RawField -Object $Raw -Name 'command'
    if ($null -ne $commandValue) {
        # Ein vorhandenes, aber unlesbares Befehlsfeld laesst den Abruf
        # scheitern, statt stillschweigend "kein Befehl" anzunehmen.
        $nameValue = Get-RawField -Object $commandValue -Name 'name'
        if ($null -eq $nameValue) { throw 'Antwort mit unlesbarem Befehlsfeld.' }

        $candidate = [string]$nameValue
        if ($knownCommands -notcontains $candidate) { throw "Antwort mit unbekanntem Befehl '$candidate'." }
        $commandName = $candidate

        $idValue = Get-RawField -Object $commandValue -Name 'id'
        if ($idValue) {
            $candidate = [string]$idValue
            if ($candidate -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw 'Antwort mit ungueltiger Befehls-Kennung.' }
            $commandId = $candidate
        }
    }
    if ($commandName -ne 'none' -and -not $commandId) {
        throw 'Befehl ohne Kennung, er liesse sich nicht genau einmal ausfuehren.'
    }

    [pscustomobject]@{
        Schedule       = $schedule
        Windows        = $windows
        Mode           = $mode
        Enabled        = $enabled
        KeepAwakeUntil = $keepAwakeUntil
        CommandName    = $commandName
        CommandId      = $commandId
    }
}

function Send-WallHeartbeat {
    <#
        Meldet den aktuellen Zustand an den Server. Fehler werden nur
        protokolliert, der Abgleich darf daran nicht scheitern.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Sync,
        [Parameter(Mandatory)][psobject]$Payload
    )

    try {
        $uri = '{0}/api/v1/panels/{1}/heartbeat' -f $Sync.ServerUrl.TrimEnd('/'), [uri]::EscapeDataString([string]$Sync.PanelId)
        $headers = @{
            'Authorization' = 'Bearer ' + [string]$Sync.ApiToken
            'User-Agent'    = 'WallDisplayPower/' + $script:AgentVersion
        }
        Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' `
            -Body ($Payload | ConvertTo-Json -Depth 4 -Compress) -TimeoutSec ([int]$Sync.TimeoutSeconds) | Out-Null
        return $true
    } catch {
        Write-WallLog -Level WARN ("Statusmeldung an den Server fehlgeschlagen: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Get-WallAgentVersion {
    return $script:AgentVersion
}

function Get-RemoteAccessId {
    <#
        Ermittelt die RustDesk-Kennung des Panels, damit die Weboberflaeche
        anzeigt, womit man sich verbinden muss.

        Reine Zusatzinformation: Die Funktion wirft nie und gibt $null zurueck,
        wenn RustDesk nicht installiert ist. Zuerst wird die Konfigurationsdatei
        gelesen (kein Prozessstart), erst danach das Programm befragt.
    #>
    [CmdletBinding()]
    param()

    try {
        # Laeuft RustDesk als Dienst, liegt die Konfiguration im Profil von
        # LOCAL SERVICE, sonst im Profil des angemeldeten Benutzers.
        $configs = @(
            (Join-Path $env:WINDIR 'ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml'),
            (Join-Path $env:APPDATA 'RustDesk\config\RustDesk.toml')
        )
        foreach ($config in $configs) {
            if (-not (Test-Path -LiteralPath $config)) { continue }
            $match = Select-String -LiteralPath $config -Pattern "^\s*id\s*=\s*['`"]?([A-Za-z0-9_-]{4,32})" |
                Select-Object -First 1
            if ($match) { return $match.Matches[0].Groups[1].Value }
        }

        $exe = @(
            (Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'RustDesk\rustdesk.exe')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if (-not $exe) { return $null }

        # Mit Zeitlimit starten: der Abgleich darf nicht haengen bleiben.
        $out = Join-Path $env:TEMP ('walldisplay-rdid-' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            $process = Start-Process -FilePath $exe -ArgumentList '--get-id' -NoNewWindow -PassThru `
                -RedirectStandardOutput $out
            if (-not $process.WaitForExit(5000)) {
                $process.Kill()
                return $null
            }
            $text = (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue)
            if ($text -and $text -match '([A-Za-z0-9_-]{4,32})') { return $Matches[1] }
        } finally {
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-WallLog -Level WARN ("RustDesk-Kennung nicht ermittelbar: {0}" -f $_.Exception.Message)
    }
    return $null
}

function New-WallWeeklyTrigger {
    <#
        Woechentlicher Ausloeser zur angegebenen Ortszeit an bestimmten Tagen.

        New-ScheduledTaskTrigger legt die Startzeit als UTC ab ('...Z'). Eine
        UTC-Startzeit verschiebt sich bei der Zeitumstellung um eine Stunde,
        das Panel wuerde also nach dem Wechsel zu falscher Uhrzeit schalten.
        Darum wird die Startzeit auf eine lokale Angabe ohne Zeitzone gesetzt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Days,
        [Parameter(Mandatory)][timespan]$At
    )

    $start = [datetime]::Today.Add($At)
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Days -At $start
    $trigger.StartBoundary = $start.ToString('yyyy-MM-ddTHH:mm:ss')
    return $trigger
}

function Get-WallScheduleTriggers {
    <#
        Erzeugt die Ausloeser einer Aufgabe aus dem Wochenplan.

        Kind:
          Wake    Beginn jedes Fensters (Panel geht an)
          Prewake wie Wake, aber um den Vorlauf frueher (weckt das Geraet)
          Sleep   Ende jedes Fensters (Panel geht aus)

        Wichtig beim Ende: Reicht ein Fenster ueber Mitternacht, liegt sein
        Ende am FOLGETAG. Freitag 17:00 bis 02:00 bedeutet also einen
        Ausloeser am Samstag um 02:00.

        Ausloeser mit gleicher Uhrzeit werden zu einem Wochentrigger
        zusammengefasst, das haelt die Aufgabe uebersichtlich.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][ValidateSet('Wake', 'Prewake', 'Sleep')][string]$Kind
    )

    $byTime = @{}
    foreach ($day in $script:WeekDays) {
        $window = $Config.Windows[$day]
        if (-not $window) { continue }

        if ($Kind -eq 'Sleep') {
            $time = $window.Off
            $triggerDay = if ($window.CrossesMidnight) { Get-NextWeekDay -Day $day } else { $day }
        } else {
            $time = $window.On
            $triggerDay = $day
            if ($Kind -eq 'Prewake') {
                $time = $time - [timespan]::FromMinutes([double]$Config.WakePreRollMinutes)
                if ($time -lt [timespan]::Zero) {
                    # Der Vorlauf rutscht vor Mitternacht: Ausloeser am Vortag.
                    $time = $time.Add([timespan]::FromDays(1))
                    $triggerDay = Get-PreviousWeekDay -Day $day
                }
            }
        }

        $key = '{0:hh\:mm}' -f $time
        if (-not $byTime.ContainsKey($key)) { $byTime[$key] = @{ Time = $time; Days = @() } }
        if ($byTime[$key].Days -notcontains $triggerDay) { $byTime[$key].Days += $triggerDay }
    }

    $triggers = @()
    foreach ($key in ($byTime.Keys | Sort-Object)) {
        $triggers += New-WallWeeklyTrigger -Days $byTime[$key].Days -At $byTime[$key].Time
    }
    return $triggers
}

function Get-NextWeekDay {
    param([Parameter(Mandatory)][string]$Day)
    $index = [array]::IndexOf($script:WeekDays, $Day)
    return $script:WeekDays[($index + 1) % 7]
}

function Get-PreviousWeekDay {
    param([Parameter(Mandatory)][string]$Day)
    $index = [array]::IndexOf($script:WeekDays, $Day)
    return $script:WeekDays[($index + 6) % 7]
}

function Update-WallTaskTriggers {
    <#
        Setzt die Ausloeser einer bestehenden Aufgabe neu. Braucht
        Administratorrechte.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][ValidateSet('Wake', 'Prewake', 'Sleep')][string]$Kind
    )

    $task = Get-WallTask -Name $Name
    if (-not $task) {
        Write-WallLog -Level WARN ("Aufgabe '{0}' fehlt, Ausloeser nicht aenderbar." -f $Name)
        return $false
    }

    try {
        $task.Triggers = @(Get-WallScheduleTriggers -Config $Config -Kind $Kind)
        Set-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
        Write-WallLog ("Ausloeser der Aufgabe '{0}' neu gesetzt ({1} Stueck)." -f $Name, @($task.Triggers).Count)
        return $true
    } catch {
        Write-WallLog -Level ERROR ("Ausloeser der Aufgabe '{0}' konnten nicht gesetzt werden: {1}" -f $Name, $_.Exception.Message)
        return $false
    }
}

function Wait-WallTask {
    <#
        Wartet, bis eine Aufgabe nicht mehr laeuft. Rueckgabe $true, wenn sie
        innerhalb der Frist fertig wurde.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSeconds = 45
    )

    # Kurz warten: direkt nach dem Start meldet die Aufgabe noch 'Ready'.
    Start-Sleep -Seconds 1

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $task = Get-WallTask -Name $Name
        if (-not $task) { return $false }
        if ($task.State -ne 'Running') { return $true }
        Start-Sleep -Milliseconds 500
    }
    Write-WallLog -Level WARN ("Aufgabe '{0}' laeuft nach {1} s immer noch." -f $Name, $TimeoutSeconds)
    return $false
}

function Start-WallTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $task = Get-WallTask -Name $Name
    if (-not $task) {
        Write-WallLog -Level WARN ("Aufgabe '{0}' fehlt und kann nicht gestartet werden." -f $Name)
        return $false
    }
    try {
        Start-ScheduledTask -InputObject $task -ErrorAction Stop
        return $true
    } catch {
        Write-WallLog -Level ERROR ("Aufgabe '{0}' konnte nicht gestartet werden: {1}" -f $Name, $_.Exception.Message)
        return $false
    }
}

function Get-SystemLanguageInfo {
    <#
        Reine Diagnose. Die Steuerung selbst wertet keinen uebersetzten Text
        aus: Konten werden ueber SIDs angesprochen, Energieoptionen ueber
        GUIDs, Schlafzustaende ueber die Kennungen S0..S4. Die Sprache des
        Geraets ist also ohne Belang - angezeigt wird sie nur, damit man bei
        einer Stoerung sofort sieht, womit man es zu tun hat.
    #>
    [CmdletBinding()]
    param()

    $ui = $null
    $display = $null
    try { $ui = [System.Globalization.CultureInfo]::InstalledUICulture.Name } catch { }
    try { $display = (Get-Culture).Name } catch { }

    [pscustomobject]@{
        UiCulture      = $ui
        FormatCulture  = $display
        # Die Steuerung haengt bewusst an keiner dieser Angaben.
        AffectsLogic   = $false
    }
}

function Test-WallAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}


Export-ModuleMember -Function @(
    'Get-WallPaths', 'Confirm-WallDataRoot',
    'Write-WallLog', 'Get-WallLogTail',
    'Get-WallConfig', 'Save-WallConfig', 'ConvertTo-TimeOfDay', 'ConvertFrom-WallUtc', 'Get-NextOccurrence',
    'Test-InsideSleepWindow', 'Test-WallNightMode', 'ConvertTo-WallSchedule', 'Test-ActiveWindow',
    'Get-NextWindowStart', 'Get-CurrentWindowEnd', 'Get-ScheduleFingerprint',
    'Get-WallState', 'Save-WallState', 'Resolve-EffectiveMode', 'Set-FallbackMode',
    'Register-WakeFailure', 'Register-WakeSuccess',
    'New-WallSignal', 'Remove-WallSignal', 'Test-WallSignal', 'Wait-WallInterval',
    'Initialize-WallNative', 'Set-DisplayPower', 'Invoke-SystemSuspend',
    'Get-SleepStateSupport', 'Get-WakeTimerSetting', 'Get-ConsoleLockSetting', 'Set-WallPowerPolicy',
    'Get-WallDeviceQuery', 'Get-WakeArmedDevices', 'Get-WallPnpClassMap', 'Resolve-WallDeviceClass',
    'Disable-WallDeviceWake', 'Enable-WallDeviceWake',
    'Get-WallTaskNames', 'Get-WallTask', 'Stop-WallSleepTask', 'Test-SuspendPrecondition',
    'Test-WakeTaskMatchesSchedule', 'Grant-WallDataAccess', 'Get-SystemLanguageInfo',
    'Get-SyncConfig', 'Save-SyncConfig', 'Protect-WallFile', 'Get-RemoteSchedule', 'Get-RawField',
    'ConvertTo-ValidatedSchedule', 'Send-WallHeartbeat', 'Get-WallAgentVersion', 'Get-RemoteAccessId',
    'New-WallWeeklyTrigger', 'Get-WallScheduleTriggers', 'Update-WallTaskTriggers',
    'Start-WallTask', 'Wait-WallTask',
    'Test-WallAdmin'
)
