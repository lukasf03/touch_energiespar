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
    zurueck (Bildschirm 10 Minuten, Standby 30 Minuten), aktiviert den
    Ruhezustand wieder und gibt den Geraeten das Weckrecht zurueck, das die
    Einrichtung ihnen genommen hat (Touchscreen, Tastatur, Maus).

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

foreach ($name in @($tasks.Sleep, $tasks.Prewake, $tasks.Wake, $tasks.Sync, $tasks.Kiosk, 'SelfTestWake')) {
    try {
        Unregister-ScheduledTask -TaskPath $tasks.Path -TaskName $name -Confirm:$false -ErrorAction Stop
        Write-Host ('Aufgabe entfernt : {0}{1}' -f $tasks.Path, $name) -ForegroundColor Green
    } catch {
        Write-Host ('Aufgabe fehlte   : {0}{1}' -f $tasks.Path, $name) -ForegroundColor DarkGray
    }
}

# Ein laufendes Vollbild-Fenster bleibt absichtlich stehen: die Anzeige soll
# nicht verschwinden, nur weil die Energiesteuerung geht.
if (@(Get-KioskProcess).Count) {
    Write-Host 'HINWEIS: Die Strichliste laeuft weiter, kommt nach der naechsten Anmeldung aber nicht mehr von selbst.' -ForegroundColor Yellow
}

try {
    Set-DisplayPower -State On
} catch {
    Write-Host ('Bildschirm konnte nicht eingeschaltet werden: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
}

# Vor dem moeglichen Loeschen der Daten lesen: dort steht, welchen Geraeten
# die Einrichtung das Weckrecht genommen hat.
$disabledWake = @((Get-WallState).DisabledWakeDevices | Where-Object { $_ })

if ($RestorePowerDefaults) {
    foreach ($argumentList in @(
        @('/change', 'monitor-timeout-ac', '10'),
        @('/change', 'standby-timeout-ac', '30'),
        @('/hibernate', 'on')
    )) {
        & powercfg.exe @argumentList | Out-Null
    }
    Write-Host 'Energieoptionen auf uebliche Standardwerte zurueckgesetzt.' -ForegroundColor Green

    if ($disabledWake.Count) {
        Enable-WallDeviceWake -Names $disabledWake
        Write-Host ('Weckrecht zurueckgegeben : {0}' -f ($disabledWake -join ', ')) -ForegroundColor Green
    }
} elseif ($disabledWake.Count) {
    Write-Host ''
    Write-Host ('HINWEIS: Diesen Geraeten fehlt weiterhin das Weckrecht: {0}' -f ($disabledWake -join ', ')) -ForegroundColor Yellow
    Write-Host '         Das Geraet laesst sich dadurch nicht per Touch, Tastatur oder Maus aus dem' -ForegroundColor Yellow
    Write-Host '         Energiesparmodus holen. Zurueckgeben mit -RestorePowerDefaults.' -ForegroundColor Yellow
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
