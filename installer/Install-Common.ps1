<#
    Shared helpers for Install-Heresay.ps1 and Uninstall-Heresay.ps1.
    Dot-sourced, not a module, so it works from a plain folder with no PSModulePath
    changes and no execution-policy machinery beyond -ExecutionPolicy Bypass.

    User-scope only.
#>

Set-StrictMode -Version Latest

# ------------------------------------------------------------------- constants --

$script:HERESAY_ProductName = 'Heresay'
$script:HERESAY_ManifestVersion = 1

# ------------------------------------------------------------------ diagnostics --

$script:HERESAY_LogPath = $null
$script:HERESAY_Quiet   = $false
# Must be declared, not just assigned on first use: Set-StrictMode -Version Latest makes
# reading an unset variable a terminating error, which would kill the first download.
$script:HERESAY_HttpClient = $null

function Initialize-HeresayLog {
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Activity = 'installer'
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:HERESAY_LogPath = $Path
    Write-HeresayLog "==== $script:HERESAY_ProductName $Activity log opened $(Get-Date -Format 'u') ===="
}

function Move-HeresayLog {
    <#
        Relocate the log after the fact.

        The installer logs to a temp file during preflight and only moves the log into
        the install root once it has decided to proceed. Otherwise a preflight abort
        would leave an empty <root>\logs\ directory behind, which makes the installer's
        own promise that "nothing was changed" untrue.
    #>
    param([Parameter(Mandatory)][string] $To)
    $from = $script:HERESAY_LogPath
    try {
        $dir = Split-Path -Parent $To
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ($from -and (Test-Path -LiteralPath $from)) {
            $existing = if (Test-Path -LiteralPath $To) { [System.IO.File]::ReadAllText($To) } else { '' }
            [System.IO.File]::WriteAllText($To, $existing + [System.IO.File]::ReadAllText($from), [System.Text.UTF8Encoding]::new($false))
            Remove-Item -LiteralPath $from -Force -ErrorAction SilentlyContinue
        }
        $script:HERESAY_LogPath = $To
        Write-HeresayLog "log relocated from '$from' to '$To'"
    }
    catch { Write-HeresayLog "could not relocate the log to '$To': $($_.Exception.Message)" 'WARN' }
}

function Write-HeresayLog {
    param([string] $Message, [string] $Level = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:HERESAY_LogPath) {
        try { [System.IO.File]::AppendAllText($script:HERESAY_LogPath, "$line`r`n", [System.Text.UTF8Encoding]::new($false)) } catch { }
    }
    Write-Verbose $line
}

function Write-HeresayStep {
    param([string] $Message)
    if (-not $script:HERESAY_Quiet) { Write-Host "==> $Message" -ForegroundColor Cyan }
    Write-HeresayLog $Message
}

function Write-HeresayInfo {
    param([string] $Message)
    if (-not $script:HERESAY_Quiet) { Write-Host "    $Message" }
    Write-HeresayLog $Message
}

function Write-HeresayOk {
    param([string] $Message)
    if (-not $script:HERESAY_Quiet) { Write-Host "    OK   $Message" -ForegroundColor Green }
    Write-HeresayLog "OK: $Message"
}

function Write-HeresayWarn {
    param([string] $Message)
    if (-not $script:HERESAY_Quiet) { Write-Host "    WARN $Message" -ForegroundColor Yellow }
    Write-HeresayLog $Message 'WARN'
}

function Write-HeresayFail {
    param([string] $Message)
    if (-not $script:HERESAY_Quiet) { Write-Host "    FAIL $Message" -ForegroundColor Red }
    Write-HeresayLog $Message 'ERROR'
}

# --------------------------------------------------------------------- plumbing --

function Get-HeresayFieldValue {
    <# Accept documented field aliases so older manifests remain readable. #>
    param(
        # NOT Mandatory on purpose: callers legitimately pass $null for an absent
        # sub-object (e.g. a component with no smokeTest block). [Parameter(Mandatory)]
        # would reject $null at BINDING time, making the guard below unreachable.
        [AllowNull()] $Object,
        [Parameter(Mandatory)][string[]] $Names,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $present = $Object.PSObject.Properties.Name
    foreach ($n in $Names) {
        if ($present -contains $n) {
            $v = $Object.$n
            if ($null -ne $v -and -not ($v -is [string] -and [string]::IsNullOrWhiteSpace($v))) { return $v }
        }
    }
    return $Default
}

function Get-HeresayFileHash256 {
    param([Parameter(Mandatory)][string] $Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() }
        finally { $fs.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Format-HeresayBytes {
    param([long] $Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# -------------------------------------------------------------------- downloads --

function Get-HeresayHttpClient {
    <# One client for the whole run, using the current user's system proxy settings. #>
    if ($script:HERESAY_HttpClient) { return $script:HERESAY_HttpClient }
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    try {
        $handler.UseProxy = $true
        $handler.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $handler.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    }
    catch { Write-HeresayLog "Could not attach the system proxy: $($_.Exception.Message)" 'WARN' }
    $c = [System.Net.Http.HttpClient]::new($handler)
    $c.Timeout = [TimeSpan]::FromMinutes(30)
    $c.DefaultRequestHeaders.UserAgent.ParseAdd("$script:HERESAY_ProductName-Installer/1.0")
    $script:HERESAY_HttpClient = $c
    return $c
}

function Invoke-HeresayDownload {
    <#
    .SYNOPSIS
        Download one file, resuming a part-finished download and retrying on failure.

    .DESCRIPTION
        ~760 MB over an inspecting proxy will fail sometimes, so:
          * bytes land in <target>.part and are resumed with an HTTP Range request
          * each attempt backs off a little further
          * SHA-256 is verified before the .part file is promoted to the real name
          * a hash mismatch deletes the file and throws - never silently accepted

        Returns a result object; throws only on a genuinely unrecoverable failure.
    #>
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $OutFile,
        [string] $Sha256,
        [long]   $ExpectedBytes = 0,
        [int]    $MaxAttempts = 4,
        [switch] $Force
    )

    $name = Split-Path -Leaf $OutFile
    $part = "$OutFile.part"
    $dir  = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Already downloaded and verified? Skip the network entirely.
    if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
        if ($Sha256) {
            $have = Get-HeresayFileHash256 -Path $OutFile
            if ($have -eq $Sha256.ToLowerInvariant()) {
                Write-HeresayOk "$name already present and SHA-256 verified; skipping download."
                return [pscustomobject]@{ Path = $OutFile; Skipped = $true; Bytes = (Get-Item -LiteralPath $OutFile).Length }
            }
            Write-HeresayWarn "$name is present but its hash does not match the manifest; re-downloading."
            Remove-Item -LiteralPath $OutFile -Force
        }
        else {
            Write-HeresayOk "$name already present (no hash in manifest to check); skipping download."
            return [pscustomobject]@{ Path = $OutFile; Skipped = $true; Bytes = (Get-Item -LiteralPath $OutFile).Length }
        }
    }

    $client = Get-HeresayHttpClient
    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $have = 0L
        if (Test-Path -LiteralPath $part) { $have = (Get-Item -LiteralPath $part).Length }

        try {
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
            if ($have -gt 0) {
                $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($have, $null)
                Write-HeresayInfo "$name - resuming at $(Format-HeresayBytes $have) (attempt $attempt/$MaxAttempts)"
            }
            elseif ($attempt -gt 1) { Write-HeresayInfo "$name - retry $attempt/$MaxAttempts" }

            $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()

            # A server that ignores Range restarts the file; drop what we had.
            $appending = $true
            if ($resp.StatusCode -eq [System.Net.HttpStatusCode]::OK -and $have -gt 0) {
                Write-HeresayInfo "$name - server ignored the resume request; starting again from zero."
                $appending = $false
                $have = 0
            }
            elseif ($resp.StatusCode -eq [System.Net.HttpStatusCode]::RequestedRangeNotSatisfiable) {
                # We already hold the whole file.
                $resp.Dispose()
                if (Test-Path -LiteralPath $part) { Move-Item -LiteralPath $part -Destination $OutFile -Force }
                break
            }
            if (-not $resp.IsSuccessStatusCode) {
                throw "HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase)"
            }

            $total = $have
            if ($resp.Content.Headers.ContentLength) { $total = $have + [long]$resp.Content.Headers.ContentLength }
            elseif ($ExpectedBytes -gt 0) { $total = $ExpectedBytes }

            $src = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $mode = if ($appending -and $have -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $dst = [System.IO.FileStream]::new($part, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1MB)
            try {
                $buffer = New-Object byte[] (1MB)
                $written = $have
                $lastReport = [datetime]::MinValue
                $lastGuiReport = [datetime]::MinValue
                while ($true) {
                    $read = $src.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    $dst.Write($buffer, 0, $read)
                    $written += $read
                    if (((Get-Date) - $lastReport).TotalMilliseconds -gt 400) {
                        $lastReport = Get-Date
                        if ($total -gt 0) {
                            $pct = [Math]::Min(100, [Math]::Round(($written / $total) * 100))
                            Write-Progress -Id 7 -Activity "Downloading $name" -Status "$(Format-HeresayBytes $written) of $(Format-HeresayBytes $total)" -PercentComplete $pct
                        }
                        else {
                            Write-Progress -Id 7 -Activity "Downloading $name" -Status (Format-HeresayBytes $written)
                        }
                    }
                    # Machine-readable progress for the GUI wrapper (installer\Install-Gui.ps1); gated so the console experience is untouched.
                    if ($env:HERESAY_INSTALL_GUI -eq '1' -and ((Get-Date) - $lastGuiReport).TotalMilliseconds -ge 500) {
                        $lastGuiReport = Get-Date
                        Write-Host "#HERESAYDL|$name|$written|$total"
                    }
                }
                $dst.Flush()
            }
            finally { $dst.Dispose(); $src.Dispose(); $resp.Dispose() }
            Write-Progress -Id 7 -Activity "Downloading $name" -Completed

            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
            Move-Item -LiteralPath $part -Destination $OutFile -Force
            $lastError = $null
            break
        }
        catch {
            $lastError = $_
            Write-Progress -Id 7 -Activity "Downloading $name" -Completed
            Write-HeresayWarn "$name - attempt $attempt failed: $($_.Exception.Message)"
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds ([Math]::Min(30, 3 * [Math]::Pow(2, $attempt - 1))) }
        }
    }

    if ($lastError) {
        throw "Could not download '$name' from $Uri after $MaxAttempts attempts. Last error: $($lastError.Exception.Message). Partial data is kept at '$part' so a re-run will resume."
    }

    $bytes = (Get-Item -LiteralPath $OutFile).Length
    if ($ExpectedBytes -gt 0 -and $bytes -ne $ExpectedBytes) {
        Write-HeresayWarn "$name is $(Format-HeresayBytes $bytes) but the manifest says $(Format-HeresayBytes $ExpectedBytes)."
    }

    if ($Sha256) {
        $actual = Get-HeresayFileHash256 -Path $OutFile
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            throw @"
SHA-256 MISMATCH for '$name'. The download has been deleted and the install aborted.
  expected : $($Sha256.ToLowerInvariant())
  actual   : $actual
  source   : $Uri
This means the bytes you received are not the bytes the manifest describes. Do not
retry blindly - either the manifest is stale or something modified the download in
transit (a proxy rewriting the body, a cached error page, or tampering).
"@
        }
        Write-HeresayOk "$name - $(Format-HeresayBytes $bytes), SHA-256 verified."
    }
    else {
        Write-HeresayWarn "$name - $(Format-HeresayBytes $bytes) downloaded, but the manifest carries NO SHA-256, so it could not be verified."
    }

    return [pscustomobject]@{ Path = $OutFile; Skipped = $false; Bytes = $bytes }
}

# ------------------------------------------------------------------- extraction --

function Expand-HeresayArchive {
    <# zip via .NET (faster and overwrites cleanly), tar/tar.gz via the bundled tar.exe. #>
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $Destination,
        [string] $ArchiveType,
        [int]    $StripComponents = 0
    )

    if (-not $ArchiveType) {
        $lower = $ArchivePath.ToLowerInvariant()
        $ArchiveType = if ($lower.EndsWith('.zip')) { 'zip' }
                       elseif ($lower.EndsWith('.tar.gz') -or $lower.EndsWith('.tgz')) { 'tar.gz' }
                       elseif ($lower.EndsWith('.tar')) { 'tar' }
                       elseif ($lower.EndsWith('.tar.bz2')) { 'tar.bz2' }
                       elseif ($lower.EndsWith('.tar.xz')) { 'tar.xz' }
                       else { 'none' }
    }

    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

    switch ($ArchiveType) {
        'none' {
            # Not an archive: the payload is the file itself (a GGUF or ONNX model).
            $leaf = Split-Path -Leaf $ArchivePath
            Copy-Item -LiteralPath $ArchivePath -Destination (Join-Path $Destination $leaf) -Force
        }
        'zip' {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            if ($StripComponents -gt 0) {
                $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("ti-zip-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
                [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $staging, $true)
                try { Move-HeresayStripped -From $staging -To $Destination -Strip $StripComponents }
                finally { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
            }
            else {
                [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination, $true)
            }
        }
        default {
            $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
            if (-not (Test-Path -LiteralPath $tar)) { $tar = 'tar' }
            $args = @('-xf', $ArchivePath, '-C', $Destination)
            if ($StripComponents -gt 0) { $args += "--strip-components=$StripComponents" }
            $out = & $tar @args 2>&1
            if ($LASTEXITCODE -ne 0) { throw "tar failed on '$ArchivePath' (exit $LASTEXITCODE): $out" }
        }
    }
}

function Move-HeresayStripped {
    <# Emulate tar --strip-components for zips: drop N leading path segments. #>
    param([string] $From, [string] $To, [int] $Strip)
    Get-ChildItem -LiteralPath $From -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($From.Length).TrimStart('\')
        $parts = $rel -split '\\'
        if ($parts.Count -le $Strip) { return }
        $newRel = ($parts[$Strip..($parts.Count - 1)]) -join '\'
        $dest = Join-Path $To $newRel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Move-Item -LiteralPath $_.FullName -Destination $dest -Force
    }
}

# --------------------------------------------------------------------- manifest --

function Read-HeresayJsonFile {
    param([Parameter(Mandatory)][string] $Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "'$Path' is empty." }
    try { return $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "'$Path' is not valid JSON: $($_.Exception.Message)" }
}

function Write-HeresayJsonFile {
    <#
        ConvertTo-Json escapes backslashes correctly, so Windows paths survive. The
        round-trip check is not paranoia: hand-built JSON containing C:\... paths is
        very easy to corrupt, and a broken install-manifest.json means an uninstall
        that cannot find what it is supposed to remove.
    #>
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)][string] $Path, [int] $Depth = 12)
    $json = $Object | ConvertTo-Json -Depth $Depth
    try { $null = $json | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Refusing to write '$Path': the JSON generated does not parse back ($($_.Exception.Message))." }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    # And confirm what actually landed on disk parses too.
    $null = Read-HeresayJsonFile -Path $Path
}

function Resolve-HeresayDownloadManifest {
    <#
        Normalise contracts/download-manifest.json into one shape:
          Name, Uri, FileName, SizeBytes, Sha256, ArchiveType, Target,
          StripComponents, SmokeExe, SmokeArgs, Optional
    #>
    param([Parameter(Mandatory)][string] $Path)

    $doc = Read-HeresayJsonFile -Path $Path
    $list = Get-HeresayFieldValue -Object $doc -Names @('components', 'downloads', 'files', 'items')
    if (-not $list) { throw "'$Path' has no components/downloads array." }

    $out = New-Object System.Collections.ArrayList
    foreach ($c in @($list)) {
        $uri  = Get-HeresayFieldValue -Object $c -Names @('url', 'uri', 'resolvedUrl', 'downloadUrl', 'href')
        $name = Get-HeresayFieldValue -Object $c -Names @('name', 'component', 'id') -Default 'unnamed'
        $file = Get-HeresayFieldValue -Object $c -Names @('filename', 'fileName', 'file', 'localName')
        if (-not $file -and $uri) {
            try { $file = Split-Path -Leaf ([uri]$uri).AbsolutePath } catch { $file = "$name.bin" }
        }
        $smoke = Get-HeresayFieldValue -Object $c -Names @('smokeTest', 'smoke', 'verify')
        $optionalValue = Get-HeresayFieldValue -Object $c -Names @('optional') -Default $null
        if ($null -eq $optionalValue) {
            $requiredValue = Get-HeresayFieldValue -Object $c -Names @('required') -Default $true
            $optionalValue = -not [bool]$requiredValue
        }
        [void]$out.Add([pscustomobject]@{
            Name            = [string]$name
            Uri             = [string]$uri
            FileName        = [string]$file
            SizeBytes       = [long](Get-HeresayFieldValue -Object $c -Names @('sizeBytes', 'size', 'bytes', 'length') -Default 0)
            Sha256          = [string](Get-HeresayFieldValue -Object $c -Names @('sha256', 'sha256sum', 'hash', 'checksum') -Default '')
            ArchiveType     = [string](Get-HeresayFieldValue -Object $c -Names @('archiveType', 'type', 'format', 'kind') -Default '')
            Target          = [string](Get-HeresayFieldValue -Object $c -Names @('target', 'extractTo', 'destination', 'dest', 'installTo') -Default '')
            StripComponents = [int](Get-HeresayFieldValue -Object $c -Names @('stripComponents', 'strip') -Default 0)
            SmokeExe        = [string](Get-HeresayFieldValue -Object $smoke -Names @('exe', 'path', 'command') -Default '')
            SmokeArgs       = @(Get-HeresayFieldValue -Object $smoke -Names @('args', 'arguments') -Default @())
            Optional        = [bool]$optionalValue
            # An install-time INPUT rather than a shipped artefact: downloaded, verified,
            # consumed by a derivation step, then deleted. The f16 weights the default
            # speech model is quantised from are the only current example.
            InstallTimeOnly = [bool](Get-HeresayFieldValue -Object $c -Names @('installTimeOnly', 'installTimeSourceOnly', 'consumeAtInstall') -Default $false)
            # The manifest maps individual archive members to exact destinations
            # instead of naming one target directory. Carry it through verbatim.
            Extract         = @(Get-HeresayFieldValue -Object $c -Names @('extract', 'extractMap', 'map') -Default @())
        })
    }
    return $out.ToArray()
}

function Install-HeresayComponentFiles {
    <#
        Applies the per-file `extract` mapping from contracts/download-manifest.json.
        Each entry is either:
            { from, to }         a single member  -> an exact destination path
            { fromGlob, toDir }  a wildcard match -> a destination directory
        Paths in the manifest use forward slashes and are relative to the install root.

        When archiveType is 'none' the downloaded file IS the payload (e.g. a .bin model),
        so there is nothing to unpack and `from` simply names that file.

        Returns the absolute paths actually written.
    #>
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $InstallRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()] $Extract,
        [string] $ArchiveType = ''
    )

    $sep       = [string][System.IO.Path]::DirectorySeparatorChar
    $written   = New-Object System.Collections.ArrayList
    $isArchive = $ArchiveType -and $ArchiveType -ne 'none'
    $staging   = $null

    try {
        if ($isArchive) {
            $staging = Join-Path ([System.IO.Path]::GetTempPath()) ('ti-x-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
            New-Item -ItemType Directory -Force -Path $staging | Out-Null
            Expand-HeresayArchive -ArchivePath $SourcePath -Destination $staging -ArchiveType $ArchiveType
        }

        foreach ($e in @($Extract)) {
            $from  = Get-HeresayFieldValue -Object $e -Names @('from', 'source', 'src')
            $glob  = Get-HeresayFieldValue -Object $e -Names @('fromGlob', 'glob', 'pattern')
            $to    = Get-HeresayFieldValue -Object $e -Names @('to', 'dest', 'destination')
            $toDir = Get-HeresayFieldValue -Object $e -Names @('toDir', 'destDir', 'directory')

            if ($glob) {
                if (-not $toDir) { throw "extract entry has fromGlob '$glob' but no toDir" }
                $destDir = Join-Path $InstallRoot ($toDir.Replace('/', $sep))
                New-Item -ItemType Directory -Force -Path $destDir | Out-Null
                $pattern = $glob.Replace('/', $sep)
                $leaf    = Split-Path -Leaf $pattern
                $hits = if ($isArchive) {
                    @(Get-ChildItem -LiteralPath $staging -Recurse -File | Where-Object {
                        $rel = $_.FullName.Substring($staging.Length).TrimStart($sep)
                        ($rel -like $pattern) -or ($_.Name -like $leaf)
                    })
                } else { @(Get-Item -LiteralPath $SourcePath) }
                if (-not $hits.Count) { throw "no archive member matched '$glob'" }
                foreach ($h in $hits) {
                    $dst = Join-Path $destDir $h.Name
                    Copy-Item -LiteralPath $h.FullName -Destination $dst -Force
                    [void]$written.Add($dst)
                }
                continue
            }

            if (-not $from -or -not $to) { throw 'extract entry needs from+to or fromGlob+toDir' }
            $dst    = Join-Path $InstallRoot ($to.Replace('/', $sep))
            $dstDir = Split-Path -Parent $dst
            if ($dstDir) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }

            if ($isArchive) {
                $rel     = $from.Replace('/', $sep)
                $srcFile = Join-Path $staging $rel
                if (-not (Test-Path -LiteralPath $srcFile)) {
                    # Tolerate archives that wrap everything in an extra top-level folder.
                    $cand = @(Get-ChildItem -LiteralPath $staging -Recurse -File -Filter (Split-Path -Leaf $rel))
                    if ($cand.Count -eq 1) { $srcFile = $cand[0].FullName }
                    else { throw "archive member '$from' not found in $(Split-Path -Leaf $SourcePath)" }
                }
                Copy-Item -LiteralPath $srcFile -Destination $dst -Force
            }
            else {
                Copy-Item -LiteralPath $SourcePath -Destination $dst -Force
            }
            [void]$written.Add($dst)
        }
    }
    finally {
        if ($staging -and (Test-Path -LiteralPath $staging)) {
            Get-Item -LiteralPath $staging | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $written.ToArray()
}

# -------------------------------------------------------------- derived models --
#
# One component is not downloaded at all: the DEFAULT speech model,
# ggml-large-v3-turbo-q4_0.bin. It does not exist upstream - there is no q4_0 anywhere in
# huggingface.co/ggerganov/whisper.cpp - so the installer produces it here by quantising
# the published f16 weights with whisper-quantize.exe, which ships inside the same
# SHA-256-verified whisper.cpp archive as whisper-cli.exe.
#
# The alternative was what this replaces: a 452 MiB model that existed only because
# someone once ran an unvendored tool on one laptop, appeared in no manifest, and would
# have made a clean install on any other machine produce a tool that could not start.

function Resolve-HeresayDerivedModels {
    <#
        Normalise the derivedComponents array of the download manifest, the same way
        Resolve-HeresayDownloadManifest normalises components. Returns an empty array when the
        manifest has no such section, so an older manifest still installs.

        Shape: Name, Target, SizeBytes, Sha256, SourceComponent, SourcePath, Tool,
               QuantType, DeleteSourceAfter, Optional
    #>
    param([Parameter(Mandatory)][string] $Path)

    $doc  = Read-HeresayJsonFile -Path $Path
    $list = Get-HeresayFieldValue -Object $doc -Names @('derivedComponents', 'derived', 'derivedModels')
    # Guard before @(): @($null) is a one-element array holding $null, which would
    # otherwise be normalised into a bogus 'unnamed' derivation.
    if (-not $list) { return @() }

    $out = New-Object System.Collections.ArrayList
    foreach ($d in @($list)) {
        if ($null -eq $d) { continue }
        [void]$out.Add([pscustomobject]@{
            Name              = [string](Get-HeresayFieldValue -Object $d -Names @('name', 'component', 'id') -Default 'unnamed')
            Target            = [string](Get-HeresayFieldValue -Object $d -Names @('target', 'to', 'destination') -Default '')
            SizeBytes         = [long](Get-HeresayFieldValue -Object $d -Names @('sizeBytes', 'size', 'bytes') -Default 0)
            Sha256            = [string](Get-HeresayFieldValue -Object $d -Names @('sha256', 'hash', 'checksum') -Default '')
            SourceComponent   = [string](Get-HeresayFieldValue -Object $d -Names @('derivedFrom', 'sourceComponent', 'fromComponent') -Default '')
            SourcePath        = [string](Get-HeresayFieldValue -Object $d -Names @('sourcePath', 'from', 'source') -Default '')
            Tool              = [string](Get-HeresayFieldValue -Object $d -Names @('tool', 'exe', 'command') -Default '')
            QuantType         = [string](Get-HeresayFieldValue -Object $d -Names @('quantType', 'quant', 'type') -Default '')
            DeleteSourceAfter = [bool](Get-HeresayFieldValue -Object $d -Names @('deleteSourceAfter', 'deleteSource') -Default $false)
            Optional          = [bool](Get-HeresayFieldValue -Object $d -Names @('optional') -Default $false)
        })
    }
    return $out.ToArray()
}

function Get-HeresayRecordedDerivedHash {
    <# The SHA-256 a PREVIOUS install of this machine recorded for a derived model. #>
    param([AllowNull()] $Manifest, [string] $Name = '', [string] $Path = '')
    if ($null -eq $Manifest) { return '' }
    if ($Manifest.PSObject.Properties.Name -notcontains 'derivedModels') { return '' }
    foreach ($d in @($Manifest.derivedModels)) {
        if ($null -eq $d) { continue }
        $n = [string](Get-HeresayFieldValue -Object $d -Names @('name') -Default '')
        $p = [string](Get-HeresayFieldValue -Object $d -Names @('path') -Default '')
        $hit = ($Name -and $n -and $n -eq $Name) -or ($Path -and $p -and $p.ToLowerInvariant() -eq $Path.ToLowerInvariant())
        if ($hit) { return ([string](Get-HeresayFieldValue -Object $d -Names @('sha256') -Default '')).ToLowerInvariant() }
    }
    return ''
}

function Get-HeresayDerivedModelState {
    <#
    .SYNOPSIS
        Is the derived model already on disk and trustworthy? Decides both whether to
        re-derive it and whether its 1.55 GiB source needs downloading at all.

    .DESCRIPTION
        Size is checked first and is non-negotiable: a quantised model's size is fixed by
        the tensor shapes and the quant type, so it cannot legitimately vary.

        Then SHA-256, which is accepted against EITHER of two references:

          1. the hash pinned in the download manifest;
          2. the hash the previous install of THIS machine recorded for it.

        (2) is not laziness. whisper-quantize loads whichever ggml-cpu-*.dll matches the
        host CPU, so bit-identical output on a different microarchitecture is likely but
        not guaranteed. On a machine whose output legitimately differs from the reference,
        proof (1) can never succeed - and without (2) every single re-run would re-download
        1.55 GiB and re-quantise. A check that fails on every install is worse than none.
    #>
    param(
        [Parameter(Mandatory)] $Spec,
        [Parameter(Mandatory)][string] $InstallRoot,
        [AllowNull()] $PreviousManifest
    )

    $out = Join-Path $InstallRoot ($Spec.Target -replace '/', '\')
    $r = [ordered]@{
        Path = $out; Present = $false; SizeBytes = 0L; Sha256 = ''
        MatchesPinned = $false; MatchesPrevious = $false; Ok = $false
        Reason = 'not present yet'
    }

    if (-not (Test-Path -LiteralPath $out -PathType Leaf)) { return [pscustomobject]$r }
    $r.Present   = $true
    $r.SizeBytes = (Get-Item -LiteralPath $out).Length

    if ($Spec.SizeBytes -gt 0 -and $r.SizeBytes -ne $Spec.SizeBytes) {
        $r.Reason = "it is $($r.SizeBytes) bytes and the manifest pins $($Spec.SizeBytes)"
        return [pscustomobject]$r
    }

    $r.Sha256 = Get-HeresayFileHash256 -Path $out
    if ($Spec.Sha256 -and $r.Sha256 -eq $Spec.Sha256.ToLowerInvariant()) {
        $r.MatchesPinned = $true
        $r.Ok = $true
        $r.Reason = 'SHA-256 matches the hash pinned in the download manifest'
        return [pscustomobject]$r
    }

    $prev = Get-HeresayRecordedDerivedHash -Manifest $PreviousManifest -Name $Spec.Name -Path $out
    if ($prev -and $r.Sha256 -eq $prev) {
        $r.MatchesPrevious = $true
        $r.Ok = $true
        $r.Reason = 'SHA-256 matches what the previous install on this machine recorded, though not the pinned hash'
        return [pscustomobject]$r
    }

    $r.Reason = 'its SHA-256 matches neither the pinned hash nor any hash a previous install recorded'
    return [pscustomobject]$r
}

function Invoke-HeresayQuantizeModel {
    <#
    .SYNOPSIS
        Run whisper-quantize.exe to derive a quantised model from f16 weights.

    .DESCRIPTION
        Usage is positional and undocumented outside the tool's own error text:
            whisper-quantize.exe <model-f16.bin> <model-quant.bin> <type>
        where type is a name ('q4_0') or a ggml ftype number.

        MEASURED, and the trap worth knowing about: whisper-quantize.exe resolves
        whisper.dll and the ggml*.dll set from its OWN directory. Run from anywhere those
        are not present it exits 53 having printed absolutely nothing - which looks
        identical to a tool that ran and quietly did nothing. So WorkingDirectory is
        pinned to the exe's folder and success is judged on the exit code AND the output
        file existing, never on output text.
    #>
    param(
        [Parameter(Mandatory)][string] $ExePath,
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $OutPath,
        [Parameter(Mandatory)][string] $QuantType,
        [int] $TimeoutSeconds = 1800
    )

    $r = [ordered]@{ Ok = $false; ExitCode = $null; Seconds = 0.0; Output = ''; Error = '' }

    foreach ($need in @(@{ N = 'quantiser'; P = $ExePath }, @{ N = 'f16 source model'; P = $SourcePath })) {
        if (-not (Test-Path -LiteralPath $need.P -PathType Leaf)) {
            $r.Error = "$($need.N) not found: $($need.P)"
            return [pscustomobject]$r
        }
    }

    $outDir = Split-Path -Parent $OutPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    # A leftover partial output from an interrupted run would pass a later existence check.
    if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $ExePath
        # ArgumentList, not a joined string: model paths live under a profile path that
        # can contain spaces.
        foreach ($a in @($SourcePath, $OutPath, $QuantType)) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.WorkingDirectory       = (Split-Path -Parent $ExePath)

        $p  = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill($true) } catch { }
            $sw.Stop()
            $r.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            $r.Error = "whisper-quantize did not finish within $TimeoutSeconds s and was killed"
            return [pscustomobject]$r
        }
        $r.ExitCode = $p.ExitCode
        $r.Output   = (($so.GetAwaiter().GetResult()) + "`n" + ($se.GetAwaiter().GetResult())).Trim()
        $r.Ok       = ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $OutPath -PathType Leaf))
        if (-not $r.Ok) {
            $r.Error = if ($p.ExitCode -ne 0) { "whisper-quantize exited $($p.ExitCode)" }
                       else { 'whisper-quantize exited 0 but produced no output file' }
        }
    }
    catch { $r.Error = $_.Exception.Message }

    $sw.Stop()
    $r.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    return [pscustomobject]$r
}

function New-HeresaySendToShortcuts {
    <# Remove shortcuts created by versions that used the Windows Send To menu.
       The function name and switches remain for installer command compatibility. #>
    param(
        [Parameter(Mandatory)][string] $InstallRoot,
        [switch] $Remove,
        [switch] $ListOnly
    )

    $sendTo = [Environment]::GetFolderPath('SendTo')
    $entries = @()

    # Names this function USED to install. Retired entries must be swept by their old
    # names, or they survive every future install AND uninstall as dead menu items:
    # both the create path and -Remove iterate the CURRENT $entries, which is now
    # empty. 'Heresay - Transcribe in PDF' joins the list because it too is now retired
    # - existing installs carry it and must have it removed on the next run.
    $legacyNames = @(
        'Heresay - Transcribe in PDF'
        'Transcribe in PDF'
        'Heresay - Generate transcript (PDF)'
        'Heresay - Fast transcript (lower accuracy)'
        'Heresay - Solo recording (no speakers)'
        'Heresay - Fastest transcript (no speakers)'
        'Heresay - Compress for Word'
        'Heresay - Save as PDF'
    )

    # Answer the preview from the same array that does the work, before anything is
    # created or removed. -ListOnly reports only the CURRENT entries: that is what the
    # -WhatIf preview shows and what the install manifest will record; the legacy
    # sweep below is cleanup, not an install effect worth advertising as one.
    if ($ListOnly) { return @($entries | ForEach-Object { $_.Name }) }

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($legacy in $legacyNames) {
        $lnk = Join-Path $sendTo ($legacy + '.lnk')
        if (Test-Path -LiteralPath $lnk) {
            try { Remove-Item -LiteralPath $lnk -Force -ErrorAction Stop } catch { }
        }
    }

    return $paths.ToArray()
}

# ------------------------------------------------------------------ smoke tests --


function Invoke-HeresaySmokeTest {
    <# Launch an executable and see whether it actually runs on this machine. Many of
       these tools return a non-zero exit code for --help, so producing output is the
       real signal, not the exit code. #>
    param(
        [Parameter(Mandatory)][string] $ExePath,
        [string[]] $Arguments = @(),
        [int] $TimeoutMs = 30000
    )

    $r = [ordered]@{ Exe = $ExePath; Ok = $false; ExitCode = $null; FirstLine = ''; Error = '' }
    if (-not (Test-Path -LiteralPath $ExePath)) { $r.Error = 'not found'; return [pscustomobject]$r }

    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $ExePath
        foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = (Split-Path -Parent $ExePath)

        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill($true) } catch { }
            $r.Error = "did not exit within $([int]($TimeoutMs/1000))s"
            return [pscustomobject]$r
        }
        $r.ExitCode = $p.ExitCode
        $text = (($so.GetAwaiter().GetResult()) + "`n" + ($se.GetAwaiter().GetResult())).Trim()
        $r.FirstLine = @($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -join ''
        # Launching at all is the point: it proves no missing DLL and no policy block.
        $r.Ok = ($r.FirstLine.Length -gt 0 -or $p.ExitCode -eq 0)
    }
    catch { $r.Error = $_.Exception.Message }

    return [pscustomobject]$r
}

# ------------------------------------------------------------------- preflight --

function Get-HeresayDotnetRuntimes {
    <# Read the shared-framework folders directly. `dotnet --list-runtimes` needs dotnet
       on PATH, which is not guaranteed even when the runtime is installed. #>
    $found = New-Object System.Collections.ArrayList
    $roots = @(
        (Join-Path $env:ProgramFiles 'dotnet\shared'),
        (Join-Path ${env:ProgramFiles(x86)} 'dotnet\shared'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\shared')
    )
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($fw in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
            foreach ($v in Get-ChildItem -LiteralPath $fw.FullName -Directory -ErrorAction SilentlyContinue) {
                [void]$found.Add([pscustomobject]@{ Framework = $fw.Name; Version = $v.Name; Path = $v.FullName })
            }
        }
    }
    return $found.ToArray()
}

function Find-HeresayEdge {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    try {
        $k = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
        if (Test-Path -LiteralPath $k) {
            $p = (Get-ItemProperty -LiteralPath $k).'(default)'
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        }
    }
    catch { }
    return $null
}

function Find-HeresayPwsh {
    $candidates = @(
        (Join-Path $PSHOME 'pwsh.exe'),
        'C:\Program Files\PowerShell\7\pwsh.exe',
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        # Portable per-user copy installed when Program Files pwsh is absent.
        (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell7\pwsh.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $cmd = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-HeresayDirectoryWritable {
    <#
        Deliberately all .NET and no cmdlets.

        Remove-Item and New-Item inherit the CALLER's $WhatIfPreference; the .NET write in
        the middle does not. So under -WhatIf this function used to create the probe file
        for real and then have its deletion suppressed, leaving a .ti-write-probe-<guid>
        file in %LOCALAPPDATA%\Programs\ after every single dry run - four of them had
        accumulated by 2026-08-27 - which made the installer's closing "Nothing was
        changed." untrue. The New-Item had the mirror-image fault: suppressed under -WhatIf,
        so the WriteAllText that followed threw and a perfectly writable location was
        reported as a preflight FAILURE.

        Both halves being .NET makes the probe symmetric: it always really happens, and it
        always really cleans up after itself.
    #>
    param([Parameter(Mandatory)][string] $Path)
    $createdDir = $false
    try {
        if (-not [System.IO.Directory]::Exists($Path)) {
            [void][System.IO.Directory]::CreateDirectory($Path)
            $createdDir = $true
        }
        $probe = Join-Path $Path (".ti-write-probe-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.File]::WriteAllText($probe, 'probe')
        [System.IO.File]::Delete($probe)
        return $true
    }
    catch { return $false }
    finally {
        # Put back a directory that only existed to be probed. Non-recursive on purpose:
        # if anything else is in there it is not ours and Delete throws, which is right.
        if ($createdDir) { try { [System.IO.Directory]::Delete($Path) } catch { } }
    }
}

function Test-HeresayRegistryWritable {
    <# -WhatIf:$false on both halves for the same reason as Test-HeresayDirectoryWritable: a
       suppressed New-Item would make this return $true having tested nothing at all. #>
    param([string] $KeyPath = 'HKCU:\Software\Classes')
    try {
        $probe = "$KeyPath\HeresayWriteProbe"
        New-Item -Path $probe -Force -WhatIf:$false -Confirm:$false | Out-Null
        Remove-Item -LiteralPath $probe -Force -Recurse -WhatIf:$false -Confirm:$false
        return $true
    }
    catch { return $false }
}

# ------------------------------------------------------- install-manifest model --

function New-HeresayInstallManifest {
    param([Parameter(Mandatory)][string] $InstallRoot, [string] $Version = '1.0.0')
    return [ordered]@{
        product          = $script:HERESAY_ProductName
        manifestVersion  = $script:HERESAY_ManifestVersion
        version          = $Version
        installRoot      = $InstallRoot
        installedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        installedBy      = "$env:USERDOMAIN\$env:USERNAME"
        machine          = $env:COMPUTERNAME
        scope            = 'user'
        directories      = @()
        files            = @()
        registryKeys     = @()   # ancestor keys this install created (prune-safe removal)
        verbKeys         = @()   # every verb key we own, pre-existing or not
        registryValues   = @()
        components       = @()
        # Models the installer PRODUCED rather than downloaded, with the measured hash of
        # what it actually produced. Declared here rather than added on the fly so it is
        # always present in the same position, and so Get-HeresayRecordedDerivedHash can rely
        # on finding it when reading back a previous install's manifest.
        derivedModels    = @()
        smokeTests       = @()
        notes            = @()
    }
}

function Add-HeresayManifestFile {
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)][string] $Path,
        [string] $Component = '',
        [switch] $NoHash,
        [switch] $ForceHash,
        [switch] $Mutable
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $fi = Get-Item -LiteralPath $Path
    $entry = [ordered]@{
        path      = $fi.FullName
        sizeBytes = $fi.Length
        component = $Component
    }
    # Hashing hundreds of MB of downloaded model files would add install time for little
    # benefit: their integrity is already established by the pinned-hash check on the
    # source archive at download time. So hash the small scripts, where a silent edit
    # actually matters.
    #
    # -ForceHash exists because the size heuristic is BACKWARDS for exactly one file: the
    # locally DERIVED model. Every other large file came from a publisher and has an
    # upstream hash to compare against; the derived one is produced on this machine, so
    # install-manifest.json is the only record of what the derivation actually emitted.
    # That is the file most worth hashing, and the only one the size rule excludes.
    #
    # -Mutable is the opposite case, and a stronger statement than -NoHash. -NoHash says
    # "hashing this is not worth the time"; -Mutable says "this file is SUPPOSED to change
    # after install, so a recorded hash would not merely cost time, it would guarantee a
    # false positive". app\config.json is the case: the installer generates it and the user
    # then tunes it - queue.rewriteItemFields and performance.realTimeFactor are both
    # documented user knobs - so any integrity check that hashes it reports tampering the
    # first time a seed is adjusted. It drifted on this machine within two hours of install
    # for precisely that reason.
    #
    # Recorded as a flag rather than merely left unhashed, so a checker can tell "no hash
    # because it is big" from "no hash because it is meant to move". Only the second is
    # safe to pass over silently. -Mutable wins over -ForceHash: a file that is expected to
    # change cannot also be pinned, and being asked for both is a caller bug, so it throws
    # rather than quietly picking one.
    if ($Mutable -and $ForceHash) {
        throw "Add-HeresayManifestFile: -Mutable and -ForceHash are contradictory for '$Path'. A file cannot be both expected to change and pinned to a hash."
    }
    if ($Mutable) { $entry['mutable'] = $true }
    elseif ($ForceHash -or (-not $NoHash -and $fi.Length -le 2MB)) {
        $entry['sha256'] = Get-HeresayFileHash256 -Path $fi.FullName
    }
    $Manifest.files = @($Manifest.files) + @([pscustomobject]$entry)
}

function Repair-HeresayConfigPaths {
    <#
    .SYNOPSIS
        Make config.json's tool paths agree with where the installer actually put things.

    .DESCRIPTION
        The source app\config.default.json may point at the development layout:

            "ffmpeg":     "vendor/ffmpeg/ffmpeg.exe"
            "whisperCli": "vendor/whisper/whisper-cli.exe"
            "diarizer":   "vendor/sherpa/sherpa-onnx-offline-speaker-diarization.exe"
            "modelDir":   "vendor/models"

        The agreed INSTALL layout is bin\{ffmpeg,whisper,sherpa}\ and models\. Copied
        verbatim, those relative paths resolve to nothing under the install root and the
        engine fails at run time with "ffprobe not found" - after an install that looked
        completely successful.

        The installer is the component that decides where files go, so reconciling this is
        its job. Transcribe.ps1's Resolve-Vendor returns rooted paths unchanged, so
        writing absolute paths here is honoured directly.

        An existing value wins if it resolves. Only unresolvable entries are
        remapped, and every remap is logged. app\config.default.json is never modified.
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)][string] $InstallRoot
    )

    $report = [ordered]@{ Remapped = @(); Unresolved = @(); Kept = @() }
    if ($Config.PSObject.Properties.Name -notcontains 'paths') { return [pscustomobject]$report }

    # Logical name -> where to look under the install root, most specific first.
    $search = [ordered]@{
        ffmpeg     = @{ Dirs = @('bin\ffmpeg'); Patterns = @('ffmpeg.exe') }
        ffprobe    = @{ Dirs = @('bin\ffmpeg'); Patterns = @('ffprobe.exe') }
        whisperCli = @{ Dirs = @('bin\whisper'); Patterns = @('whisper-cli.exe', 'whisper.exe', 'main.exe', 'whisper*.exe') }
        diarizer   = @{ Dirs = @('bin\sherpa'); Patterns = @('sherpa-onnx-offline-speaker-diarization.exe', 'sherpa-onnx*diariz*.exe', 'sherpa-onnx*.exe') }
        modelDir   = @{ Dirs = @('.');          Patterns = @('models'); Directory = $true }
        renderer   = @{ Dirs = @('.');          Patterns = @('app\Render-Pdf.ps1') }
        merger     = @{ Dirs = @('.');          Patterns = @('app\Merge-Diarization.ps1') }
    }

    $remapped = New-Object System.Collections.ArrayList
    $unresolved = New-Object System.Collections.ArrayList
    $kept = New-Object System.Collections.ArrayList

    foreach ($name in @($Config.paths.PSObject.Properties.Name)) {
        $value = [string]$Config.paths.$name
        if (-not $value) { continue }

        # Already absolute, or already resolves the way the engine will resolve it.
        if ([System.IO.Path]::IsPathRooted($value)) { [void]$kept.Add($name); continue }
        $asIs = Join-Path $InstallRoot ($value -replace '/', '\')
        $asApp = Join-Path (Join-Path $InstallRoot 'app') ($value -replace '/', '\')
        if ((Test-Path -LiteralPath $asIs) -or (Test-Path -LiteralPath $asApp)) { [void]$kept.Add($name); continue }

        if ($search.Contains($name)) {
            $spec = $search[$name]
            $hit = $null
            foreach ($d in $spec.Dirs) {
                $base = if ($d -eq '.') { $InstallRoot } else { Join-Path $InstallRoot $d }
                if (-not (Test-Path -LiteralPath $base)) { continue }
                foreach ($pat in $spec.Patterns) {
                    if ($pat -match '[\\/]') {
                        $direct = Join-Path $base $pat
                        if (Test-Path -LiteralPath $direct) { $hit = (Resolve-Path -LiteralPath $direct).ProviderPath; break }
                        continue
                    }
                    $isDir = ($spec.ContainsKey('Directory') -and $spec.Directory)
                    $found = @(Get-ChildItem -LiteralPath $base -Filter $pat -Recurse -Force -ErrorAction SilentlyContinue |
                               Where-Object { if ($isDir) { $_.PSIsContainer } else { -not $_.PSIsContainer } } |
                               Sort-Object { $_.FullName.Length }) | Select-Object -First 1
                    if ($found) { $hit = $found.FullName; break }
                }
                if ($hit) { break }
            }

            if ($hit) {
                $Config.paths.$name = $hit
                [void]$remapped.Add([pscustomobject]@{ name = $name; from = $value; to = $hit })
                continue
            }
        }
        [void]$unresolved.Add([pscustomobject]@{ name = $name; value = $value })
    }

    $report.Remapped   = $remapped.ToArray()
    $report.Unresolved = $unresolved.ToArray()
    $report.Kept       = $kept.ToArray()
    return [pscustomobject]$report
}

function Get-HeresayInstallManifestPath {
    param([Parameter(Mandatory)][string] $InstallRoot)
    return (Join-Path $InstallRoot 'install-manifest.json')
}

# ----------------------------------------------------------- single-file deploy --

function Update-HeresayInstalledAppFile {
    <#
    .SYNOPSIS
        Deploy ONE app file into an existing install and update its manifest entry in the
        same operation.

    .DESCRIPTION
        The gap this closes: nothing but a full Install-Heresay.ps1 run ever wrote
        install-manifest.json, so iterating on a single script meant hand-copying it into
        the live install. Five entries drifted that way in one session - app\Transcribe.ps1,
        Render-Pdf.ps1, Transcribe-Entry.ps1, Register-ShellVerbs.ps1 and config.json.
        Regenerating the manifest afterwards is not a fix: it
        records whatever is on disk as authoritative, which destroys the one property the
        manifest exists to provide.

        THE COPY AND THE RECORD ARE ONE OPERATION. If the manifest cannot be read, this
        refuses to copy at all rather than deploy a file it cannot record. Four things went
        unrecorded on this project - two speech models, two app scripts and a Send To
        shortcut - and every one was brought into existence by a path that was not also the
        path that records it. Same rule as New-HeresaySendToShortcuts, applied to app\ instead
        of the Send To folder.

        It VERIFIES rather than assumes. The destination is re-hashed after the copy and
        compared to the source, because an installer run has already been observed logging
        "10 app file(s) copied" while two of those files did not change: $SourceRoot
        defaults to Split-Path -Parent $PSScriptRoot, so a run launched from the wrong tree
        installs stale files and reports success. An unconditional Copy-Item cannot tell
        you that; a post-copy hash comparison can.

        Idempotent, and safe in any order. If the destination already matches the source no
        copy happens and only the manifest entry is refreshed. There is deliberately no
        multi-file transaction: the launcher discovers the progress UI's parameters by name
        at run time (Get-ScriptParameterNames in Start-ProgressUi), so Progress.ps1 and
        Transcribe-Entry.ps1 can be deployed independently in either order - old launcher
        with new UI, and new launcher with old UI, both degrade cleanly.

    .PARAMETER SourcePath
        The file in the source tree, e.g. C:\Users\...\Heresay\app\Progress.ps1.

    .PARAMETER InstallRoot
        An existing install root. The file lands in <InstallRoot>\app\<leaf>.

    .PARAMETER Force
        Required to overwrite an entry flagged `mutable`. app\config.json is generated by
        the installer and then tuned by the user, so deploying over it discards that tuning.

    .EXAMPLE
        Update-HeresayInstalledAppFile -SourcePath C:\path\to\repo\app\Progress.ps1 -InstallRoot "$env:LOCALAPPDATA\Programs\Heresay"

    .EXAMPLE
        # Preview without touching anything.
        Update-HeresayInstalledAppFile -SourcePath ...\app\Progress.ps1 -InstallRoot ... -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $InstallRoot,
        [string] $Component = 'app',
        [string] $ManifestPath,
        [switch] $Force
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Source file not found: '$SourcePath'."
    }
    $src    = Get-Item -LiteralPath $SourcePath
    $dstDir = Join-Path $InstallRoot 'app'
    if (-not (Test-Path -LiteralPath $dstDir -PathType Container)) {
        throw "No app directory under '$InstallRoot'. Is that actually an install root?"
    }
    $dst = Join-Path $dstDir $src.Name

    if (-not $ManifestPath) { $ManifestPath = Get-HeresayInstallManifestPath -InstallRoot $InstallRoot }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "No install-manifest.json at '$ManifestPath'. Refusing to deploy a file that cannot be recorded."
    }
    # Read-HeresayJsonFile throws on malformed JSON, which is the behaviour wanted here: a
    # manifest that cannot be parsed is a manifest that cannot be updated, and deploying
    # anyway is the exact bug this function exists to prevent.
    $manifest = Read-HeresayJsonFile -Path $ManifestPath
    if ($manifest.PSObject.Properties.Name -notcontains 'files') {
        throw "'$ManifestPath' has no files[] array; refusing to deploy against it."
    }

    $files    = @($manifest.files)
    $existing = $files |
                Where-Object { $_.PSObject.Properties.Name -contains 'path' -and $_.path -and
                               ([string]$_.path).Equals($dst, [System.StringComparison]::OrdinalIgnoreCase) } |
                Select-Object -First 1
    $isMutable = $null -ne $existing -and
                 ($existing.PSObject.Properties.Name -contains 'mutable') -and
                 [bool]$existing.mutable

    if ($isMutable -and -not $Force) {
        Write-HeresayWarn ("app\{0} is flagged mutable in the manifest (installer-generated, then user-tuned); not overwriting. Pass -Force if that is genuinely intended." -f $src.Name)
        return [pscustomobject]@{
            Name = $src.Name; Action = 'skipped-mutable'; Path = $dst
            SizeBytes = $null; Sha256 = ''; ManifestUpdated = $false
        }
    }

    $srcHash   = Get-HeresayFileHash256 -Path $src.FullName
    $alreadyOk = (Test-Path -LiteralPath $dst -PathType Leaf) -and
                 ((Get-HeresayFileHash256 -Path $dst) -eq $srcHash)

    $what = if ($alreadyOk) { "Record app\{0} (already matches source)" } else { "Deploy app\{0} and record it" }
    if (-not $PSCmdlet.ShouldProcess($dst, ($what -f $src.Name))) {
        return [pscustomobject]@{
            Name = $src.Name; Action = 'whatif'; Path = $dst
            SizeBytes = $src.Length; Sha256 = $srcHash; ManifestUpdated = $false
        }
    }

    if (-not $alreadyOk) {
        Copy-Item -LiteralPath $src.FullName -Destination $dst -Force
        # Verify what landed, not what was asked for. This is the whole point.
        $landed = Get-HeresayFileHash256 -Path $dst
        if ($landed -ne $srcHash) {
            throw ("Copied '{0}' to '{1}' but the destination hashes differently ({2} vs {3}). Nothing recorded." -f $src.FullName, $dst, $landed, $srcHash)
        }
        Write-HeresayOk ("deployed app\{0} ({1})" -f $src.Name, (Format-HeresayBytes $src.Length))
    }
    else {
        Write-HeresayInfo ("app\{0} already matches the source; refreshing its manifest entry only." -f $src.Name)
    }

    $fi = Get-Item -LiteralPath $dst
    $entry = [ordered]@{
        path      = $fi.FullName
        sizeBytes = $fi.Length
        component = if ($null -ne $existing -and
                        ($existing.PSObject.Properties.Name -contains 'component') -and
                        $existing.component) { [string]$existing.component } else { $Component }
    }
    if ($isMutable) { $entry['mutable'] = $true }
    elseif ($fi.Length -le 2MB) { $entry['sha256'] = Get-HeresayFileHash256 -Path $fi.FullName }
    # Marks entries written by a single-file deploy rather than by a full install run.
    # Without it, "the manifest is clean" and "the install is current" are indistinguishable
    # from the manifest alone - which is how a two-file-stale install passed an audit with
    # zero drift reported.
    $entry['updatedUtc'] = (Get-Date).ToUniversalTime().ToString('o')

    # Replace in place so files[] ordering survives; append only if it was never recorded.
    $rebuilt  = New-Object System.Collections.Generic.List[object]
    $replaced = $false
    foreach ($f in $files) {
        if ($f.PSObject.Properties.Name -contains 'path' -and $f.path -and
            ([string]$f.path).Equals($dst, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$rebuilt.Add([pscustomobject]$entry)
            $replaced = $true
        }
        else { [void]$rebuilt.Add($f) }
    }
    if (-not $replaced) {
        [void]$rebuilt.Add([pscustomobject]$entry)
        Write-HeresayInfo ("app\{0} was not in files[]; added it." -f $src.Name)
    }
    $manifest.files = $rebuilt.ToArray()

    # Temp-then-move. A truncated install-manifest.json is an uninstall that cannot find
    # what it is meant to remove. Write-HeresayJsonFile validates the JSON round-trip before and
    # after writing; the move makes the replacement atomic on the same volume.
    $tmp = "$ManifestPath.new"
    Write-HeresayJsonFile -Object $manifest -Path $tmp
    Move-Item -LiteralPath $tmp -Destination $ManifestPath -Force

    return [pscustomobject]@{
        Name            = $src.Name
        Action          = if ($alreadyOk) { 'already-current' } else { 'deployed' }
        Path            = $dst
        SizeBytes       = $fi.Length
        Sha256          = if ($entry.Contains('sha256')) { [string]$entry['sha256'] } else { '' }
        ManifestUpdated = $true
    }
}
