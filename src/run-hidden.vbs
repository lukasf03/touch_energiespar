' Startet WallDisplay.ps1 ohne sichtbares Konsolenfenster.
' Aufruf: wscript.exe run-hidden.vbs "<Pfad zu WallDisplay.ps1>" <Aktion>
' Damit erscheint auf dem Wandpanel kein kurz aufblitzendes PowerShell-Fenster.

Option Explicit

Dim shell, scriptPath, actionName, commandLine

If WScript.Arguments.Count < 2 Then
    WScript.Quit 2
End If

scriptPath = WScript.Arguments(0)
actionName = WScript.Arguments(1)

Set shell = CreateObject("WScript.Shell")

commandLine = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ _
    & scriptPath & """ -Action " & actionName

' 0 = unsichtbares Fenster, True = auf das Ende warten (damit die Aufgabe
' erst endet, wenn das Skript fertig ist).
WScript.Quit shell.Run(commandLine, 0, True)
