# Building the Heresay distribution

`Make-Distribution.ps1` packages this repo into a folder + zip that a non-technical
colleague can install by double-clicking `Install Heresay.cmd`. Run it from anywhere;
paths are resolved relative to the script.

## Usage

```powershell
# Standard package (~small zip; installer downloads ~2.7 GB on first install)
pwsh -NoProfile -File build\Make-Distribution.ps1

# Offline package: bundles the pre-seeded component cache (~2.7 GB zip)
pwsh -NoProfile -File build\Make-Distribution.ps1 -IncludeDownloadCache

# Folder only, no zip
pwsh -NoProfile -File build\Make-Distribution.ps1 -NoZip
```

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-OutputDir` | `build\dist` | Where the `Heresay-Setup\` staging folder and the zip land. |
| `-IncludeDownloadCache` | off | Bundle the component cache so the install needs no network. |
| `-DownloadCacheSource` | `%LOCALAPPDATA%\TranscribeIt\downloads` | Where cache files come from. The default mirrors the installer's own `-DownloadCache` default, so a machine that has installed once can build the offline package with no extra flags. |
| `-ZipName` | `Heresay-Setup.zip` / `Heresay-Setup-offline.zip` | Zip file name; the offline name is picked automatically when the cache is bundled. |
| `-NoZip` | off | Stage the folder only. |

## What ships

`Install Heresay.cmd`, `app\` (all files), `contracts\` (all files), `installer\`
(the four install scripts + `assets\` — never `tests\`), a generated `README.txt`
for the recipient, a `dist-manifest.json` (build time, git commit, file count —
so any distributed copy traces back to a commit), and optionally `download-cache\`.

Excluded everywhere: `vendor\`, `test\`, `docs\`, `.git`, `installer\tests`,
`*.bak*`, `*.log`, `logs\` folders.

## Notes

- The build **fails loudly** if any required file is missing — including
  `Install Heresay.cmd` and `installer\Bootstrap-Pwsh.ps1`, which are produced by
  other work streams, and every app file the installer records in its
  `files[]` manifest.
- `-IncludeDownloadCache` copies **only** the files that
  `contracts\download-manifest.json` references (matched by its `filename` fields),
  not the whole cache directory. Manifest entries absent from the local cache are
  warned about, not fatal — the installer downloads them at install time. Every
  bundled file is SHA-256 verified against the manifest at install time before use.
- Requires PowerShell 7 (`pwsh`).
