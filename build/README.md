# Building the Heresay distribution

`Make-Installer-Vbs.ps1` builds the package and embeds it in the single release
asset, `Install-Heresay.vbs`. Run it from anywhere; paths are resolved relative to
the script.

## Usage

```powershell
# Build the release installer (downloads ~2.7 GB on first install)
pwsh -NoProfile -File build\Make-Installer-Vbs.ps1

# Offline package: bundles the pre-seeded component cache (~2.7 GB zip)
pwsh -NoProfile -File build\Make-Installer-Vbs.ps1 -IncludeDownloadCache

# Build or inspect only the intermediate package
pwsh -NoProfile -File build\Make-Distribution.ps1 -NoZip
```

## Distribution parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-OutputDir` | `build\dist` | Where the `Heresay-Setup\` staging folder and the zip land. |
| `-IncludeDownloadCache` | off | Bundle the component cache so the install needs no network. |
| `-DownloadCacheSource` | `%LOCALAPPDATA%\TranscribeIt\downloads` | Where cache files come from. The default mirrors the installer's own `-DownloadCache` default, so a machine that has installed once can build the offline package with no extra flags. |
| `-ZipName` | `Heresay-Setup.zip` / `Heresay-Setup-offline.zip` | Zip file name; the offline name is picked automatically when the cache is bundled. |
| `-NoZip` | off | Stage the folder only. |

## What ships

`app\` (all files), `contracts\` (all files), `installer\`
(the five install scripts + `assets\` — never `tests\`), a generated `README.txt`
for the recipient, a `dist-manifest.json` (build time, git commit, file count —
so any distributed copy traces back to a commit), and optionally `download-cache\`.

Excluded everywhere: `vendor\`, `test\`, `docs\`, `.git`, `installer\tests`,
`*.bak*`, `*.log`, `logs\` folders.

## Notes

- The build **fails loudly** if any required file is missing, including
  `installer\Bootstrap-Pwsh.ps1` and every app file the installer records in its
  `files[]` manifest.
- `Make-Installer-Vbs.ps1` preserves the auditable VBScript header, replaces only
  its comment-only payload, and decodes the result again to prove it matches the
  newly built ZIP byte for byte.
- `-IncludeDownloadCache` copies **only** the files that
  `contracts\download-manifest.json` references (matched by its `filename` fields),
  not the whole cache directory. Manifest entries absent from the local cache are
  warned about, not fatal — the installer downloads them at install time. Every
  bundled file is SHA-256 verified against the manifest at install time before use.
- Requires PowerShell 7 (`pwsh`).
