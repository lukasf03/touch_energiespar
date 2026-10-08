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

$script:AgentVersion = '1.1.0'

$script:ConfigDefaults = @{
    SleepTime                     = '22:00'
    WakeTime                      = '06:00'
    Mode                          = 'Combined'
    Enabled                       = $true
    DisplayOffDelaySeconds        = 60
    WakePreRollMinutes            = 1
    WakeToleranceMinutes          = 10
    MaxWakeFailures               = 2
    MinimumSuspendSeconds         = 30
    MaxSuspendRetries             = 20
    KeepDisplayOffIntervalSeconds = 20
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
    $cfg['SleepTimeOfDay'] = ConvertTo-TimeOfDay $cfg['SleepTime']
    $cfg['WakeTimeOfDay']  = ConvertTo-TimeOfDay $cfg['WakeTime']

    if ($cfg['Mode'] -notin @('Combined', 'DisplayOnly', 'SuspendOnly')) {
        Write-WallLog -Level WARN ("Unbekannter Modus '{0}', es gilt 'Combined'." -f $cfg['Mode'])
        $cfg['Mode'] = 'Combined'
    }

    return [pscustomobject]$cfg
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
        Entscheidet, ob gerade Nachtbetrieb gelten soll.

        Reihenfolge der Auswertung (die erste zutreffende Regel gewinnt):
          1. Befehl 'sleep-now' laeuft noch  -> Nacht
          2. Zeitplan ist abgeschaltet       -> Tag
          3. Befehl 'wake-now' laeuft noch   -> Tag
          4. Server-Uebersteuerung aktiv     -> Tag
          5. Uhrzeit liegt im Zeitfenster    -> Nacht

        Das Zeitfenster darf Mitternacht ueberspannen (22:00 bis 06:00).
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

    $sleep = $Config.SleepTimeOfDay
    $wake = $Config.WakeTimeOfDay
    if ($sleep -eq $wake) { return $false }

    $time = $Now.TimeOfDay
    if ($sleep -lt $wake) { return ($time -ge $sleep -and $time -lt $wake) }
    return ($time -ge $sleep -or $time -lt $wake)
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
        Ausgewertet werden nur die sprachunabhaengigen Kennungen S1..S4 / S0.
    #>
    [CmdletBinding()]
    param()

    $raw = ''
    try {
        $raw = (& powercfg.exe /a) -join "`n"
    } catch {
        return [pscustomobject]@{ Raw = ''; Available = @(); SupportsStandby = $null; ModernStandby = $null }
    }

    # 'powercfg /a' gibt zuerst die verfuegbaren, danach die nicht verfuegbaren
    # Zustaende aus. Abschnitte beginnen mit einer nicht eingerueckten Zeile.
    $available = New-Object System.Collections.Generic.List[string]
    $headerCount = 0
    foreach ($line in ($raw -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^\s') { $headerCount++; continue }
        if ($headerCount -ne 1) { continue }
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

function Test-SuspendPrecondition {
    <#
        Prueft vor dem ersten Standby, ob ein Aufwachen ueberhaupt zu erwarten
        ist. Fehlt eine Voraussetzung, bleibt es beim ausgeschalteten Bildschirm.
    #>
    [CmdletBinding()]
    param()

    $reasons = New-Object System.Collections.Generic.List[string]

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
        Write-WallLog -Level ERROR ("sync.json ist unlesbar: {0}" -f $_.Exception.Message)
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
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($account in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $account, 'FullControl', 'Allow')))
        }
        $acl.SetOwner((New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')))
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        Write-WallLog -Level WARN ("Zugriffsrechte fuer '{0}' konnten nicht gesetzt werden: {1}" -f $Path, $_.Exception.Message)
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

    $sleepValue = Get-RawField -Object $Raw -Name 'sleepTime'
    $wakeValue = Get-RawField -Object $Raw -Name 'wakeTime'
    if ($null -eq $sleepValue -or $null -eq $wakeValue) {
        throw 'Antwort ohne sleepTime/wakeTime.'
    }

    $sleepTod = ConvertTo-TimeOfDay ([string]$sleepValue)
    $wakeTod = ConvertTo-TimeOfDay ([string]$wakeValue)
    if ($sleepTod -eq $wakeTod) {
        throw 'Antwort mit identischer Schlafens- und Weckzeit.'
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
        SleepTime      = $sleepTod.ToString('hh\:mm')
        WakeTime       = $wakeTod.ToString('hh\:mm')
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

function New-WallDailyTrigger {
    <#
        Taeglicher Ausloeser zur angegebenen Ortszeit.

        New-ScheduledTaskTrigger legt die Startzeit als UTC ab ('...Z'). Eine
        UTC-Startzeit verschiebt sich bei der Zeitumstellung um eine Stunde,
        das Panel wuerde also nach dem Wechsel zu falscher Uhrzeit schlafen.
        Darum wird die Startzeit auf eine lokale Angabe ohne Zeitzone gesetzt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime]$At)

    $trigger = New-ScheduledTaskTrigger -Daily -At $At
    $trigger.StartBoundary = $At.ToString('yyyy-MM-ddTHH:mm:ss')
    return $trigger
}

function Update-WallTaskTime {
    <#
        Setzt die Startzeit einer bestehenden Aufgabe neu. Rueckgabe $true,
        wenn tatsaechlich etwas geaendert wurde. Braucht Administratorrechte.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][datetime]$At
    )

    $task = Get-WallTask -Name $Name
    if (-not $task) {
        Write-WallLog -Level WARN ("Aufgabe '{0}' fehlt, Startzeit nicht aenderbar." -f $Name)
        return $false
    }

    $desired = $At.ToString('yyyy-MM-ddTHH:mm:ss')
    $current = @($task.Triggers) | Select-Object -First 1
    if ($current -and [string]$current.StartBoundary -eq $desired) { return $false }

    try {
        $task.Triggers = @(New-WallDailyTrigger -At $At)
        Set-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
        Write-WallLog ("Startzeit der Aufgabe '{0}' auf {1:HH:mm} gesetzt." -f $Name, $At)
        return $true
    } catch {
        Write-WallLog -Level ERROR ("Startzeit der Aufgabe '{0}' konnte nicht gesetzt werden: {1}" -f $Name, $_.Exception.Message)
        return $false
    }
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

function Test-WallAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}


Export-ModuleMember -Function @(
    'Get-WallPaths', 'Confirm-WallDataRoot',
    'Write-WallLog', 'Get-WallLogTail',
    'Get-WallConfig', 'Save-WallConfig', 'ConvertTo-TimeOfDay', 'ConvertFrom-WallUtc', 'Get-NextOccurrence',
    'Test-InsideSleepWindow', 'Test-WallNightMode',
    'Get-WallState', 'Save-WallState', 'Resolve-EffectiveMode', 'Set-FallbackMode',
    'Register-WakeFailure', 'Register-WakeSuccess',
    'New-WallSignal', 'Remove-WallSignal', 'Test-WallSignal', 'Wait-WallInterval',
    'Initialize-WallNative', 'Set-DisplayPower', 'Invoke-SystemSuspend',
    'Get-SleepStateSupport', 'Get-WakeTimerSetting', 'Set-WallPowerPolicy',
    'Get-WallTaskNames', 'Get-WallTask', 'Stop-WallSleepTask', 'Test-SuspendPrecondition',
    'Get-SyncConfig', 'Save-SyncConfig', 'Protect-WallFile', 'Get-RemoteSchedule', 'Get-RawField',
    'ConvertTo-ValidatedSchedule', 'Send-WallHeartbeat', 'Get-WallAgentVersion', 'Get-RemoteAccessId',
    'New-WallDailyTrigger', 'Update-WallTaskTime', 'Start-WallTask',
    'Test-WallAdmin'
)
