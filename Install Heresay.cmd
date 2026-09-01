@echo off
setlocal EnableExtensions
title Heresay installer

echo.
echo  ===================================================================
echo    Heresay - meeting transcription, installed just for you
echo  ===================================================================
echo.
echo    This installs Heresay for YOUR user account only.
echo    No admin rights are needed, and none are asked for.
echo.
echo    The FIRST install downloads about 2.7 GB of speech models and
echo    tools, so it can take a while. Please leave this window open.
echo.

rem Zip guard: double-clicked inside an unextracted ZIP, Explorer extracts
rem only this .cmd to a temp folder - the rest of the files are missing.
if not exist "%~dp0app\Transcribe-Entry.ps1" goto :zipguard

rem ---- prefer the graphical installer --------------------------------------
rem With extensions hidden (the Windows default) this file and Install
rem Heresay.vbs are indistinguishable in Explorer, and a real user clicked this
rem one expecting the setup window (observed 2026-08-28). So both entries lead
rem to the SAME wizard: this hands off to the .vbs, whose wscript host owns no
rem console, and closes. The text-mode flow below is kept for two cases only:
rem an explicit -Console argument, or a package/machine where the GUI pieces
rem are unavailable.
set "CONSOLEMODE="
for %%A in (%*) do if /i "%%~A"=="-Console" set "CONSOLEMODE=1"
if defined CONSOLEMODE goto :consolemode
if not exist "%~dp0installer\Install-Gui.ps1" goto :consolemode
if not exist "%~dp0Install Heresay.vbs" goto :consolemode
echo    Opening the Heresay setup window...
start "" wscript.exe "%~dp0Install Heresay.vbs" %*
exit /b 0

:consolemode

rem ---- locate PowerShell 7 ------------------------------------------------
rem TI_FORCE_PWSH_BOOTSTRAP=1 skips detection so the bootstrap branch can be
rem tested on machines that already have pwsh.
set "PWSH="
if "%TI_FORCE_PWSH_BOOTSTRAP%"=="1" goto :bootstrap
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%LOCALAPPDATA%\Programs\PowerShell7\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Programs\PowerShell7\pwsh.exe"
if not defined PWSH for /f "delims=" %%P in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%P"
if defined PWSH goto :run

:bootstrap
echo    PowerShell 7 was not found on this computer. Setting it up now -
echo    a one-time download of about 110 MB, for your account only...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Bootstrap-Pwsh.ps1"
if errorlevel 1 goto :bootstrapfailed
set "PWSH=%LOCALAPPDATA%\Programs\PowerShell7\pwsh.exe"
if not exist "%PWSH%" goto :bootstrapfailed

:run
echo.
echo    Using PowerShell 7 at: %PWSH%
rem "%~dp0" ends in a backslash, which would escape the closing quote and
rem corrupt the argument - "%~dp0." keeps the quote intact.
set "ARGS=-SourceRoot "%~dp0.""
if exist "%~dp0download-cache\" set "ARGS=%ARGS% -DownloadCache "%~dp0download-cache""
echo.
echo    Starting the installer with this exact command:
echo    "%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Install-TranscribeIt.ps1" %ARGS% %*
echo.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Install-TranscribeIt.ps1" %ARGS% %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto :failed

echo.
echo  ===================================================================
echo    Heresay is installed.
echo.
echo    To transcribe a recording, find it in File Explorer, then
echo    right-click it and choose "Transcribe in PDF"
echo    (you may need "Show more options" first).
echo  ===================================================================
echo.
pause
exit /b 0

:zipguard
rem A real dialog rather than console text: this branch is the very first thing
rem an un-extracted double-click ever shows, so it should not look like a script.
rem The console text stays underneath as the fallback record if the dialog is
rem somehow blocked.
echo    It looks like this file was opened from INSIDE the downloaded ZIP,
echo    so the rest of Heresay's files are not here yet.
echo.
echo    Please do this instead:
echo      1. Right-click the downloaded file and click "Extract All".
echo      2. Open the folder that gets created.
echo      3. Double-click "Install Heresay" in that folder.
echo.
powershell.exe -NoProfile -Command "Add-Type -AssemblyName PresentationFramework; [void][System.Windows.MessageBox]::Show('It looks like this was opened from inside the downloaded ZIP, so the rest of Heresay''s files are not here yet.' + [Environment]::NewLine + [Environment]::NewLine + '1. Right-click the downloaded file and click \"Extract All\".' + [Environment]::NewLine + '2. Open the folder that gets created.' + [Environment]::NewLine + '3. Double-click \"Install Heresay\" in that folder.', 'Heresay setup', 'OK', 'Warning')"
exit /b 1

:bootstrapfailed
echo.
echo    PowerShell 7 could not be set up automatically. The messages above
echo    say why. What you can do:
echo      - ask IT to install PowerShell 7, or
echo      - if winget works on your machine, run:
echo            winget install Microsoft.PowerShell
echo    ...then double-click this file again.
echo.
pause
exit /b 1

:failed
echo.
echo    The install did not finish. The messages above explain what
echo    happened, and the installer printed the location of its log file
echo    above - please send that log to whoever supports Heresay.
echo.
pause
exit /b %RC%
