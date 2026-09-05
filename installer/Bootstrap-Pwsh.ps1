<#
.SYNOPSIS
    Installs a portable PowerShell 7 for the current user, so the Heresay installer
    can run. No admin rights, ever.

.DESCRIPTION
    This script runs on stock Windows PowerShell 5.1 and deliberately uses no
    PowerShell-7-only syntax. It downloads the official Microsoft PowerShell 7
    win-x64 ZIP (Microsoft-signed binaries - no new unsigned executables), verifies
    its SHA-256 against the hash pinned below BEFORE extracting anything, and
    extracts it to %LOCALAPPDATA%\Programs\PowerShell7. Nothing is written to HKLM,
    Program Files, or PATH; removing it is deleting that one folder.

    Exit code 0 means %LOCALAPPDATA%\Programs\PowerShell7\pwsh.exe exists and runs.
    Anything else is a failure, explained on the console in plain language.

    Normally launched by the Install-Heresay.vbs setup window when no PowerShell 7
    is found on the machine.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ------------------------------------------------------------------ pinned release --
# PINNED, never "latest at runtime": the exact bytes this script will trust are decided
# here, once, and every machine verifies the download against this hash before touching
# it. Bump all three values together when moving to a newer release.
#
# sha256VerifiedFrom: MEASURED 2026-08-27 - the ZIP at this exact URL was downloaded on
# the reference device and hashed locally with Get-FileHash -Algorithm SHA256, and that
# result was cross-checked against the release's own published hash list,
# https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/hashes.sha256
# (line: "32eb8f6cdce08f86e987d625a2733e54ac3e289ae7e1621b14c0b5bcec2434ea
# *PowerShell-7.6.5-win-x64.zip"). The two agree.
# NOTE: an HTTP ETag is NOT the file hash. An ETag on a release asset is the CDN's
# entity tag for that response, not the content's SHA-256 - this project has mistaken
# one for the other before (see notes[] in contracts/download-manifest.json). Only a
# locally computed Get-FileHash over the actual bytes counts.
$PinnedVersion = '7.6.5'
$PinnedUrl     = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/PowerShell-7.6.5-win-x64.zip'
$PinnedSha256  = '32eb8f6cdce08f86e987d625a2733e54ac3e289ae7e1621b14c0b5bcec2434ea'

$TargetDir = Join-Path $env:LOCALAPPDATA 'Programs\PowerShell7'
$TargetExe = Join-Path $TargetDir 'pwsh.exe'

function Write-Step {
    param([string] $Text)
    Write-Host "  $Text"
}

function Test-PwshRuns {
    # True if $TargetExe starts and reports major version 7. Never throws.
    param()
    if (-not (Test-Path -LiteralPath $TargetExe)) { return $false }
    try {
        $out = & $TargetExe -NoProfile -Command '$PSVersionTable.PSVersion.Major' 2>$null
        $text = (@($out) -join '').Trim()
        if ($LASTEXITCODE -eq 0 -and $text -eq '7') { return $true }
    }
    catch { }
    return $false
}

function Invoke-BootstrapDownload {
    <# Stream the URL to $Destination, printing progress every 20 MB. Uses the system
       proxy with default credentials, mirroring Install-Common.ps1's Get-TiHttpClient,
       so the corporate proxy and its TLS inspection are honoured. #>
    param(
        [string] $Url,
        [string] $Destination
    )
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.AllowAutoRedirect = $true
    $request.UserAgent = 'TranscribeIt-Bootstrap/1.0'
    $request.Timeout = 100000          # connect + first byte, ms
    $request.ReadWriteTimeout = 300000 # per read, ms
    try {
        $request.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    }
    catch {
        Write-Step "(Could not attach the system proxy: $($_.Exception.Message). Trying anyway.)"
    }
    $response = $request.GetResponse()
    try {
        $total = $response.ContentLength
        $inStream = $response.GetResponseStream()
        $outStream = [System.IO.File]::Create($Destination)
        try {
            $buffer = New-Object byte[] (256KB)
            $done = [long]0
            $nextReport = [long](20MB)
            while ($true) {
                $read = $inStream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $outStream.Write($buffer, 0, $read)
                $done += $read
                if ($done -ge $nextReport) {
                    if ($total -gt 0) {
                        Write-Step ("... {0} MB of {1} MB" -f [int]($done / 1MB), [int]($total / 1MB))
                    }
                    else {
                        Write-Step ("... {0} MB so far" -f [int]($done / 1MB))
                    }
                    $nextReport += [long](20MB)
                }
            }
        }
        finally {
            $outStream.Dispose()
            $inStream.Dispose()
        }
    }
    finally {
        $response.Close()
    }
}

# ------------------------------------------------------------------------- main --
try {
    Write-Host ''
    Write-Step "Heresay needs PowerShell 7 to run its installer."

    # Already there and working? Then this is a no-op.
    if (Test-PwshRuns) {
        Write-Step "Good news - PowerShell 7 is already set up at:"
        Write-Step "  $TargetExe"
        Write-Host ''
        exit 0
    }
    if (Test-Path -LiteralPath $TargetExe) {
        Write-Step "A copy exists at $TargetExe but it does not run cleanly."
        Write-Step "Reinstalling it fresh."
    }

    # Windows PowerShell 5.1 may default to a protocol list GitHub refuses; make sure
    # TLS 1.2 is on the list before the first request.
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Step "(Could not enable TLS 1.2: $($_.Exception.Message). Trying anyway.)"
    }

    $zipName  = "PowerShell-$PinnedVersion-win-x64.zip"
    $zipPath  = Join-Path $env:TEMP $zipName
    $partPath = "$zipPath.part"

    # Reuse an already-downloaded, already-verified ZIP if one is sitting in TEMP.
    $haveVerifiedZip = $false
    if (Test-Path -LiteralPath $zipPath) {
        $existingHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($existingHash -eq $PinnedSha256) {
            Write-Step "Found an already-downloaded copy in your temp folder - reusing it."
            $haveVerifiedZip = $true
        }
        else {
            Remove-Item -LiteralPath $zipPath -Force
        }
    }

    if (-not $haveVerifiedZip) {
        # Download to a .part file, verify the hash, and only then rename - so a file
        # with the real name is always a verified file.
        $maxAttempts = 3
        $attempt = 0
        $downloaded = $false
        while (-not $downloaded -and $attempt -lt $maxAttempts) {
            $attempt++
            try {
                if (Test-Path -LiteralPath $partPath) {
                    Remove-Item -LiteralPath $partPath -Force
                }
                if ($attempt -eq 1) {
                    Write-Step "Downloading PowerShell $PinnedVersion from Microsoft's official"
                    Write-Step "GitHub release (about 110 MB). This is a one-time step..."
                }
                else {
                    Write-Step "Retrying the download (attempt $attempt of $maxAttempts)..."
                }
                Invoke-BootstrapDownload -Url $PinnedUrl -Destination $partPath
                $downloaded = $true
            }
            catch {
                Write-Step "That attempt failed: $($_.Exception.Message)"
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds (5 * $attempt)
                }
            }
        }
        if (-not $downloaded) {
            Write-Host ''
            Write-Step "The download did not succeed after $maxAttempts attempts."
            Write-Step "Check your network connection and run the installer again."
            Write-Step "If it keeps failing, ask IT to install PowerShell 7, or run:"
            Write-Step "    winget install Microsoft.PowerShell"
            exit 1
        }

        Write-Step "Checking the download is the genuine, untampered file..."
        $actualHash = (Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash
        if ($actualHash -ne $PinnedSha256) {
            Remove-Item -LiteralPath $partPath -Force
            Write-Host ''
            Write-Step "The downloaded file's fingerprint does not match the expected one:"
            Write-Step "  expected SHA-256: $PinnedSha256"
            Write-Step "  actual   SHA-256: $($actualHash.ToLower())"
            Write-Step "The file has been deleted and nothing was installed. This usually"
            Write-Step "means the download was corrupted or altered in transit (a proxy"
            Write-Step "rewriting the body, a cached error page, or tampering). Try again;"
            Write-Step "if it keeps happening, ask IT to install PowerShell 7 instead."
            exit 1
        }
        Move-Item -LiteralPath $partPath -Destination $zipPath -Force
        Write-Step "Verified. SHA-256 matches the pinned Microsoft release hash."
    }

    Write-Step "Unpacking to $TargetDir ..."
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $TargetDir -Force

    if (-not (Test-Path -LiteralPath $TargetExe)) {
        Write-Host ''
        Write-Step "Unpacking finished but pwsh.exe is not where it should be:"
        Write-Step "  $TargetExe"
        Write-Step "Ask IT to install PowerShell 7, or run: winget install Microsoft.PowerShell"
        exit 1
    }

    # Smoke test: prove the freshly extracted pwsh actually starts on THIS machine.
    # If it will not start, the likeliest cause on this fleet is the endpoint security
    # agent blocking it - say so, and name the fallback.
    Write-Step "Checking the new PowerShell 7 starts..."
    $smokeOk = $false
    try {
        & $TargetExe -NoProfile -Command 'exit 0' 2>$null
        if ($LASTEXITCODE -eq 0) { $smokeOk = $true }
    }
    catch {
        Write-Step "It would not start: $($_.Exception.Message)"
    }
    if (-not $smokeOk) {
        Write-Host ''
        Write-Step "PowerShell 7 was unpacked correctly but Windows would not run it."
        Write-Step "On this kind of managed machine that usually means the endpoint"
        Write-Step "security agent is blocking it, and there is nothing this script"
        Write-Step "can do about that. Please either:"
        Write-Step "  - ask IT to install PowerShell 7 for you, or"
        Write-Step "  - if winget works on your machine, run:"
        Write-Step "        winget install Microsoft.PowerShell"
        Write-Step "then double-click 'Install-Heresay.vbs' again."
        exit 1
    }

    # Tidy up the 110 MB ZIP now that it has served its purpose.
    try { Remove-Item -LiteralPath $zipPath -Force } catch { }

    Write-Host ''
    Write-Step "PowerShell 7 is ready at:"
    Write-Step "  $TargetExe"
    Write-Host ''
    exit 0
}
catch {
    Write-Host ''
    Write-Step "Something unexpected went wrong: $($_.Exception.Message)"
    Write-Step "Nothing harmful was done. Please either:"
    Write-Step "  - ask IT to install PowerShell 7 for you, or"
    Write-Step "  - if winget works on your machine, run:"
    Write-Step "        winget install Microsoft.PowerShell"
    Write-Step "then double-click 'Install-Heresay.vbs' again."
    exit 1
}
