' Run-Hidden.vbs - launch a PowerShell script with NO console window, ever.
'
' WHY THIS EXISTS: pwsh.exe is a console-subsystem executable, so Windows creates its
' console host window at process creation, and that window stays on screen until pwsh
' has started up and parsed -WindowStyle Hidden - measured ~2.3 s on this machine
' under the endpoint-security process-creation tax. A shortcut that targets pwsh.exe
' directly therefore ALWAYS flashes a console for those seconds, whatever flags it
' passes. wscript.exe is a GUI-subsystem host: it never owns a console, and it starts
' pwsh below with window style 0 (SW_HIDE), so nothing ever appears.
'
' Usage:  wscript.exe Run-Hidden.vbs <full path to a .ps1> [arguments for that script]
'
' pwsh.exe is located at RUN TIME, not hardcoded: %ProgramFiles%\PowerShell\7 first,
' then the portable per-user copy at %LOCALAPPDATA%\Programs\PowerShell7 that
' installer\Bootstrap-Pwsh.ps1 lays down when the Program Files install is absent
' (no admin on this fleet).
'
' Every argument is re-quoted individually because the Send To menu appends the
' selected media file paths to the shortcut's command line, and those paths contain
' spaces - joining them unquoted would split "C:\call recordings\a.m4a" into two
' arguments. Uniform quoting is safe on the receiving side: pwsh's -File argument
' parser sees tokens AFTER quote removal, so a quoted "-Model" still binds as the
' parameter and quoted bare paths still land in the script's remaining-arguments
' parameter (SendTo-Heresay.ps1 declares PositionalBinding=$false for exactly that).
' VBS note: inside a VBS string literal a double quote is escaped by doubling it ("").

Option Explicit

Dim vbsArgs, cmd, i
Set vbsArgs = WScript.Arguments

If vbsArgs.Count < 1 Then
    ' No script to run. Exit silently: this shim is only ever launched from a
    ' shortcut, so there is no console to print usage to.
    WScript.Quit 1
End If

' Resolve pwsh.exe at run time: the machine-wide install first, then the portable
' per-user copy that installer\Bootstrap-Pwsh.ps1 installs when Program Files pwsh
' is absent (no admin on this fleet).
Dim shell, fso, pwshPath, candidate
Set shell = WScript.CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

pwshPath = ""
For Each candidate In Array( _
        "%ProgramFiles%\PowerShell\7\pwsh.exe", _
        "%LOCALAPPDATA%\Programs\PowerShell7\pwsh.exe")
    candidate = shell.ExpandEnvironmentStrings(candidate)
    If fso.FileExists(candidate) Then
        pwshPath = candidate
        Exit For
    End If
Next

If pwshPath = "" Then
    ' No pwsh.exe in either location. Exit silently: this is a GUI-context shim
    ' with nowhere to print an error. The installer preflight (Find-TiPwsh) checks
    ' the same locations before anything is registered, so a completed install
    ' never reaches this branch in practice.
    WScript.Quit 3
End If

' Same flags the Send To shortcuts passed when they targeted pwsh directly.
' -WindowStyle Hidden is belt-and-braces here (the Run call's window style 0 already
' hides everything) but keeps a copied command line behaving the same anywhere.
cmd = """" & pwshPath & """" & _
      " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden" & _
      " -File """ & vbsArgs(0) & """"

For i = 1 To vbsArgs.Count - 1
    cmd = cmd & " """ & vbsArgs(i) & """"
Next

' 0 = SW_HIDE: the launched process gets no visible window.
' False = do not wait: Send To should return to Explorer immediately.
shell.Run cmd, 0, False
