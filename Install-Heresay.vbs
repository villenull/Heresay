' Install-Heresay.vbs - single-file installer for Heresay
' https://github.com/villenull/Heresay
'
' Double-click this file. A setup window opens after a few seconds.
' No ZIP to extract, no folder to navigate, no administrator rights needed.
'
' What this does:
'   1. Downloads the latest Heresay-Setup.zip from GitHub Releases (~280 KB).
'   2. Extracts it to a temporary folder.
'   3. Launches the graphical setup window from the extracted package.
'
' Requirements: Windows 10 or 11, internet access for the initial download.
' The first install then downloads ~2.7 GB of speech models - leave the
' setup window open until it finishes.
'
' If Windows shows a "Windows protected your PC" SmartScreen message:
'   click "More info", then "Run anyway". This file is open source.
'
' WHY A .VBS FILE: Windows enterprise policy commonly blocks unsigned .exe
' files. A .vbs file runs via wscript.exe, which is Microsoft-signed and
' always present on Windows, so it passes through those policies unmodified.
Option Explicit

Const ZIP_URL  = "https://github.com/villenull/Heresay/releases/latest/download/Heresay-Setup.zip"
Const APP_NAME = "Heresay"

Dim oShell : Set oShell = CreateObject("WScript.Shell")
Dim oFSO   : Set oFSO   = CreateObject("Scripting.FileSystemObject")

' Unique temp directory so two concurrent runs don't collide.
Dim sTmpDir : sTmpDir = oFSO.GetSpecialFolder(2) & "\Heresay-Bootstrap-" & _
                        oShell.ExpandEnvironmentStrings("%RANDOM%") & "-" & _
                        oShell.ExpandEnvironmentStrings("%RANDOM%")
Dim sPsFile : sPsFile = sTmpDir & ".ps1"

' Windows PowerShell 5.1 is built into every Windows 10/11 installation.
Dim sPwsh : sPwsh = oShell.ExpandEnvironmentStrings("%SystemRoot%") & _
                    "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not oFSO.FileExists(sPwsh) Then
    MsgBox "Windows PowerShell was not found at the expected location." & vbCrLf & _
           vbCrLf & _
           "(" & sPwsh & ")" & vbCrLf & vbCrLf & _
           "Please re-run on a standard Windows 10 or 11 machine.", _
           vbExclamation, APP_NAME
    WScript.Quit 1
End If

' Write a PowerShell bootstrap to a temp file.
' Doing this avoids shell-quoting nightmares and keeps the VBS readable.
Dim oFile : Set oFile = oFSO.CreateTextFile(sPsFile, True, False)
oFile.WriteLine "$ErrorActionPreference = 'Stop'"
oFile.WriteLine "try {"
oFile.WriteLine "    $tmp = '" & sTmpDir & "'"
oFile.WriteLine "    New-Item -ItemType Directory -Force -Path $tmp | Out-Null"
oFile.WriteLine "    $zip = Join-Path $tmp 'Heresay-Setup.zip'"
oFile.WriteLine ""
oFile.WriteLine "    # Download the package. Invoke-WebRequest follows GitHub's redirect."
oFile.WriteLine "    Invoke-WebRequest -Uri '" & ZIP_URL & "' -OutFile $zip -UseBasicParsing"
oFile.WriteLine ""
oFile.WriteLine "    # Extract without shell interaction."
oFile.WriteLine "    Add-Type -AssemblyName System.IO.Compression.FileSystem"
oFile.WriteLine "    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)"
oFile.WriteLine ""
oFile.WriteLine "    # Launch the graphical installer from inside the extracted package."
oFile.WriteLine "    $inst = Join-Path $tmp 'Heresay-Setup\Install Heresay.vbs'"
oFile.WriteLine "    if (-not (Test-Path -LiteralPath $inst)) {"
oFile.WriteLine "        throw 'Installer script not found in the downloaded package. The release may be incomplete.'"
oFile.WriteLine "    }"
oFile.WriteLine "    & wscript.exe $inst"
oFile.WriteLine "} catch {"
oFile.WriteLine "    Add-Type -AssemblyName PresentationFramework"
oFile.WriteLine "    $msg = 'Heresay could not be downloaded or started.' +"
oFile.WriteLine "           [Environment]::NewLine + [Environment]::NewLine +"
oFile.WriteLine "           $_.Exception.Message"
oFile.WriteLine "    [void][System.Windows.MessageBox]::Show($msg, 'Heresay', 'OK', 'Error')"
oFile.WriteLine "}"
oFile.Close

' Run the bootstrap script hidden. The installer's own WPF window is the
' only feedback the user sees - it opens within a few seconds.
' run=0 means SW_HIDE; bWaitOnReturn=False lets wscript exit immediately.
oShell.Run """" & sPwsh & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass" & _
           " -WindowStyle Hidden -File """ & sPsFile & """", 0, False
