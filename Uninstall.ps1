<#
.SYNOPSIS
    Entfernt die Energiesteuerung des Wand-Touchpanels.

.DESCRIPTION
    Loescht die geplanten Aufgaben unter \WallDisplayPower\ und schaltet den
    Bildschirm sicherheitshalber ein. Konfiguration und Protokoll bleiben
    erhalten, sofern nicht -RemoveData angegeben wird.

.PARAMETER RemoveData
    Loescht zusaetzlich C:\ProgramData\WallDisplayPower (Konfiguration,
    Zustand und Protokoll).

.PARAMETER RestorePowerDefaults
    Setzt Bildschirm- und Standby-Zeitueberschreitung auf uebliche Werte
    zurueck (Bildschirm 10 Minuten, Standby 30 Minuten) und aktiviert den
    Ruhezustand wieder.

.EXAMPLE
    .\Uninstall.ps1

.EXAMPLE
    .\Uninstall.ps1 -RemoveData -RestorePowerDefaults
#>
[CmdletBinding()]
param(
    [switch]$RemoveData,
    [switch]$RestorePowerDefaults
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\WallDisplay.Core.psm1') -Force -DisableNameChecking

if (-not (Test-WallAdmin)) {
    throw 'Uninstall.ps1 muss in einer PowerShell mit Administratorrechten laufen.'
}

$paths = Get-WallPaths
$tasks = Get-WallTaskNames

Write-Host ''
Write-Host '=== Entfernen der Wand-Display Energiesteuerung ===' -ForegroundColor Cyan

# Eine eventuell laufende Nacht-Aufgabe zuerst beenden, damit der Bildschirm
# nicht gleich wieder ausgeschaltet wird.
New-WallSignal
Stop-WallSleepTask
Start-Sleep -Seconds 3

foreach ($name in @($tasks.Sleep, $tasks.Prewake, $tasks.Wake, $tasks.Sync, 'SelfTestWake')) {
    try {
        Unregister-ScheduledTask -TaskPath $tasks.Path -TaskName $name -Confirm:$false -ErrorAction Stop
        Write-Host ('Aufgabe entfernt : {0}{1}' -f $tasks.Path, $name) -ForegroundColor Green
    } catch {
        Write-Host ('Aufgabe fehlte   : {0}{1}' -f $tasks.Path, $name) -ForegroundColor DarkGray
    }
}

try {
    Set-DisplayPower -State On
} catch {
    Write-Host ('Bildschirm konnte nicht eingeschaltet werden: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
}

if ($RestorePowerDefaults) {
    foreach ($argumentList in @(
        @('/change', 'monitor-timeout-ac', '10'),
        @('/change', 'standby-timeout-ac', '30'),
        @('/hibernate', 'on')
    )) {
        & powercfg.exe @argumentList | Out-Null
    }
    Write-Host 'Energieoptionen auf uebliche Standardwerte zurueckgesetzt.' -ForegroundColor Green
}

Remove-WallSignal

if ($RemoveData) {
    if (Test-Path -LiteralPath $paths.DataRoot) {
        Remove-Item -LiteralPath $paths.DataRoot -Recurse -Force
        Write-Host ('Daten entfernt   : {0}' -f $paths.DataRoot) -ForegroundColor Green
    }
} else {
    Write-Host ('Daten erhalten   : {0}' -f $paths.DataRoot) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Fertig.' -ForegroundColor Cyan
Write-Host ''
