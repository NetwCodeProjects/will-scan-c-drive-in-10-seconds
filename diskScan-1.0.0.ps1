<#
============================
Two-stage disk scanner (PowerShell 7+)
Stage 1: Build top-level target list and save to diskScan-target.csv
Stage 2: Pooled recursive scan of each target; results saved to diskScan-results.txt

Defaults:
- ThrottleLimit 4
- TargetFile: C:\diskScan-target.csv
- OutFileResults: C:\diskScan-results.txt

Supports multiple mixed roots

Usage:
pwsh .\diskScan.ps1 -Roots 'C:\','D:\','C:\Users\jamesbond\Downloads' -EchoToConsole
============================
#>

param(
    [string[]]$Roots              = @('C:\'),        # accepts C:\, C:/, \\Server\Share, or any folder
    [int]$ThrottleLimit           = 4,
    [string]$BaseDir              = 'C:\IT\diskScan',# default work area
    [string]$TargetFile,                              # derived from BaseDir if not provided
    [string]$OutDir,                                  # derived from BaseDir if not provided
    [string]$TempDir,                                 # derived from BaseDir if not provided
    [string[]]$IncludeExt         = @(),             # optional filter list, e.g. 'exe','dll'
    [switch]$EchoToConsole,
    [switch]$VerboseErrors
)

# --- Derive defaults from BaseDir if not explicitly supplied ---
if (-not $PSBoundParameters.ContainsKey('TargetFile')) { $TargetFile = Join-Path $BaseDir 'targets.csv' }
if (-not $PSBoundParameters.ContainsKey('OutDir'))     { $OutDir     = Join-Path $BaseDir 'results' }
if (-not $PSBoundParameters.ContainsKey('TempDir'))    { $TempDir    = Join-Path $BaseDir 'tmp'     }

# --- Normalize and validate Roots (supports C:\, C:/, \\Server\Share, any folder) ---
$Roots =
    $Roots |
    Where-Object { $_ -ne $null } |
    ForEach-Object { ($_ -replace '/', '\').Trim() } |
    Where-Object { $_ -ne '' }

if (-not $Roots -or $Roots.Count -eq 0) { throw "No valid -Roots provided." }

# Resolve existing paths to full names (keep non-existent for logging)
$ResolvedRoots = @()
foreach ($r in $Roots) {
    try {
        if (Test-Path -LiteralPath $r) { $ResolvedRoots += (Get-Item -LiteralPath $r).FullName }
        else                           { $ResolvedRoots += $r }
    } catch {                            $ResolvedRoots += $r }
}
$Roots = $ResolvedRoots

if (-not ($PSVersionTable.PSVersion.Major -ge 7)) {
    Write-Error "This script requires PowerShell 7+. Run with 'pwsh'."
    exit 1
}

# ------------- Helpers -------------
function Ensure-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}
function Reset-File([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $dir = Split-Path -Path $Path -Parent
    if ($dir) { Ensure-Dir $dir }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
}
# CSV-safe join (kept for reference; inlined in worker writes for speed)
function Format-CsvRow {
    param([string]$Root,[string]$Path,[UInt64]$SizeBytes)
    $q = { param($s) '"' + ($s -replace '"','""') + '"' }
    return (& $q $Root) + ',' + (& $q $Path) + ',' + $SizeBytes
}

function Compress-TempFilesToZip {
    param(
        [string[]]$TempFiles,              # line-oriented temp files (UTF-8)
        [string]  $HeaderLine,             # e.g., 'Root,Path,SizeBytes'
        [string]  $ZipPath,                # final .zip path
        [string]  $EntryName = 'data.csv'  # CSV name inside the ZIP
    )
    Reset-File $ZipPath

    $fsOut = [System.IO.File]::Create($ZipPath)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new(
            $fsOut, [System.IO.Compression.ZipArchiveMode]::Create, $false
        )
        try {
            $entry = $zip.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                $sw = [System.IO.StreamWriter]::new($entryStream, $utf8NoBom)
                $rows = 0
                try {
                    $sw.WriteLine($HeaderLine)
                    foreach ($tf in $TempFiles) {
                        if (-not (Test-Path -LiteralPath $tf)) { continue }
                        $sr = [System.IO.File]::OpenText($tf)
                        try {
                            while (($line = $sr.ReadLine()) -ne $null) {
                                if ($line.Length -gt 0) { $sw.WriteLine($line); $rows++ }
                            }
                        } finally { $sr.Close(); $sr.Dispose() }
                    }
                } finally { $sw.Flush(); $sw.Close(); $sw.Dispose() }
                return $rows
            } finally { $entryStream.Close() }
        } finally { $zip.Dispose() }
    } finally { $fsOut.Close(); $fsOut.Dispose() }
}

# Build a readable, safe tag for output filenames
function Get-RootTag([string]$RootPath) {
    if ($RootPath -like '\\*') {
        # \\Server\Share\optional\sub\path -> UNC_Server_Share_optional_sub_path
        $clean = ($RootPath.TrimEnd('\') -replace '^[\\]{2}', '') -replace '[:\\\/]', '_'
        $parts = $clean -split '_'
        if ($parts.Count -ge 2) {
            return 'UNC_' + ($parts -join '_')  # UNC_Server_Share_...
        } else {
            return 'UNC_' + $clean
        }
    } else {
        $tag = ($RootPath -replace '[:\\\/]','_').Trim('_')
        if (-not $tag) { $tag = 'root' }
        return $tag
    }
}

function Test-UncReachable([string]$Path) {
    # Non-UNC paths are considered reachable
    if ($Path -notlike '\\*') { return $true }

    # Extract \\Server
    if ($Path -match '^[\\]{2}([^\\]+)') {
        $server = $Matches[1]
        try {
            return Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue
        } catch {
            return $false
        }
    }
    return $true
}

# ------------- Prep -------------
# Per-run timestamp folder: YYYYMMDD_THHmmss
$RunStamp = Get-Date -Format "yyyyMMdd_'T'HHmmss"

# Ensure base dirs exist (C:\IT\diskScan\{results,tmp})
Ensure-Dir $BaseDir
Ensure-Dir $OutDir
Ensure-Dir $TempDir

# Per-run subfolders
$ResultsRunDir = Join-Path $OutDir  $RunStamp     # e.g., C:\IT\diskScan\results\20251023_T141623
$TempRunDir    = Join-Path $TempDir $RunStamp     # e.g., C:\IT\diskScan\tmp\20251023_T141623
Ensure-Dir $ResultsRunDir
Ensure-Dir $TempRunDir

# Stage 1 list goes into the per-run results folder with a simple name
if (-not $PSBoundParameters.ContainsKey('TargetFile')) {
    $TargetFile = Join-Path $ResultsRunDir 'targets.csv'
}

# Fresh Stage-1 file, optional error log (in per-run results)
Reset-File $TargetFile
$ErrorLog = Join-Path $ResultsRunDir 'errors.log'
if ($VerboseErrors) { Reset-File $ErrorLog }

# ----------------- Stage 1: Discover targets -----------------
$targetsByRoot = @{}
$allTargets = @()  # simple array for easy counting

foreach ($root in $Roots) {
    try {
        # Skip if UNC host isn’t reachable
        if (-not (Test-UncReachable $root)) {
            if ($VerboseErrors) { Add-Content $ErrorLog "Stage1: UNC host unreachable: $root" }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
            if ($VerboseErrors) { Add-Content $ErrorLog "Stage1: Root not found or blank: <$root>" }
            continue
        }

        $rootFull = (Get-Item -LiteralPath $root).FullName

        # include the root itself
        $list = @($rootFull)

        # first-level subdirectories, skip reparse points (filter as early as possible)
        $firstLevel = Get-ChildItem -LiteralPath $rootFull -Directory -Force -ErrorAction SilentlyContinue `
                      -Attributes !ReparsePoint |
                      Select-Object -ExpandProperty FullName

        if ($firstLevel) { $list += $firstLevel }

        # de-dupe and drop null/empty
        $unique = $list | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Sort-Object -Unique

        $targetsByRoot[$rootFull] = $unique
        $allTargets += $unique
    } catch {
        if ($VerboseErrors) { Add-Content $ErrorLog "Stage1: $root : $_" }
    }
}

# Write target CSV
Reset-File $TargetFile
"Path" | Out-File -FilePath $TargetFile -Encoding utf8
foreach ($p in ($allTargets | Sort-Object -Unique)) {
    ('"' + ($p -replace '"','""') + '"') | Add-Content -Path $TargetFile -Encoding utf8
}

$targetCount = ($allTargets | Measure-Object).Count
Write-Host "Stage 1 complete: $targetCount targets -> $TargetFile"

# ------------- Stage 2: Per-root pooled scan -> streamed ZIP -------------
# Cache UNC reachability per host across all workers (avoid repeated Test-Connection)
$UncHostCache = [System.Collections.Concurrent.ConcurrentDictionary[string,bool]]::new()

foreach ($rootKey in $targetsByRoot.Keys) {
    $rootTargets = $targetsByRoot[$rootKey]
    if (-not $rootTargets -or $rootTargets.Count -eq 0) { continue }

    # Generate a safe tag for filenames
    $rootTag = Get-RootTag $rootKey

    # Per-root temp folder for this run
    $rootTempDir = Join-Path $TempRunDir ("tmp_" + $rootTag)
    Ensure-Dir $rootTempDir

    # Build queue before starting workers (skip null/blank)
    $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    foreach ($t in $rootTargets) {
        if ($t -and $t.Trim().Length -gt 0) { $queue.Enqueue($t) }
    }

    # ---- Workers emit their temp file paths to the parent (no shared bag) ----
    $workerResults = 1..$ThrottleLimit | ForEach-Object -Parallel {
        # ---- capture $using: vars into locals ----
        $ProgressPreference = 'SilentlyContinue'  # reduce overhead in runspaces
        $queueLocal       = $using:queue
        $echo             = [bool]$using:EchoToConsole
        $rootKeyLocal     = $using:rootKey
        $rootTempDirLocal = $using:rootTempDir
        $includeExtList   = @($using:IncludeExt)
        $verboseFlag      = [bool]$using:VerboseErrors
        $errorLogPath     = $using:ErrorLog
        $uncCache         = $using:UncHostCache

        # ---- per-runspace setup ----
        $temp       = Join-Path $rootTempDirLocal ("scan_{0}.tmp" -f ([guid]::NewGuid()))
        $utf8NoBom  = [System.Text.UTF8Encoding]::new($false)
        $sw         = [System.IO.StreamWriter]::new($temp, $false, $utf8NoBom, 65536)  # 64KB buffer
        $localErr   = $null

        try {
            # Extension filtering strategy
            $useFilter    = $includeExtList.Count -gt 0
            $singleFilter = $includeExtList.Count -eq 1 -and ($includeExtList[0] -notmatch '[*?]')
            if ($useFilter -and -not $singleFilter) {
                $extSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($e in $includeExtList) { [void]$extSet.Add('.' + $e.Trim('.')) }
            }

            # ---- dequeue work items dynamically (safe TryDequeue) ----
            $item = $null
            while ($queueLocal.TryDequeue([ref]$item)) {
                if ([string]::IsNullOrWhiteSpace($item)) { continue }
                $subtree = $item
                try {
                    # INLINE UNC reachability check with shared cache
                    if ($subtree -like '\\*' -and ($subtree -match '^[\\]{2}([^\\]+)')) {
                        $server = $Matches[1]
                        $reachableRef = $null
                        if (-not $uncCache.TryGetValue($server, [ref]$reachableRef)) {
                            $reachableRef = Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue
                            $uncCache[$server] = [bool]$reachableRef
                        }
                        if (-not [bool]$reachableRef) {
                            if ($verboseFlag) { Add-Content -LiteralPath $errorLogPath -Value ("Stage2: UNC host unreachable: {0}" -f $subtree) }
                            continue
                        }
                    }

                    if (-not (Test-Path -LiteralPath $subtree)) { continue }

                    # Prefer provider-side filtering where possible
                    if ($singleFilter) {
                        $ext = $includeExtList[0].Trim('.')
                        $pattern = "*.$ext"
                        $files = Get-ChildItem -LiteralPath $subtree -File -Recurse -ErrorAction SilentlyContinue `
                                 -Attributes !ReparsePoint -Filter $pattern
                    } else {
                        $files = Get-ChildItem -LiteralPath $subtree -File -Recurse -ErrorAction SilentlyContinue `
                                 -Attributes !ReparsePoint
                        if ($useFilter) {
                            $files = $files | Where-Object { $extSet.Contains($_.Extension) }
                        }
                    }

                    foreach ($f in $files) {
                        # CSV-safe: quote Root and Path, include SizeBytes
                        $sw.WriteLine(
                            '"' + ($rootKeyLocal -replace '"','""') + '","' +
                            ($f.FullName -replace '"','""') + '",' + $f.Length
                        )
                        if ($echo) { Write-Host $f.FullName }
                    }
                } catch {
                    $localErr = $localErr + ("{0} : {1}`n" -f $subtree, $_.ToString())
                }
            }
        }
        finally {
            $sw.Flush(); $sw.Dispose()
        }

        # Emit results back to parent
        if ($localErr) {
            $errfile = Join-Path $rootTempDirLocal ("err_{0}.log" -f ([guid]::NewGuid()))
            $localErr | Out-File -LiteralPath $errfile -Encoding utf8
            [PSCustomObject]@{ Kind='Err'; Path=$errfile }
        }
        if ((Test-Path -LiteralPath $temp) -and ((Get-Item -LiteralPath $temp).Length -gt 0)) {
            [PSCustomObject]@{ Kind='Out'; Path=$temp }
        } else {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        }
    }  # end -Parallel

    # Separate temp & error files from worker output
    $rootTemps = @()
    $rootErrs  = @()
    foreach ($r in $workerResults) {
        if ($null -eq $r) { continue }
        if ($r.Kind -eq 'Out') { $rootTemps += $r.Path }
        elseif ($r.Kind -eq 'Err') { $rootErrs += $r.Path }
    }

    # Stream-compress: header + all temp lines into a ZIP (CSV inside named after the root tag)
    $rootZipPath = Join-Path $ResultsRunDir ("{0}.zip" -f $rootTag)
    Reset-File $rootZipPath
    $entryName = ("{0}.csv" -f $rootTag)
    $rows = Compress-TempFilesToZip -TempFiles $rootTemps -HeaderLine 'Root,Path,SizeBytes' -ZipPath $rootZipPath -EntryName $entryName
    Write-Host ("Stage 2: {0} -> {1} (rows: {2})" -f $rootKey, $rootZipPath, $rows)

    # Cleanup temp files
    foreach ($t in $rootTemps) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    foreach ($e in $rootErrs)  {
        if ($VerboseErrors) {
            try { Get-Content -LiteralPath $e -ErrorAction SilentlyContinue | Add-Content -Path $ErrorLog -Encoding utf8 } catch {}
        }
        Remove-Item -LiteralPath $e -Force -ErrorAction SilentlyContinue
    }
    # Remove per-root temp dir if empty
    try {
        if ((Get-ChildItem -LiteralPath $rootTempDir -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
            Remove-Item -LiteralPath $rootTempDir -Force
        }
    } catch {}
}

# Remove global per-run temp dir if empty
try {
    if ((Get-ChildItem -LiteralPath $TempRunDir -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
        Remove-Item -LiteralPath $TempRunDir -Force
    }
} catch {}

if ($VerboseErrors -and (Test-Path -LiteralPath $ErrorLog)) {
    Write-Host "Done. Errors (if any) -> $ErrorLog"
} else {
    Write-Host "Done."
}

