<#
.SYNOPSIS
    Caretaker SeedVault - health check.

.DESCRIPTION
    Shows whether the monitor is running, what it has captured, and how much space the
    vault is using. Use -SelfTest to prove the whole capture pipeline works end to end
    using throwaway files - it never touches your real saves.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Write-Banner 'Status'

$cfg = Read-SeedVaultConfig
if (-not $cfg) {
    Write-Host "  Not set up on this machine yet. Run Setup.cmd first." -ForegroundColor Yellow
    Write-Host ''
    # -SelfTest still runs: checking the tool works before installing it is reasonable.
    if (-not $SelfTest) { return }
}

# ------------------------------------------------------------- is it on? ----

if ($cfg) {

$running = $false
$how     = 'not running'

$task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
if ($task) {
    $running = ($task.State -eq 'Running')
    $how = "Scheduled Task ($($task.State))"
}
$proc = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
          Where-Object { $_.CommandLine -like '*Watch-Saves.ps1*' })
if ($proc.Count -gt 0) {
    $running = $true
    if (-not $task) { $how = 'Startup folder' }
}

if ($running) {
    Write-Host "  MONITOR: running  ($how)" -ForegroundColor Green
} else {
    Write-Host "  MONITOR: NOT RUNNING  ($how)" -ForegroundColor Red
    Write-Host "  Your saves are not being protected right now." -ForegroundColor Red
    Write-Host "  Run Setup.cmd again to fix it." -ForegroundColor Yellow
}

# ---------------------------------------------------------- what's inside ----

Write-Host ''
Write-Host "  Vault    : $($cfg.ArchivePath)"
foreach ($s in @($cfg.SourcePaths)) {
    $mark = if (Test-Path -LiteralPath $s) { ' ' } else { '!' }
    Write-Host "  Watching${mark}: $s"
}

if (Test-Path -LiteralPath $cfg.ArchivePath) {
    $files = @(Get-ChildItem -LiteralPath $cfg.ArchivePath -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -eq '.sav' })
    $bytes = ($files | Measure-Object Length -Sum).Sum
    Write-Host ''
    Write-Host "  Saves kept : $($files.Count)" -ForegroundColor Cyan
    Write-Host "  Using      : $(Format-Size $bytes)" -ForegroundColor Cyan

    $free = Get-DriveFreeBytes $cfg.ArchivePath
    if ($free) {
        $colour = if ($free -lt ($cfg.MinFreeGB * 1GB)) { 'Red' } else { 'Cyan' }
        Write-Host "  Free space : $(Format-Size $free)" -ForegroundColor $colour
    }

    if ($files.Count -gt 0) {
        $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $oldest = $files | Sort-Object LastWriteTime | Select-Object -First 1
        Write-Host ''
        Write-Host "  Newest : $($newest.LastWriteTime)  $($newest.Name)" -ForegroundColor Gray
        Write-Host "  Oldest : $($oldest.LastWriteTime)  $($oldest.Name)" -ForegroundColor Gray
        $span = (New-TimeSpan -Start $oldest.LastWriteTime -End $newest.LastWriteTime)
        Write-Host "  You can go back $([int]$span.TotalDays) day(s) / $([int]$span.TotalHours) hour(s)." -ForegroundColor Green
    }
}

$log = Join-Path $cfg.ArchivePath '_log.txt'
if (Test-Path -LiteralPath $log) {
    Write-Host ''
    Write-Host "  Recent activity:" -ForegroundColor Cyan
    Get-Content -LiteralPath $log -Tail 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}

}   # end: only when configured

# --------------------------------------------------------------- selftest ----

if ($SelfTest) {
    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host '   SELF-TEST - uses throwaway files, never your real saves' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan

    $tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("sv-selftest-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $src  = Join-Path $tmp 'src'
    $dst  = Join-Path $tmp 'dst'
    New-Item -ItemType Directory -Path $src, $dst -Force | Out-Null
    $watcher = Join-Path $PSScriptRoot 'Watch-Saves.ps1'
    $pass = 0; $fail = 0
    function Check {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host "   PASS  $Name" -ForegroundColor Green; $script:pass++ }
        else     { Write-Host "   FAIL  $Name" -ForegroundColor Red;   $script:fail++ }
    }

    try {
        $fake = Join-Path $src 'TestProfile_0.sav'
        [System.IO.File]::WriteAllBytes($fake, (New-Object byte[] 2048))
        & $watcher -SourcePaths @($src) -ArchivePath $dst -Once -Quiet | Out-Null
        $stored = @(Get-ChildItem $dst -Recurse -Filter *.sav -File)
        Check 'a new save is captured' ($stored.Count -eq 1)
        Check 'stored copy is the right size' ($stored.Count -eq 1 -and $stored[0].Length -eq 2048)
        Check 'stored copy is protected from overwrite' ($stored.Count -eq 1 -and $stored[0].IsReadOnly)

        $firstName = $stored[0].FullName
        $firstHash = (Get-FileHash $firstName -Algorithm SHA256).Hash

        # A changed save must produce a second copy, leaving the first alone.
        [System.IO.File]::WriteAllBytes($fake, (New-Object byte[] 4096))
        (Get-Item $fake).LastWriteTime = (Get-Date).AddMinutes(1)
        & $watcher -SourcePaths @($src) -ArchivePath $dst -Once -Quiet | Out-Null
        $stored2 = @(Get-ChildItem $dst -Recurse -Filter *.sav -File)
        Check 'a changed save is captured separately' ($stored2.Count -eq 2)
        Check 'the earlier save was left untouched' ((Test-Path $firstName) -and (Get-FileHash $firstName -Algorithm SHA256).Hash -eq $firstHash)

        # Re-saving identical content must not waste space.
        (Get-Item $fake).LastWriteTime = (Get-Date).AddMinutes(2)
        & $watcher -SourcePaths @($src) -ArchivePath $dst -Once -Quiet | Out-Null
        $stored3 = @(Get-ChildItem $dst -Recurse -Filter *.sav -File)
        Check 'identical content is not stored twice' ($stored3.Count -eq 2)

        Write-Host ''
        if ($fail -eq 0) {
            Write-Host "   $pass checks passed. The vault is working correctly." -ForegroundColor Green
        } else {
            Write-Host "   $pass passed, $fail FAILED. Please report this." -ForegroundColor Red
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if (-not $SelfTest) {
    Write-Host "  Tip: run with -SelfTest to verify the whole pipeline works." -ForegroundColor DarkGray
    Write-Host ''
}
