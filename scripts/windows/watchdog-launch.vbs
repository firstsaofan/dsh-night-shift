' DSH Night-Shift watchdog launcher (Windows Script Host).
'
' Purpose: start watchdog.ps1 without ever creating a console window.
'
' The scheduled task "DSH Night Watchdog" calls this file through wscript.exe.
' Calling pwsh.exe directly flashes a black window on every run, because
' -WindowStyle Hidden only hides the console window *after* it is created.
' wscript.exe is a GUI-subsystem host: it creates no console at all, and the
' child pwsh is started with a hidden window (0) without waiting (False).
'
' pwsh resolution order: %ProgramFiles%\PowerShell\7\pwsh.exe,
' %ProgramFiles%\PowerShell\7-preview\pwsh.exe, then every PATH entry.
' Missing prerequisites are appended to night-shift/watchdog.log.
'
' Exit codes: 0 = launched, 1 = prerequisite missing.
Option Explicit

Dim shell, fso, here, ps1, logPath, pwsh

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(here, "watchdog.ps1")
logPath = fso.BuildPath(fso.GetParentFolderName(here), "watchdog.log")
pwsh = FindPwsh()

If pwsh = "" Then
    LogLine "launcher: pwsh.exe not found (PowerShell 7); cannot run watchdog"
    WScript.Quit 1
End If
If Not fso.FileExists(ps1) Then
    LogLine "launcher: watchdog.ps1 not found at " & ps1
    WScript.Quit 1
End If

' 0 = hidden window, False = do not wait for the child process to exit.
shell.Run """" & pwsh & """ -NoProfile -WindowStyle Hidden -File """ & ps1 & """", 0, False
WScript.Quit 0

Function FindPwsh()
    Dim cand, envPath, parts, i, p
    cand = shell.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell\7\pwsh.exe")
    If fso.FileExists(cand) Then
        FindPwsh = cand
        Exit Function
    End If
    cand = shell.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell\7-preview\pwsh.exe")
    If fso.FileExists(cand) Then
        FindPwsh = cand
        Exit Function
    End If
    envPath = shell.Environment("PROCESS")("PATH")
    parts = Split(envPath, ";")
    For i = 0 To UBound(parts)
        p = parts(i)
        If Len(p) > 0 Then
            If Right(p, 1) <> "\" Then p = p & "\"
            If fso.FileExists(p & "pwsh.exe") Then
                FindPwsh = p & "pwsh.exe"
                Exit Function
            End If
        End If
    Next
    FindPwsh = ""
End Function

Sub LogLine(msg)
    On Error Resume Next
    Dim ts
    Set ts = fso.OpenTextFile(logPath, 8, True)
    ts.WriteLine Now & " " & msg
    ts.Close
End Sub
