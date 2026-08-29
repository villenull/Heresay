' Install Heresay.vbs - the double-click entry point for the graphical installer,
' with NO console window, ever.
'
' WHY THIS EXISTS: powershell.exe is a console-subsystem executable, so a shortcut
' or .cmd that starts it ALWAYS flashes a console window at process creation,
' whatever flags it passes. wscript.exe is a GUI-subsystem host: it never owns a
' console, and it starts powershell below with window style 0 (SW_HIDE), so the
' only window the recipient ever sees is the WPF setup window that
' installer\Install-Gui.ps1 opens itself. A classic setup.exe would do the same
' job, but this fleet forbids introducing new unsigned executables, so a .exe
' entry point is not an option - .vbs double-click association is verified intact
' here (assoc .vbs -> WScript).
'
' WHY powershell.exe 5.1 AND NOT pwsh: Windows PowerShell 5.1 is present on every
' Windows box at %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe;
' pwsh 7 may not be installed yet - bootstrapping it is the GUI installer's own
' job. -STA is REQUIRED: the GUI is WPF, which only runs on a single-threaded
' apartment.
'
' Install Heresay.cmd remains alongside this file as the console fallback if .vbs
' execution is ever policy-blocked.
'
' Every argument is re-quoted individually (same pattern as app\Run-Hidden.vbs)
' so a tester invoking this from a shell can pass overrides with spaces in them
' - e.g. -WhatIf or -InstallRoot "C:\some path" - and they arrive at the GUI
' script as the same tokens. Uniform quoting is safe on the receiving side:
' powershell's -File argument parser sees tokens AFTER quote removal, so a quoted
' "-WhatIf" still binds as the switch.
' VBS note: inside a VBS string literal a double quote is escaped by doubling it ("").

Option Explicit

Dim fso, shell, root, guiScript, cmd, vbsArgs, i
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = WScript.CreateObject("WScript.Shell")

root = fso.GetParentFolderName(WScript.ScriptFullName)

' ZIP GUARD: double-clicking this file INSIDE the downloaded zip runs a temp-dir
' copy of just this script, with no app\ folder beside it. That is the single
' most likely first-run mistake, and this is the one place a message can still
' reach the user before the GUI exists - so it explains the fix step by step.
If Not fso.FileExists(root & "\app\Transcribe-Entry.ps1") Then
    MsgBox "Heresay cannot install from inside the zip file." & vbCrLf & vbCrLf & _
           "Please extract it first:" & vbCrLf & vbCrLf & _
           "  1. Right-click the downloaded file and choose ""Extract All...""." & vbCrLf & _
           "  2. Open the new folder that appears." & vbCrLf & _
           "  3. Double-click ""Install Heresay"" again from there.", _
           vbExclamation, "Heresay setup"
    WScript.Quit 1
End If

' PACKAGE GUARD: the extracted folder is present but the GUI installer script is
' not - a truncated download or a hand-pruned copy. Nothing can be repaired from
' here, so say so plainly.
guiScript = root & "\installer\Install-Gui.ps1"
If Not fso.FileExists(guiScript) Then
    MsgBox "This copy of the Heresay setup folder is incomplete:" & vbCrLf & vbCrLf & _
           "  installer\Install-Gui.ps1 is missing." & vbCrLf & vbCrLf & _
           "Please download the package again and extract all of it.", _
           vbExclamation, "Heresay setup"
    WScript.Quit 1
End If

' Windows PowerShell 5.1 - always at this path on this fleet, no lookup needed.
cmd = """" & shell.ExpandEnvironmentStrings("%SystemRoot%") & _
      "\System32\WindowsPowerShell\v1.0\powershell.exe""" & _
      " -NoProfile -STA -ExecutionPolicy Bypass" & _
      " -File """ & guiScript & """"

Set vbsArgs = WScript.Arguments
For i = 0 To vbsArgs.Count - 1
    cmd = cmd & " """ & vbsArgs(i) & """"
Next

' 0 = SW_HIDE: the powershell console never exists; the WPF window appears on its
' own. False = do not wait: the GUI owns its own lifetime, wscript exits at once.
shell.Run cmd, 0, False
