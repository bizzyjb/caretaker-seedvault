<#
.SYNOPSIS
    Caretaker SeedVault - the save monitor.

.DESCRIPTION
    Watches your save folder(s) and copies every new or modified save to a timestamped
    vault. Vault files are NEVER overwritten and never deleted.

    Reads its settings from the config written by Setup. Command-line parameters override
    the config, which is how the self-test drives it against throwaway folders.

.EXAMPLE
    .\Watch-Saves.ps1
    .\Watch-Saves.ps1 -SourcePaths C:\test\src -ArchivePath C:\test\dst -Once
#>
[CmdletBinding()]
param(
    [string[]]$SourcePaths,
    [string]  $ArchivePath,
    [int]     $PollSeconds,
    [string]  $FilePattern,
    [int]     $MinFreeGB,
    [switch]  $NoDedupe,
    [switch]  $NoReadOnly,
    [switch]  $Once,
    [switch]  $Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

# ------------------------------------------------------- resolve settings ----

$cfg = Read-SeedVaultConfig
if (-not $SourcePaths) {
    if (-not $cfg) { throw "Not configured yet. Run Setup.cmd first." }
    $SourcePaths = @($cfg.SourcePaths)
}
if (-not $ArchivePath) { $ArchivePath = if ($cfg) { $cfg.ArchivePath } else { throw "No archive path. Run Setup.cmd first." } }
if (-not $PollSeconds) { $PollSeconds = if ($cfg -and $cfg.PollSeconds) { $cfg.PollSeconds } else { 4 } }
if (-not $FilePattern) { $FilePattern = if ($cfg -and $cfg.FilePattern) { $cfg.FilePattern } else { '*.sav' } }
if (-not $MinFreeGB)   { $MinFreeGB   = if ($cfg -and $cfg.MinFreeGB)   { $cfg.MinFreeGB }   else { 10 } }

$dedupe   = if ($NoDedupe)   { $false } elseif ($cfg) { $cfg.Dedupe }   else { $true }
$readOnly = if ($NoReadOnly) { $false } elseif ($cfg) { $cfg.ReadOnly } else { $true }
$pruneDays = if ($cfg -and $cfg.PruneAfterDays) { [int]$cfg.PruneAfterDays } else { 0 }

# A save must look identical for this many consecutive polls before we trust that the
# write has finished. Saves can be tens of MB and take real time to land on disk.
$RequiredStablePolls = 2

$ManifestPath = Join-Path $ArchivePath '_manifest.csv'
$LogPath      = Join-Path $ArchivePath '_log.txt'
$LogMaxBytes  = 5MB

$script:LastSeen    = @{}
$script:StableCount = @{}
$script:Handled     = @{}
$script:KnownHashes = @{}
$script:LockWaits   = @{}
$script:CopyCount   = 0
$script:DupCount    = 0

# ---------------------------------------------------------------- logging ----

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv), $Level, $Message
    if (-not $Quiet) {
        switch ($Level) {
            'COPY'  { Write-Host $line -ForegroundColor Green }
            'SKIP'  { Write-Host $line -ForegroundColor DarkGray }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'ERROR' { Write-Host $line -ForegroundColor Red }
            default { Write-Host $line }
        }
    }
    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt $LogMaxBytes) {
            $rolled = Join-Path $ArchivePath '_log.1.txt'
            if (Test-Path -LiteralPath $rolled) { Remove-Item -LiteralPath $rolled -Force }
            Move-Item -LiteralPath $LogPath -Destination $rolled
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        # A logging failure must never take down the monitor.
    }
}

# --------------------------------------------------------------- manifest ----

function ConvertTo-CsvField {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    '"' + ($Value -replace '"', '""') + '"'
}

function Add-ManifestRow {
    param(
        [string]$Origin, [string]$SourceFile, [string]$ArchivedPath,
        [long]$Bytes, [string]$Sha256, [string]$SourceLastWrite, [string]$Status
    )
    $values = @(
        (Get-Date).ToUniversalTime().ToString('o', $script:Inv), $Origin, $SourceFile,
        $ArchivedPath, [string]$Bytes, $Sha256, $SourceLastWrite, $Status
    )
    $fields = $values | ForEach-Object { ConvertTo-CsvField ([string]$_) }
    Add-Content -LiteralPath $ManifestPath -Value ($fields -join ',') -Encoding UTF8
}

# ------------------------------------------------------------------ setup ----

function Initialize-Vault {
    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        New-Item -ItemType Directory -Path $ArchivePath -Force | Out-Null
        Write-Log "Created vault: $ArchivePath"
    }

    # Partial copies from an interrupted run are never valid saves.
    $stale = @(Get-ChildItem -LiteralPath $ArchivePath -Recurse -Filter '*.tmp' -File -ErrorAction SilentlyContinue)
    foreach ($t in $stale) {
        Remove-Item -LiteralPath $t.FullName -Force -ErrorAction SilentlyContinue
        Write-Log "Removed stale partial copy: $($t.Name)" 'WARN'
    }

    if (Test-Path -LiteralPath $ManifestPath) {
        $rows = @(Import-Csv -LiteralPath $ManifestPath -ErrorAction SilentlyContinue)
        foreach ($r in $rows) {
            if ($r.Sha256 -and $r.Status -notlike 'DUPLICATE-OF*') {
                $script:KnownHashes[$r.Sha256] = $r.ArchivedPath
            }
        }
        Write-Log "Loaded $($script:KnownHashes.Count) known save states."
    } else {
        Add-Content -LiteralPath $ManifestPath -Encoding UTF8 -Value 'ArchivedAtUtc,Origin,SourceFile,ArchivedPath,Bytes,Sha256,SourceLastWrite,Status'
        # Adopt anything already in the vault (e.g. the snapshot Setup took) so those
        # states count toward dedupe instead of being copied a second time.
        $existing = @(Get-ChildItem -LiteralPath $ArchivePath -Recurse -Filter $FilePattern -File -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) {
            Write-Log "Indexing $($existing.Count) file(s) already in the vault..."
            foreach ($e in $existing) {
                $h = (Get-FileHash -LiteralPath $e.FullName -Algorithm SHA256).Hash
                if (-not $script:KnownHashes.ContainsKey($h)) {
                    $script:KnownHashes[$h] = $e.FullName
                    Add-ManifestRow -Origin 'snapshot' -SourceFile $e.Name -ArchivedPath $e.FullName -Bytes $e.Length -Sha256 $h -SourceLastWrite $e.LastWriteTime.ToString('o', $script:Inv) -Status 'SNAPSHOT'
                }
            }
            Write-Log "Indexed $($script:KnownHashes.Count) distinct save states."
        }
    }
}

# ---------------------------------------------------------------- helpers ----

function Test-FileReadable {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $fs.Close()
        $fs.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Get-Origin {
    param([System.IO.FileInfo]$File)
    if ($File.DirectoryName -like '*SaveGameBackups*') { return 'game-backup' }
    return 'save'
}

function Get-VaultTarget {
    param([System.IO.FileInfo]$File)
    # Files the game already stamped keep their own name. Ours get the save's own
    # modified time - the moment you were actually at that point, not the copy time.
    if ($File.Name -match '_(\d{4}-\d{2}-\d{2})_\d{2}_\d{2}_\d{2}\.[^.]+$') {
        $day  = $Matches[1]
        $leaf = $File.BaseName
    } else {
        $ts   = $File.LastWriteTime
        $day  = $ts.ToString('yyyy-MM-dd', $script:Inv)
        $leaf = '{0}__{1}' -f $File.BaseName, $ts.ToString('yyyy-MM-dd_HH-mm-ss', $script:Inv)
    }
    $dir = Join-Path $ArchivePath $day
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # An existing file is NEVER a write target. Suffix until the name is free.
    $ext    = $File.Extension
    $target = Join-Path $dir "$leaf$ext"
    $n = 2
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $dir ('{0}_{1}{2}' -f $leaf, $n, $ext)
        $n++
    }
    return $target
}

# ------------------------------------------------------------------ store ----

function Save-VaultCopy {
    param([System.IO.FileInfo]$File)

    $src        = $File.FullName
    $origin     = Get-Origin $File
    $beforeLen  = $File.Length
    $beforeTime = $File.LastWriteTimeUtc

    $target = Get-VaultTarget $File
    $tmp    = "$target.tmp"

    Copy-Item -LiteralPath $src -Destination $tmp -Force

    # If the game rewrote the file mid-copy, what we captured is untrustworthy.
    $after = Get-Item -LiteralPath $src
    if ($after.Length -ne $beforeLen -or $after.LastWriteTimeUtc -ne $beforeTime) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Log "$($File.Name) changed while copying - will retry." 'WARN'
        return $false
    }

    $tmpItem = Get-Item -LiteralPath $tmp
    if ($tmpItem.Length -ne $beforeLen) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Log "$($File.Name) short copy ($($tmpItem.Length) vs $beforeLen) - discarded." 'ERROR'
        return $false
    }

    # Hash the copy rather than the source, so the hash always describes the stored bytes.
    $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash

    if ($dedupe -and $script:KnownHashes.ContainsKey($hash)) {
        $existing = $script:KnownHashes[$hash]
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Add-ManifestRow -Origin $origin -SourceFile $File.Name -ArchivedPath $existing -Bytes $beforeLen -Sha256 $hash -SourceLastWrite $File.LastWriteTime.ToString('o', $script:Inv) -Status "DUPLICATE-OF:$existing"
        $script:DupCount++
        Write-Log "SKIP $($File.Name) - already stored as $(Split-Path $existing -Leaf)" 'SKIP'
        return $true
    }

    Move-Item -LiteralPath $tmp -Destination $target   # errors rather than overwrites
    $item = Get-Item -LiteralPath $target
    $item.LastWriteTime = $File.LastWriteTime
    if ($readOnly) { $item.IsReadOnly = $true }

    $script:KnownHashes[$hash] = $target
    $script:CopyCount++
    Add-ManifestRow -Origin $origin -SourceFile $File.Name -ArchivedPath $target -Bytes $beforeLen -Sha256 $hash -SourceLastWrite $File.LastWriteTime.ToString('o', $script:Inv) -Status 'COPIED'

    Write-Log "SAVED $($File.Name) -> $($target.Substring($ArchivePath.Length + 1))  ($(Format-Size $beforeLen))" 'COPY'
    return $true
}

# ------------------------------------------------------------------- poll ----

function Invoke-Pass {
    $live = @{}

    foreach ($dir in $SourcePaths) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $files = @(Get-ChildItem -LiteralPath $dir -Filter $FilePattern -File -ErrorAction SilentlyContinue)

        foreach ($f in $files) {
            $key = $f.FullName
            $live[$key] = $true
            $sig = '{0}|{1}' -f $f.Length, $f.LastWriteTimeUtc.Ticks

            # Already stored this exact version - don't re-copy it every poll.
            if ($script:Handled.ContainsKey($key) -and $script:Handled[$key] -eq $sig) { continue }

            if ($script:LastSeen.ContainsKey($key) -and $script:LastSeen[$key] -eq $sig) {
                $script:StableCount[$key] = [int]$script:StableCount[$key] + 1
            } else {
                $script:LastSeen[$key]    = $sig
                $script:StableCount[$key] = 1
                continue   # it just changed - let it settle before touching it
            }

            if ($script:StableCount[$key] -lt $RequiredStablePolls) { continue }

            if (-not (Test-FileReadable $key)) {
                $script:LockWaits[$key] = [int]$script:LockWaits[$key] + 1
                if (($script:LockWaits[$key] % 15) -eq 0) {
                    Write-Log "$($f.Name) is still locked by the game - waiting." 'WARN'
                }
                continue   # keep retrying; never abandon a save
            }
            $script:LockWaits[$key] = 0

            try {
                # Only mark handled when it genuinely succeeded, so a failure retries
                # next poll instead of silently dropping the save.
                if (Save-VaultCopy $f) { $script:Handled[$key] = $sig }
            } catch {
                Write-Log "Could not store $($f.Name): $($_.Exception.Message)" 'ERROR'
            }
            $script:StableCount[$key] = 0
        }
    }

    # Forget files the game rotated away so these tables cannot grow forever.
    $gone = @($script:LastSeen.Keys | Where-Object { -not $live.ContainsKey($_) })
    foreach ($stale in $gone) {
        $script:LastSeen.Remove($stale)
        $script:StableCount.Remove($stale)
        $script:Handled.Remove($stale)
        $script:LockWaits.Remove($stale)
    }
}

function Test-VaultSpace {
    $free = Get-DriveFreeBytes $ArchivePath
    if ($null -ne $free -and $free -lt ($MinFreeGB * 1GB)) {
        Write-Log "LOW DISK SPACE: $(Format-Size $free) free on the vault drive. Still archiving - free some space." 'WARN'
    }
}

function Invoke-Prune {
    if ($pruneDays -le 0) { return }   # 0 = keep everything, the default
    $cutoff = (Get-Date).AddDays(-$pruneDays)
    $old = @(Get-ChildItem -LiteralPath $ArchivePath -Recurse -Filter $FilePattern -File -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -lt $cutoff })
    foreach ($o in $old) {
        try {
            if ($o.IsReadOnly) { $o.IsReadOnly = $false }
            Remove-Item -LiteralPath $o.FullName -Force
            Write-Log "Pruned (older than $pruneDays days): $($o.Name)" 'WARN'
        } catch {
            Write-Log "Could not prune $($o.Name): $($_.Exception.Message)" 'ERROR'
        }
    }
}

# ------------------------------------------------------------------- main ----

# The lock is keyed on the VAULT, not on the app name. Two monitors writing to one vault
# would race on the same temporary file and could commit a mixed-content save that still
# passed its length check - corruption in the one place that must never have any. Keying
# on the vault means any second monitor for this vault backs off, whichever install it
# came from, while a monitor for a different vault is free to run alongside.
$vaultKey = ([System.BitConverter]::ToString(
    (New-Object System.Security.Cryptography.SHA256Managed).ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($ArchivePath.ToLowerInvariant().TrimEnd('\'))
    )) -replace '-', '').Substring(0, 16)

$mutex = New-Object System.Threading.Mutex($false, "Local\$($script:AppSlug)_$vaultKey")
if (-not $mutex.WaitOne(0)) {
    Write-Host "Another Caretaker SeedVault monitor is already watching this vault:" -ForegroundColor Yellow
    Write-Host "  $ArchivePath" -ForegroundColor Yellow
    Write-Host "Nothing to do - the saves are already being looked after." -ForegroundColor Yellow
    exit 2
}

try {
    Initialize-Vault
    Write-Log "=== Caretaker SeedVault v$script:AppVersion started (every ${PollSeconds}s) ==="
    foreach ($s in $SourcePaths) {
        $state = if (Test-Path -LiteralPath $s) { 'watching' } else { 'not found yet' }
        Write-Log "  $state : $s"
    }
    Write-Log "  vault    : $ArchivePath"

    if ($Once) {
        for ($i = 0; $i -lt ($RequiredStablePolls + 2); $i++) {
            Invoke-Pass
            Start-Sleep -Milliseconds 400
        }
        Write-Log "=== Done: $($script:CopyCount) stored, $($script:DupCount) already had ==="
    } else {
        $tick = 0
        while ($true) {
            try {
                Invoke-Pass
                $tick++
                if (($tick % 150) -eq 0) { Test-VaultSpace }
                if (($tick % 900) -eq 0) { Invoke-Prune }
            } catch {
                # The loop must never die and leave saves unprotected.
                Write-Log "Poll error (continuing): $($_.Exception.Message)" 'ERROR'
            }
            Start-Sleep -Seconds $PollSeconds
        }
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
