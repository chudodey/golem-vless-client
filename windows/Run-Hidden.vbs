' Hidden launcher for scheduled tasks (watchdog / refresh / runner).
'
' Task Scheduler + "powershell.exe -WindowStyle Hidden" still flashes a console
' window for an instant on every run. wscript.exe is a GUI host and never
' allocates a console, and .Run(..., WindowStyle=0) starts PowerShell fully
' hidden — so the 5-minute watchdog no longer pops up over other windows.
'
' Usage:  wscript.exe Run-Hidden.vbs <script.ps1> [args...]
Option Explicit
If WScript.Arguments.Count = 0 Then
    WScript.Echo "usage: wscript.exe Run-Hidden.vbs <script.ps1> [args...]"
    WScript.Quit 1
End If

Dim shell, cmd, i
Set shell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & Quote(WScript.Arguments(0))
For i = 1 To WScript.Arguments.Count - 1
    cmd = cmd & " " & Quote(WScript.Arguments(i))
Next
' WindowStyle 0 = hidden. bWaitOnReturn=True keeps the scheduled task
' "Running" until the script exits (the runner stays alive as long as
' sing-box runs, same as calling powershell.exe directly).
shell.Run cmd, 0, True

Function Quote(s)
    Quote = """" & s & """"
End Function