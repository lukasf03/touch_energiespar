<#
.SYNOPSIS
    Energiesteuerung fuer ein Wand-Touchpanel: Bildschirm und Standby nach Uhrzeit.

.DESCRIPTION
    Wird von den Aufgaben unter \WallDisplayPower\ aufgerufen und kann fuer
    Tests auch von Hand gestartet werden.

    Aktionen:
      Sleep       Nachtbetrieb: Bildschirm aus, danach (je nach Modus) Standby.
      Wake        Tagbetrieb: Bildschirm ein, Nacht-Aufgabe beenden, Protokoll.
      Prewake     Platzhalter-Aufgabe, die den Aufwachzeitgeber ausloest.
      Sync        Zeitplan vom Server holen und den Zustand abgleichen.
      Status      Konfiguration, Zustand, Aufgaben und Energieoptionen anzeigen.
      Diagnose    Ausfuehrliche Analyse fuer die Fehlersuche.
      SelfTest    Einmaliger Standby-Test ueber wenige Minuten.
      Reset       Automatische Rueckstufung aufheben.
      DisplayOff  Bildschirm sofort ausschalten.
      DisplayOn   Bildschirm sofort einschalten.

.EXAMPLE
    .\WallDisplay.ps1 -Action Status

.EXAMPLE
    .\WallDisplay.ps1 -Action SelfTest -SelfTestMinutes 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Sleep', 'Wake', 'Prewake', 'Sync', 'Status', 'Diagnose', 'SelfTest', 'Reset', 'DisplayOff', 'DisplayOn')]
    [string]$Action,

    [ValidateRange(2, 60)]
    [int]$SelfTestMinutes = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WallDisplay.Core.psm1') -Force -DisableNameChecking


# ------------------------------------------------------------------ Nachtbetrieb

function Invoke-SleepAction {
    $config = Get-WallConfig
    $state = Get-WallState

    if (-not (Test-InsideSleepWindow -Config $config -State $state)) {
        Write-WallLog ('Nachtbetrieb uebersprungen: ausgeschaltet oder uebersteuert (Enabled={0}).' -f $config.Enabled)
        return
    }

    $mode = Resolve-EffectiveMode -Config $config -State $state
    $wakeTarget = Get-NextWindowStart -Windows $config.Windows

    Remove-WallSignal
    Write-WallLog ('Ruhebetrieb beginnt. Modus={0}, naechstes Fenster ab {1}' -f $mode,
        $(if ($wakeTarget) { $wakeTarget.ToString('dddd dd.MM. HH:mm') } else { 'unbekannt' }))

    Set-DisplayPower -State Off

    if ($mode -eq 'DisplayOnly') {
        Invoke-KeepDisplayOff
        return
    }

    # Letzte Abfrage vor dem Standby. Sie liegt bewusst vor der Wartezeit, also
    # rund eine Minute vor dem Einschlafen: Im Standby ist das Panel nicht mehr
    # erreichbar, eine Aenderung der letzten Minuten wuerde sonst erst am
    # naechsten Morgen ankommen.
    Invoke-FinalScheduleCheck

    if ($mode -eq 'Combined' -and [int]$config.DisplayOffDelaySeconds -gt 0) {
        Write-WallLog ('Standby in {0} s.' -f [int]$config.DisplayOffDelaySeconds)
        if (-not (Wait-WallInterval -Seconds ([int]$config.DisplayOffDelaySeconds))) {
            Write-WallLog 'Weck-Signal vor dem Standby empfangen, Nachtbetrieb abgebrochen.'
            return
        }
    }

    $retries = 0
    while ($true) {
        # Zeitplan in jedem Durchlauf neu lesen: eine von aussen geaenderte
        # Weckzeit soll noch in derselben Nacht wirken.
        $config = Get-WallConfig
        $state = Get-WallState
        if (-not (Test-InsideSleepWindow -Config $config -State $state)) {
            Write-WallLog 'Zeitfenster endet oder wurde uebersteuert, Nachtbetrieb beendet.'
            break
        }

        $wakeTarget = Get-NextWindowStart -Windows $config.Windows
        if (-not $wakeTarget) {
            Write-WallLog -Level WARN 'Der Wochenplan enthaelt kein naechstes Fenster, kein Standby.'
            Invoke-KeepDisplayOff
            return
        }

        $margin = [timespan]::FromMinutes([double]$config.WakePreRollMinutes + 1)
        if ((Get-Date) -ge ($wakeTarget - $margin)) { break }

        # Erst hier pruefen, nicht vor der Wartezeit: Der Zeitplan kann sich
        # bei der letzten Abfrage gerade geaendert haben, und dann muessen auch
        # die Aufwach-Ausloeser zum neuen Wochenplan passen.
        $precondition = Test-SuspendPrecondition -Config $config -State $state
        if (-not $precondition.Ok) {
            Write-WallLog -Level WARN ('Standby uebersprungen: {0}' -f ($precondition.Reasons -join ' '))
            Invoke-KeepDisplayOff
            return
        }

        Set-DisplayPower -State Off -Quiet

        $state.ExpectedWakeUtc = $wakeTarget.ToUniversalTime().ToString('o')
        $state.LastSuspendAttemptUtc = (Get-Date).ToUniversalTime().ToString('o')
        $state.EffectiveMode = $mode
        Save-WallState $state

        Write-WallLog 'Wechsel in den Energiesparmodus.'
        $before = Get-Date
        $accepted = Invoke-SystemSuspend
        $slept = (Get-Date) - $before

        if (-not $accepted -or $slept.TotalSeconds -lt [double]$config.MinimumSuspendSeconds) {
            Write-WallLog -Level WARN ('Standby nicht moeglich (Rueckgabe={0}, Dauer={1} s).' -f $accepted, [int]$slept.TotalSeconds)
            Set-FallbackMode -Reason 'Das Geraet wechselt nicht in den Energiesparmodus.'
            Invoke-KeepDisplayOff
            return
        }

        Write-WallLog ('Aus dem Energiesparmodus zurueck nach {0} Minuten.' -f [int]$slept.TotalMinutes)

        if (Test-WallSignal) {
            Write-WallLog 'Weck-Signal liegt vor, Nachtbetrieb beendet.'
            return
        }

        $retries++
        if ($retries -ge [int]$config.MaxSuspendRetries) {
            Write-WallLog -Level WARN ('Nach {0} unerwarteten Aufwach-Vorgaengen bleibt es bis zum Fensterende beim ausgeschalteten Bildschirm.' -f $retries)
            Invoke-KeepDisplayOff
            return
        }

        Write-WallLog -Level WARN 'Unerwartetes Aufwachen vor der Weckzeit, erneuter Standby in 15 s.'
        if (-not (Wait-WallInterval -Seconds 15)) { return }

        # Das Geraet war eine Weile weg und hat dabei jeden regulaeren Abruf
        # verpasst. Vor dem erneuten Einschlafen also nochmal nachfragen.
        Invoke-FinalScheduleCheck
    }

    Write-WallLog 'Nachtbetrieb regulaer beendet (Weckzeit erreicht).'
}

function Invoke-FinalScheduleCheck {
    <#
        Letzte Abfrage des Zeitplans, bevor das Panel in den Standby geht.
        Ohne eingerichtete Fernsteuerung passiert nichts.

        Zwei Wege, weil diese Aufgabe in der Benutzersitzung laeuft:

        1. Darf diese Sitzung die Zugangsdaten lesen (SYSTEM oder erhoehte
           Rechte), wird direkt abgefragt.
        2. Sonst wird die Abgleich-Aufgabe angestossen. Sie laeuft als SYSTEM,
           darf also sowohl das Token lesen als auch die Startzeiten der
           Aufgaben nachziehen - was ein gewoehnlicher Benutzer nicht kann.
           Danach steht das Ergebnis in config.json und wird von hier gelesen.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath (Get-WallPaths).SyncFile)) { return }

    Write-WallLog 'Letzte Abfrage des Zeitplans vor dem Standby.'

    $sync = Get-SyncConfig
    if ($sync) {
        Update-ScheduleFromServer -Sync $sync | Out-Null
        return
    }

    $tasks = Get-WallTaskNames
    Write-WallLog 'Zugangsdaten hier nicht lesbar, Abgleich-Aufgabe uebernimmt die Abfrage.'
    if (-not (Start-WallTask -Name $tasks.Sync)) {
        Write-WallLog -Level WARN 'Abfrage vor dem Standby nicht moeglich, es gilt der zuletzt bekannte Zeitplan.'
        return
    }
    if (Wait-WallTask -Name $tasks.Sync -TimeoutSeconds 45) {
        Write-WallLog 'Abgleich-Aufgabe fertig, Zeitplan ist aktuell.'
    }
}

function Invoke-KeepDisplayOff {
    <#
        Haelt den Bildschirm aus, solange das Zeitfenster gilt. Notwendig, weil
        ein Touchpanel durch Streu-Eingaben sonst wieder aufwachen kann.

        Abbruchbedingung ist absichtlich das Zeitfenster und nicht eine fest
        berechnete Weckzeit: so endet die Schleife auch dann, wenn der Zeitplan
        waehrend der Nacht von aussen geaendert wird.
    #>
    [CmdletBinding()]
    param()

    $interval = [math]::Max(5, [int](Get-WallConfig).KeepDisplayOffIntervalSeconds)
    Write-WallLog ('Bildschirm bleibt bis zum Fensterende aus, Nachkontrolle alle {0} s.' -f $interval)

    while (Test-WallNightMode) {
        Set-DisplayPower -State Off -Quiet
        if (-not (Wait-WallInterval -Seconds $interval)) {
            Write-WallLog 'Weck-Signal empfangen, Nachkontrolle beendet.'
            return
        }
    }
    Write-WallLog 'Nachkontrolle beendet (Zeitfenster vorbei).'
}


# -------------------------------------------------------------------- Tagbetrieb

function Invoke-WakeAction {
    $config = Get-WallConfig

    New-WallSignal
    Stop-WallSleepTask
    Set-DisplayPower -State On

    $state = Get-WallState
    $state.LastWakeUtc = (Get-Date).ToUniversalTime().ToString('o')

    $expected = ConvertFrom-WallUtc $state.ExpectedWakeUtc
    if ($expected) {
        $delay = (Get-Date) - $expected
        $state.ExpectedWakeUtc = $null
        Save-WallState $state

        if ($delay.TotalMinutes -gt [double]$config.WakeToleranceMinutes) {
            Register-WakeFailure -Config $config -Reason ('Das Geraet ist {0} Minuten zu spaet aufgewacht (geplant {1:HH:mm}).' -f [int]$delay.TotalMinutes, $expected)
        } else {
            Register-WakeSuccess -DelayMinutes $delay.TotalMinutes
            Write-WallLog ('Aufwachen puenktlich, Abweichung {0} Minuten.' -f [math]::Round($delay.TotalMinutes, 1))
        }
    } else {
        Save-WallState $state
    }

    # Die Signaldatei bleibt absichtlich liegen: Sie wird erst vom naechsten
    # Nachtbetrieb entfernt. Wuerde sie hier geloescht, koennte eine noch
    # laufende Nachkontrolle das Signal verpassen und den Bildschirm wieder
    # ausschalten.
    Write-WallLog 'Tagbetrieb aktiv.'
}

function Invoke-PrewakeAction {
    $state = Get-WallState
    $state.LastPrewakeUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-WallState $state
    Write-WallLog 'Aufwachzeitgeber hat ausgeloest, das Geraet ist wach.'
}


# ------------------------------------------------------------------ Fernsteuerung

function Update-ScheduleFromServer {
    <#
        Holt den Zeitplan vom Server und uebernimmt ihn. Rueckgabe $true bei
        Erfolg, $false bei Netz- oder Validierungsfehlern sowie dann, wenn gar
        keine Fernsteuerung eingerichtet ist.

        Wirft nie: bei einem Fehler bleibt der letzte gueltige Zeitplan in
        Kraft. Ein Rueckfall auf "immer an" ist bewusst ausgeschlossen, das
        waere genau der Zustand, der vermieden werden soll.
    #>
    [CmdletBinding()]
    param([psobject]$Sync = (Get-SyncConfig))

    if (-not $Sync) { return $false }

    try {
        $raw = Get-RemoteSchedule -Sync $Sync
        $schedule = ConvertTo-ValidatedSchedule -Raw $raw
        Set-WallScheduleFromRemote -Schedule $schedule

        $state = Get-WallState
        $state.SyncLastSuccessUtc = (Get-Date).ToUniversalTime().ToString('o')
        $state.SyncConsecutiveFailures = 0
        $state.SyncLastError = $null
        Save-WallState $state
        return $true
    } catch {
        $state = Get-WallState
        $count = [int]$state.SyncConsecutiveFailures + 1
        $state.SyncConsecutiveFailures = $count
        $state.SyncLastError = $_.Exception.Message
        Save-WallState $state

        $level = if ($count -ge 12) { 'ERROR' } else { 'WARN' }
        Write-WallLog -Level $level ('Abgleich fehlgeschlagen ({0}x in Folge), es gilt weiter der letzte gueltige Zeitplan: {1}' -f $count, $_.Exception.Message)
        return $false
    }
}

function Invoke-SyncAction {
    $sync = Get-SyncConfig
    Update-ScheduleFromServer -Sync $sync | Out-Null
    Invoke-Reconcile

    if ($sync) {
        $config = Get-WallConfig
        $state = Get-WallState
        Send-WallHeartbeat -Sync $sync -Payload ([pscustomobject]@{
            agentVersion            = Get-WallAgentVersion
            computerName            = $env:COMPUTERNAME
            reportedAtUtc           = (Get-Date).ToUniversalTime().ToString('o')
            configuredSchedule      = Format-WallSchedule -Windows $config.Windows
            configuredMode          = $config.Mode
            effectiveMode           = Resolve-EffectiveMode -Config $config -State $state
            enabled                 = [bool]$config.Enabled
            insideSleepWindow       = (Test-InsideSleepWindow -Config $config -State $state)
            displayState            = $state.DisplayState
            lastWakeUtc             = $state.LastWakeUtc
            lastWakeDelayMinutes    = $state.LastWakeDelayMinutes
            consecutiveWakeFailures = [int]$state.ConsecutiveWakeFailures
            fallbackReason          = $state.FallbackReason
            appliedCommandId        = $state.LastCommandId
            remoteId                = Get-RemoteAccessId
            sleepStates             = @((Get-SleepStateSupport).Available)
        }) | Out-Null
    }
}

function Set-WallScheduleFromRemote {
    <#
        Uebernimmt einen bereits geprueften Zeitplan in die lokale
        Konfiguration und zieht die Startzeiten der Aufgaben nach.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Schedule)

    $config = Get-WallConfig
    $changes = New-Object System.Collections.Generic.List[string]
    $values = @{}

    $before = Format-WallSchedule -Windows $config.Windows
    $after = Format-WallSchedule -Windows $Schedule.Windows
    $scheduleChanged = ($before -ne $after)
    if ($scheduleChanged) {
        $changes.Add(('Wochenplan {0} -> {1}' -f $before, $after))
        $values['Schedule'] = $Schedule.Schedule
    }
    if ($config.Mode -ne $Schedule.Mode) {
        $changes.Add(('Modus {0} -> {1}' -f $config.Mode, $Schedule.Mode))
        $values['Mode'] = $Schedule.Mode
    }
    if ([bool]$config.Enabled -ne [bool]$Schedule.Enabled) {
        $changes.Add(('Zeitplan aktiv {0} -> {1}' -f [bool]$config.Enabled, [bool]$Schedule.Enabled))
        $values['Enabled'] = [bool]$Schedule.Enabled
    }

    if ($values.Count -gt 0) {
        Save-WallConfig -Values $values | Out-Null
        Write-WallLog ('Zeitplan vom Server uebernommen: {0}' -f ($changes -join ', '))
    }

    $state = Get-WallState

    # Die Server-Uebersteuerung wird immer uebernommen, auch ihr Wegfall.
    if ([string]$state.ForceAwakeUntilUtc -ne [string]$Schedule.KeepAwakeUntil) {
        $local = ConvertFrom-WallUtc $Schedule.KeepAwakeUntil
        if ($local) {
            Write-WallLog ('Uebersteuerung vom Server: wach bleiben bis {0:dd.MM. HH:mm}.' -f $local)
        } else {
            Write-WallLog 'Uebersteuerung vom Server aufgehoben.'
        }
        $state.ForceAwakeUntilUtc = $Schedule.KeepAwakeUntil
    }

    # Ein Befehl wird genau einmal ausgefuehrt, erkannt an seiner Kennung.
    if ($Schedule.CommandId -and [string]$Schedule.CommandId -ne [string]$state.LastCommandId) {
        $effective = Get-WallConfig
        switch ($Schedule.CommandName) {
            'sleep-now' {
                # Bis zum Beginn des naechsten Aktiv-Fensters schlafen.
                $until = Get-NextWindowStart -Windows $effective.Windows
                if ($until) {
                    $state.CommandSleepUntilUtc = $until.ToUniversalTime().ToString('o')
                    $state.CommandAwakeUntilUtc = $null
                    Write-WallLog ('Befehl "sleep-now" angenommen, Ruhebetrieb bis {0:dd.MM. HH:mm}.' -f $until)
                }
            }
            'wake-now' {
                # Bis zum Ende des laufenden Fensters wach bleiben; liegt
                # gerade keines an, bis zum Ende des naechsten.
                $until = Get-CurrentWindowEnd -Windows $effective.Windows
                if (-not $until) {
                    $start = Get-NextWindowStart -Windows $effective.Windows
                    if ($start) { $until = Get-CurrentWindowEnd -Windows $effective.Windows -Now $start }
                }
                if ($until) {
                    $state.CommandAwakeUntilUtc = $until.ToUniversalTime().ToString('o')
                    $state.CommandSleepUntilUtc = $null
                    Write-WallLog ('Befehl "wake-now" angenommen, Betrieb bis {0:dd.MM. HH:mm}.' -f $until)
                }
            }
            default {
                $state.CommandAwakeUntilUtc = $null
                $state.CommandSleepUntilUtc = $null
            }
        }
        $state.LastCommandId = $Schedule.CommandId
    }

    Save-WallState $state

    if ($scheduleChanged) {
        Update-WallTaskTimesFromConfig
    }
}

function Format-WallSchedule {
    <#
        Kurzfassung des Wochenplans fuer Protokoll und Anzeige, z. B.
        "Mo-Do 18:00-22:00, Fr-Sa 17:00-02:00, So 16:00-23:00".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Windows)

    if (-not $Windows) { return '(leer)' }

    $kurz = @{
        Monday = 'Mo'; Tuesday = 'Di'; Wednesday = 'Mi'; Thursday = 'Do'
        Friday = 'Fr'; Saturday = 'Sa'; Sunday = 'So'
    }
    $reihenfolge = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

    # Aufeinanderfolgende Tage mit gleichen Zeiten zusammenfassen.
    $gruppen = @()
    foreach ($day in $reihenfolge) {
        $window = $Windows[$day]
        $text = if ($window) { '{0:hh\:mm}-{1:hh\:mm}' -f $window.On, $window.Off } else { 'aus' }

        if ($gruppen.Count -gt 0 -and $gruppen[-1].Text -eq $text) {
            $gruppen[-1].Bis = $day
        } else {
            $gruppen += @{ Von = $day; Bis = $day; Text = $text }
        }
    }

    $teile = foreach ($g in $gruppen) {
        if ($g.Text -eq 'aus') { continue }
        $tage = if ($g.Von -eq $g.Bis) { $kurz[$g.Von] } else { '{0}-{1}' -f $kurz[$g.Von], $kurz[$g.Bis] }
        '{0} {1}' -f $tage, $g.Text
    }
    if (-not $teile) { return '(kein Fenster)' }
    return ($teile -join ', ')
}

function Update-WallTaskTimesFromConfig {
    <#
        Zieht die Startzeiten der Aufgaben auf die Konfiguration nach. Die
        Aufgaben bleiben noetig, weil nur ein Aufwachzeitgeber das Geraet aus
        dem Standby holen kann - dort laeuft der Abgleich nicht.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-WallAdmin)) {
        Write-WallLog -Level WARN 'Startzeiten der Aufgaben nicht geaendert: dafuer sind Administratorrechte noetig.'
        return
    }

    $config = Get-WallConfig
    $tasks = Get-WallTaskNames

    $ok = $true
    foreach ($entry in @(
        @{ Name = $tasks.Sleep;   Kind = 'Sleep' },
        @{ Name = $tasks.Prewake; Kind = 'Prewake' },
        @{ Name = $tasks.Wake;    Kind = 'Wake' }
    )) {
        if (-not (Update-WallTaskTriggers -Name $entry.Name -Config $config -Kind $entry.Kind)) { $ok = $false }
    }

    # Nur wenn wirklich alle Ausloeser sitzen, gilt der Zeitplan als umgesetzt.
    # Der Fingerabdruck ist die Grundlage dafuer, ob ein Standby gewagt wird.
    $state = Get-WallState
    $state.TaskScheduleFingerprint = if ($ok) { Get-ScheduleFingerprint -Config $config } else { $null }
    Save-WallState $state
}

function Invoke-Reconcile {
    <#
        Bringt den tatsaechlichen Zustand mit dem Zeitplan in Deckung.

        Dadurch wirkt eine Aenderung von aussen auch dann, wenn der passende
        Zeitpunkt schon vorbei ist: wird die Weckzeit mittags auf 11:00
        vorgezogen, startet der naechste Abgleich den Tagbetrieb, ohne auf den
        naechsten Ausloeser zu warten.
    #>
    [CmdletBinding()]
    param()

    $config = Get-WallConfig
    $state = Get-WallState
    $tasks = Get-WallTaskNames

    $night = Test-InsideSleepWindow -Config $config -State $state
    $sleepTask = Get-WallTask -Name $tasks.Sleep
    $sleepRunning = ($sleepTask -and $sleepTask.State -eq 'Running')

    if ($night) {
        if ($sleepRunning) { return }
        Write-WallLog 'Abgleich: Nachtbetrieb soll gelten, Nacht-Aufgabe wird gestartet.'
        Start-WallTask -Name $tasks.Sleep | Out-Null
        return
    }

    if ($sleepRunning -or $state.DisplayState -eq 'off') {
        Write-WallLog 'Abgleich: Tagbetrieb soll gelten, Weck-Aufgabe wird gestartet.'
        Start-WallTask -Name $tasks.Wake | Out-Null
    }
}


# ------------------------------------------------------------------------ Status

function Invoke-StatusAction {
    $config = Get-WallConfig
    $state = Get-WallState
    $mode = Resolve-EffectiveMode -Config $config -State $state
    $tasks = Get-WallTaskNames
    $paths = Get-WallPaths

    Write-Host ''
    Write-Host '=== Wand-Display Energiesteuerung ===' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Konfiguration'
    Write-Host ('  Datei                 : {0}' -f $(if ($config.SourceFile) { $config.SourceFile } else { '(Standardwerte)' }))
    Write-Host '  Wochenplan (Panel AN) :'
    $kurz = @{ Monday = 'Mo'; Tuesday = 'Di'; Wednesday = 'Mi'; Thursday = 'Do'; Friday = 'Fr'; Saturday = 'Sa'; Sunday = 'So' }
    foreach ($day in @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')) {
        $window = $config.Windows[$day]
        if ($window) {
            $hinweis = if ($window.CrossesMidnight) { ' (bis zum Folgetag)' } else { '' }
            Write-Host ('      {0}  {1:hh\:mm} - {2:hh\:mm}{3}' -f $kurz[$day], $window.On, $window.Off, $hinweis)
        } else {
            Write-Host ('      {0}  aus' -f $kurz[$day]) -ForegroundColor DarkGray
        }
    }
    Write-Host ('  Modus (konfiguriert)  : {0}' -f $config.Mode)
    Write-Host ('  Modus (aktiv)         : {0}' -f $mode) -ForegroundColor $(if ($mode -eq $config.Mode) { 'Green' } else { 'Yellow' })
    Write-Host ('  Zeitplan aktiv        : {0}' -f $(if ($config.Enabled) { 'ja' } else { 'NEIN' })) -ForegroundColor $(if ($config.Enabled) { 'Gray' } else { 'Yellow' })

    $schlaeft = Test-InsideSleepWindow -Config $config -State $state
    Write-Host ('  Panel soll jetzt      : {0}' -f $(if ($schlaeft) { 'schlafen' } else { 'AN sein' })) -ForegroundColor $(if ($schlaeft) { 'Gray' } else { 'Green' })
    if ($schlaeft) {
        $next = Get-NextWindowStart -Windows $config.Windows
        Write-Host ('  Naechstes Fenster ab  : {0}' -f $(if ($next) { $next.ToString('dddd dd.MM. HH:mm') } else { '-' }))
    } else {
        $end = Get-CurrentWindowEnd -Windows $config.Windows
        Write-Host ('  Fenster endet         : {0}' -f $(if ($end) { $end.ToString('dddd dd.MM. HH:mm') } else { '- (uebersteuert)' }))
    }

    Write-Host ''
    Write-Host 'Fernsteuerung'
    $sync = Get-SyncConfig
    if (-not $sync) {
        Write-Host '  nicht eingerichtet (Panel arbeitet nur mit der lokalen Konfiguration)' -ForegroundColor DarkGray
    } else {
        Write-Host ('  Server                 : {0}' -f $sync.ServerUrl)
        Write-Host ('  Panel-Kennung          : {0}' -f $sync.PanelId)
        Write-Host ('  Letzter Abruf erfolgr. : {0}' -f (Format-WallTime $state.SyncLastSuccessUtc))
        $syncFails = [int]$state.SyncConsecutiveFailures
        Write-Host ('  Fehlversuche in Folge  : {0}' -f $syncFails) -ForegroundColor $(if ($syncFails -gt 0) { 'Yellow' } else { 'Gray' })
        if ($state.SyncLastError) {
            Write-Host ('  Letzter Fehler         : {0}' -f $state.SyncLastError) -ForegroundColor Yellow
        }
    }
    foreach ($override in @(
        @{ Label = 'Wach bis (Server)      '; Value = $state.ForceAwakeUntilUtc },
        @{ Label = 'Wach bis (Befehl)      '; Value = $state.CommandAwakeUntilUtc },
        @{ Label = 'Schlaf bis (Befehl)    '; Value = $state.CommandSleepUntilUtc }
    )) {
        $local = ConvertFrom-WallUtc $override.Value
        if ($local -and $local -gt (Get-Date)) {
            Write-Host ('  {0}: {1:dd.MM.yyyy HH:mm}' -f $override.Label, $local) -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host 'Zustand'
    Write-Host ('  Bildschirm             : {0}' -f $state.DisplayState)
    Write-Host ('  Letzter Standby-Start  : {0}' -f (Format-WallTime $state.LastSuspendAttemptUtc))
    Write-Host ('  Letztes Aufwachen      : {0}' -f (Format-WallTime $state.LastWakeUtc))
    Write-Host ('  Letzter Zeitgeber      : {0}' -f (Format-WallTime $state.LastPrewakeUtc))
    Write-Host ('  Abweichung letzte Nacht: {0}' -f $(if ($null -ne $state.LastWakeDelayMinutes) { "$($state.LastWakeDelayMinutes) min" } else { '-' }))
    Write-Host ('  Fehlversuche in Folge  : {0} (Grenze {1})' -f [int]$state.ConsecutiveWakeFailures, [int]$config.MaxWakeFailures)
    if ($state.FallbackReason) {
        Write-Host ('  Hinweis                : {0}' -f $state.FallbackReason) -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Aufgaben'
    foreach ($name in @($tasks.Sleep, $tasks.Prewake, $tasks.Wake, $tasks.Sync)) {
        $task = Get-WallTask -Name $name
        if (-not $task) {
            Write-Host ('  {0,-10} : nicht eingerichtet' -f $name) -ForegroundColor Yellow
            continue
        }
        $info = $null
        try { $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop } catch { }
        $next = if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('dd.MM. HH:mm') } else { '-' }
        $last = if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 1999) { $info.LastRunTime.ToString('dd.MM. HH:mm') } else { '-' }
        $wake = if ($task.Settings.WakeToRun) { 'ja' } else { 'nein' }
        Write-Host ('  {0,-10} : Status {1}, naechster Start {2}, letzter Start {3}, weckt auf: {4}' -f $name, $task.State, $next, $last, $wake)
    }

    Write-Host ''
    Write-Host 'Energieoptionen'
    $states = Get-SleepStateSupport
    Write-Host ('  Schlafzustaende       : {0}' -f $(if (@($states.Available).Count) { ($states.Available -join ', ') } else { 'unbekannt' }))
    if ($states.ModernStandby) {
        Write-Host '  Hinweis               : Modern Standby (S0). Hier ist das Aufwachen per Zeitgeber geraeteabhaengig.' -ForegroundColor Yellow
    }
    $wakeTimers = Get-WakeTimerSetting
    $wakeText = switch ($wakeTimers) { $true { 'erlaubt' } $false { 'DEAKTIVIERT' } default { 'nicht ermittelbar' } }
    Write-Host ('  Aufwachzeitgeber      : {0}' -f $wakeText) -ForegroundColor $(if ($wakeTimers -eq $false) { 'Red' } else { 'Gray' })

    $lock = Get-ConsoleLockSetting
    $lockText = switch ($lock) { $true { 'JA - Panel zeigt dann den Sperrbildschirm' } $false { 'nein' } default { 'nicht ermittelbar' } }
    Write-Host ('  Anmeldung nach Wecken : {0}' -f $lockText) -ForegroundColor $(if ($lock -eq $true) { 'Red' } else { 'Gray' })

    # Nach einem Treiber- oder Windows-Update kann ein Geraet sein Weckrecht
    # zurueckbekommen. Dann wecken Beruehrungen das Panel nachts wieder, und
    # hier sieht man es. Abhilfe: Install.ps1 erneut laufen lassen.
    $armedDevices = @(Get-WakeArmedDevices -Map (Get-WallPnpClassMap))
    if ($armedDevices.Count) {
        Write-Host ('  Weckberechtigte Geraete: {0}' -f ($armedDevices -join ', ')) -ForegroundColor Yellow
    } else {
        Write-Host '  Weckberechtigte Geraete: keine (nur der Zeitgeber weckt das Panel)'
    }

    $lang = Get-SystemLanguageInfo
    Write-Host ('  Systemsprache         : {0} (ohne Einfluss: Konten ueber SIDs, Energieoptionen ueber GUIDs)' -f $lang.UiCulture) -ForegroundColor DarkGray

    Write-Host ''
    Write-Host ('Protokoll: {0}' -f $paths.LogFile)
    foreach ($line in (Get-WallLogTail -Lines 15)) { Write-Host ('  ' + $line) -ForegroundColor DarkGray }
    Write-Host ''
}

function Format-WallTime {
    param([AllowNull()]$Utc)
    $local = ConvertFrom-WallUtc $Utc
    if (-not $local) { return '-' }
    return $local.ToString('dd.MM.yyyy HH:mm:ss')
}


# ---------------------------------------------------------------------- Diagnose

function Invoke-DiagnoseAction {
    Invoke-StatusAction

    Write-Host '=== Diagnose ===' -ForegroundColor Cyan

    $probes = @(
        @{ Title = 'powercfg /a (Schlafzustaende)';        Args = @('/a') },
        @{ Title = 'powercfg /waketimers (aktive Zeitgeber)'; Args = @('/waketimers') },
        @{ Title = 'powercfg /lastwake (letzter Weckgrund)';  Args = @('/lastwake') },
        @{ Title = 'powercfg /requests (Sperren)';            Args = @('/requests') },
        @{ Title = 'powercfg /devicequery wake_armed';        Args = @('/devicequery', 'wake_armed') }
    )

    foreach ($probe in $probes) {
        Write-Host ''
        Write-Host ('--- {0}' -f $probe.Title) -ForegroundColor Cyan
        try {
            & powercfg.exe @($probe.Args) | ForEach-Object { Write-Host ('  ' + $_) }
        } catch {
            Write-Host ('  Fehler: {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }

    Write-Host ''
    Write-Host '--- Letzte Standby-/Aufwach-Ereignisse' -ForegroundColor Cyan
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 } -MaxEvents 5 -ErrorAction Stop |
            ForEach-Object { Write-Host ('  {0:dd.MM.yyyy HH:mm:ss}  {1}' -f $_.TimeCreated, (($_.Message -split "`r?`n" | Where-Object { $_ -match '\S' }) -join ' | ')) }
    } catch {
        Write-Host '  Keine Ereignisse gefunden (das Geraet war moeglicherweise noch nie im Standby).' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '--- Unerwartete Neustarts / Stromausfaelle (Kernel-Power 41)' -ForegroundColor Cyan
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 } -MaxEvents 3 -ErrorAction Stop |
            ForEach-Object { Write-Host ('  {0:dd.MM.yyyy HH:mm:ss}' -f $_.TimeCreated) }
    } catch {
        Write-Host '  Keine gefunden.' -ForegroundColor DarkGray
    }
    Write-Host ''
}


# --------------------------------------------------------------------- Selbsttest

function Invoke-SelfTestAction {
    if (-not (Test-WallAdmin)) {
        throw 'Der Selbsttest braucht Administratorrechte, weil dafuer eine Aufgabe mit Aufwachzeitgeber angelegt wird.'
    }

    $tasks = Get-WallTaskNames
    $paths = Get-WallPaths
    $testTask = 'SelfTestWake'
    $target = (Get-Date).AddMinutes($SelfTestMinutes)

    Write-Host ''
    Write-Host ('Selbsttest: Das Geraet geht jetzt in den Energiesparmodus und soll um {0:HH:mm:ss} von selbst aufwachen.' -f $target) -ForegroundColor Cyan
    Write-Host 'Bitte in dieser Zeit weder Maus, Tastatur noch das Touchpanel beruehren.' -ForegroundColor Yellow
    for ($i = 10; $i -gt 0; $i--) {
        Write-Host ("`rStart in {0,2} s ... (Abbruch mit Strg+C)" -f $i) -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host ''

    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Prewake' -f $paths.ScriptFile)
        $trigger = New-ScheduledTaskTrigger -Once -At $target
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([timespan]::FromMinutes(5)) -MultipleInstances IgnoreNew

        Register-ScheduledTask -TaskPath $tasks.Path -TaskName $testTask -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Description 'Einmaliger Aufwach-Test des Wandpanels' -Force | Out-Null

        Write-WallLog ('Selbsttest gestartet, geplantes Aufwachen {0:HH:mm:ss}.' -f $target)

        Write-Host ''
        Write-Host 'Angemeldete Aufwachzeitgeber:' -ForegroundColor Cyan
        & powercfg.exe /waketimers | ForEach-Object { Write-Host ('  ' + $_) }
        Write-Host ''

        Set-DisplayPower -State Off
        Start-Sleep -Seconds 2

        $before = Get-Date
        $accepted = Invoke-SystemSuspend
        $slept = (Get-Date) - $before

        Set-DisplayPower -State On
        Start-Sleep -Seconds 1

        Write-Host ''
        if (-not $accepted -or $slept.TotalSeconds -lt 20) {
            Write-Host ('FEHLGESCHLAGEN: Das Geraet ist nicht in den Energiesparmodus gewechselt (Rueckgabe={0}, Dauer={1} s).' -f $accepted, [int]$slept.TotalSeconds) -ForegroundColor Red
            Write-Host 'Empfehlung: Modus in der Konfiguration auf "DisplayOnly" setzen, oder im BIOS/UEFI den Standby (S3) freigeben.' -ForegroundColor Yellow
            Write-WallLog -Level ERROR 'Selbsttest: Standby nicht moeglich.'
            return
        }

        $delay = (Get-Date) - $target
        Write-Host ('Schlafdauer: {0} Minuten, Abweichung zur Weckzeit: {1} Sekunden.' -f [math]::Round($slept.TotalMinutes, 1), [int]$delay.TotalSeconds)
        Write-Host ''
        Write-Host 'Letzter Weckgrund laut Windows:' -ForegroundColor Cyan
        & powercfg.exe /lastwake | ForEach-Object { Write-Host ('  ' + $_) }
        Write-Host ''

        if ([math]::Abs($delay.TotalSeconds) -le 90) {
            Write-Host 'ERFOLGREICH: Das Geraet wacht per Zeitgeber zuverlaessig auf. Der Modus "Combined" kann verwendet werden.' -ForegroundColor Green
            Write-WallLog ('Selbsttest erfolgreich, Abweichung {0} s.' -f [int]$delay.TotalSeconds)
        } else {
            Write-Host 'FEHLGESCHLAGEN: Das Geraet ist nicht zur geplanten Zeit aufgewacht.' -ForegroundColor Red
            Write-Host 'Empfehlung: Im BIOS/UEFI "Wake on RTC" aktivieren und ErP/Deep-Sleep deaktivieren, danach erneut testen.' -ForegroundColor Yellow
            Write-Host 'Alternativ Modus in der Konfiguration auf "DisplayOnly" setzen.' -ForegroundColor Yellow
            Write-WallLog -Level ERROR ('Selbsttest fehlgeschlagen, Abweichung {0} s.' -f [int]$delay.TotalSeconds)
        }
    } finally {
        try {
            Unregister-ScheduledTask -TaskPath $tasks.Path -TaskName $testTask -Confirm:$false -ErrorAction Stop
        } catch { }
    }
}


# ------------------------------------------------------------------------- Reset

function Invoke-ResetAction {
    $config = Get-WallConfig
    $state = Get-WallState
    $state.EffectiveMode = $null
    $state.FallbackReason = $null
    $state.ConsecutiveWakeFailures = 0
    $state.ExpectedWakeUtc = $null
    Save-WallState $state
    Write-WallLog ('Rueckstufung aufgehoben, es gilt wieder der konfigurierte Modus "{0}".' -f $config.Mode)
}


# ----------------------------------------------------------------------- Einstieg

try {
    switch ($Action) {
        'Sleep'      { Invoke-SleepAction }
        'Wake'       { Invoke-WakeAction }
        'Prewake'    { Invoke-PrewakeAction }
        'Sync'       { Invoke-SyncAction }
        'Status'     { Invoke-StatusAction }
        'Diagnose'   { Invoke-DiagnoseAction }
        'SelfTest'   { Invoke-SelfTestAction }
        'Reset'      { Invoke-ResetAction }
        'DisplayOff' { Set-DisplayPower -State Off }
        'DisplayOn'  { Set-DisplayPower -State On }
    }
    exit 0
} catch {
    Write-WallLog -Level ERROR ('Aktion "{0}" abgebrochen: {1}' -f $Action, $_.Exception.Message)
    Write-Error $_
    exit 1
}
