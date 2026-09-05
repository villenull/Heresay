# Contributing

Heresay is a Windows-only PowerShell project. Bug reports and focused pull
requests are welcome.

## Before opening a pull request

1. Use Windows 10 or 11 with PowerShell 7 (`pwsh`).
2. Keep application behavior, installer behavior, and release metadata changes in
   separate commits where practical.
3. Run `pwsh -NoProfile -File build/Test-Repository.ps1` from the repository root.
4. If packaging changed, regenerate `Install-Heresay.vbs` with
   `pwsh -NoProfile -File build/Make-Installer-Vbs.ps1` and review the generated
   package contents.
5. Explain any new network request, filesystem location, registry key, or bundled
   dependency in the pull request.

Do not commit downloaded models, build output, recordings, transcripts, logs, or
credentials.

