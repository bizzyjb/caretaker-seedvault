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

# The live monitor process is the authority, not the task state. The task launches the
# monitor and exits straight away, so a healthy setup shows the task as "Ready" while the
# monitor runs happily detached - reading the task state alone would be misleading.
$task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
$proc = @(Get-MonitorProcess)

$running = ($proc.Count -gt 0)
if ($task)                   { $how = 'starts at logon, checks itself every 15 min' }
elseif (Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) "$($script:AppSlug).vbs")) {
                               $how = 'starts from your Startup folder' }
else                         { $how = 'no automatic start configured' }

if ($running) {
    Write-Host "  MONITOR: running  ($how)" -ForegroundColor Green
} else {
    Write-Host "  MONITOR: NOT RUNNING" -ForegroundColor Red
    Write-Host "  Your saves are not being protected right now." -ForegroundColor Red
    if ($task) {
        Write-Host "  It should restart by itself within 15 minutes." -ForegroundColor Yellow
        Write-Host "  To start it immediately: Start-ScheduledTask -TaskName $($script:TaskName)" -ForegroundColor Yellow
    } else {
        Write-Host "  Run Setup.cmd again to fix it." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------- what's inside ----

Write-Host ''
Write-Host "  Vault    : $($cfg.ArchivePath)"
foreach ($s in (Get-ExpandedSourcePaths -SourcePaths @($cfg.SourcePaths))) {
    $mark = if (Test-Path -LiteralPath $s) { ' ' } else { '!' }
    Write-Host "  Watching${mark}: $s"
}

# A game update can move the saves into a new profile folder. Say so plainly - the
# alternative is a status screen that looks perfectly healthy while the folder it names
# has not changed in weeks.
$configured = @($cfg.SourcePaths)[0]
$active     = Get-ActiveSavePath -SourcePaths @($cfg.SourcePaths) -Configured $configured
if ($active -and $configured -and $active -ne $configured) {
    Write-Host ''
    Write-Host "  The game is now saving into a different folder than setup chose:" -ForegroundColor Yellow
    Write-Host "    $active" -ForegroundColor Yellow
    Write-Host "  It is being watched as well, so nothing is being missed." -ForegroundColor DarkGray
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

        # ---- getting a save back ----
        # Restoring matters as much as keeping, so prove that half works too.
        #
        # Order matters here. A same-slot restore drops a copy into _before-restore, which
        # then appears in the listing too and shifts what "-Index 2" refers to. So do the
        # different-slot restore first, while the vault still holds exactly two entries.
        $restorer   = Join-Path $PSScriptRoot 'Restore-Save.ps1'
        $older      = @(Get-ChildItem $dst -Recurse -Filter *.sav -File | Sort-Object LastWriteTime -Descending)[1]
        $olderHash  = (Get-FileHash $older.FullName -Algorithm SHA256).Hash
        $liveBefore = (Get-FileHash $fake -Algorithm SHA256).Hash

        # ---- restoring into a different slot (nothing exists in slot 3 yet) ----
        # 6>$null suppresses Write-Host output, which Out-Null does not catch.
        & $restorer -VaultPath $dst -SavePath $src -Index 2 -ToSlot 3 -Yes 6>$null | Out-Null
        $slot3 = Join-Path $src 'TestProfile_3.sav'
        Check 'a save can be restored into a different slot' ((Test-Path $slot3) -and (Get-FileHash $slot3 -Algorithm SHA256).Hash -eq $olderHash)
        Check 'restoring elsewhere leaves the original slot alone' ((Get-FileHash $fake -Algorithm SHA256).Hash -eq $liveBefore)

        # ---- restoring into its own slot ----
        & $restorer -VaultPath $dst -SavePath $src -Index 2 -Yes 6>$null | Out-Null

        Check 'a chosen save is put back into the game folder' ((Get-FileHash $fake -Algorithm SHA256).Hash -eq $olderHash)
        Check 'the restored save is not left read-only' (-not (Get-Item $fake).IsReadOnly)

        # A read-only restored save would stop the game writing that slot at all.
        $canWrite = $false
        try { $h = [System.IO.File]::Open($fake, 'Open', 'Write', 'None'); $h.Close(); $canWrite = $true } catch { }
        Check 'the game can still write to the restored save' $canWrite

        $kept = @(Get-ChildItem (Join-Path $dst '_before-restore') -Recurse -File -ErrorAction SilentlyContinue)
        Check 'the save being replaced was kept first' ($kept.Count -ge 1 -and (Get-FileHash $kept[0].FullName -Algorithm SHA256).Hash -eq $liveBefore)
        Check 'restoring destroyed nothing in the vault' ((Test-Path $older.FullName) -and (Get-FileHash $older.FullName -Algorithm SHA256).Hash -eq $olderHash)

        # ---- the game renaming its own saves must not break a restore ----
        # A save archived as TestProfile_0.sav has to come back as NewProfile_0.sav once
        # the game has started calling its saves NewProfile_*. Put back under the old name
        # it would sit in exactly the right folder and the game would still show an empty
        # slot.
        $src4 = Join-Path $tmp 'src4'
        $dst4 = Join-Path $tmp 'dst4'
        New-Item -ItemType Directory -Path $src4, $dst4 -Force | Out-Null
        $old4 = Join-Path $src4 'TestProfile_0.sav'
        [System.IO.File]::WriteAllBytes($old4, (New-Object byte[] 700))
        & $watcher -SourcePaths @($src4) -ArchivePath $dst4 -Once -Quiet | Out-Null
        Remove-Item -LiteralPath $old4 -Force
        $new4 = Join-Path $src4 'NewProfile_0.sav'
        [System.IO.File]::WriteAllBytes($new4, (New-Object byte[] 300))
        & $restorer -VaultPath $dst4 -SavePath $src4 -Index 1 -Yes 6>$null | Out-Null
        Check 'a restore follows the name the game uses now' ((Test-Path $new4) -and (Get-Item $new4).Length -eq 700)
        Check 'the name the game abandoned is not resurrected' (-not (Test-Path $old4))

        # ---- a save folder appearing beside the watched one is picked up ----
        # The Linux update of 31 August 2026 in miniature: the game stops writing to the
        # profile folder setup chose and starts writing to a sibling. Watching only what
        # the config names would quietly capture nothing from then on.
        $root5 = Join-Path $tmp 'Voyage\Saved\SaveGames'
        $old5  = Join-Path $root5 '76561197960000000'
        $new5  = Join-Path $root5 'LocalSteamUser'
        $dst5  = Join-Path $tmp 'dst5'
        New-Item -ItemType Directory -Path $old5, $new5, $dst5 -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $old5 '76561197960000000_0.sav'), (New-Object byte[] 400))
        [System.IO.File]::WriteAllBytes((Join-Path $new5 'VoyageSaveGame_0.sav'),    (New-Object byte[] 500))
        & $watcher -SourcePaths @($old5) -ArchivePath $dst5 -Once -Quiet | Out-Null
        $stored5 = @(Get-ChildItem $dst5 -Recurse -Filter *.sav -File)
        Check 'a save folder that appears beside the watched one is picked up' ($stored5.Count -eq 2)

        # ---- two Steam accounts must not be mistaken for a rename ----
        # Both folders get watched, which only costs disk. But a restore has to stay in
        # the folder that was set up, or it lands in the other person's game.
        $sg8    = Join-Path $tmp 'two\Voyage\Saved\SaveGames'
        $mine   = Join-Path $sg8 '76561197960000001'
        $theirs = Join-Path $sg8 '76561197960000002'
        New-Item -ItemType Directory -Path $mine, $theirs -Force | Out-Null
        $mineSave = Join-Path $mine '76561197960000001_0.sav'
        [System.IO.File]::WriteAllBytes($mineSave, (New-Object byte[] 128))
        [System.IO.File]::WriteAllBytes((Join-Path $theirs '76561197960000002_0.sav'), (New-Object byte[] 128))
        (Get-Item $mineSave).LastWriteTime = (Get-Date).AddDays(-30)
        Check 'a second Steam account does not steal the restore' `
            ((Get-ActiveSavePath -SourcePaths @($mine) -Configured $mine) -eq $mine)
        Check 'but both accounts are still watched' `
            ((Get-ExpandedSourcePaths -SourcePaths @($mine)).Count -eq 2)

        # ---- a renamed folder still wins, whatever it is called ----
        # Nothing here knows the name the game picked - only that it is not another
        # Steam ID.
        $sg9 = Join-Path $tmp 'renamed\Voyage\Saved\SaveGames'
        $was = Join-Path $sg9 '76561197960000001'
        $now = Join-Path $sg9 'SomeFutureName'
        New-Item -ItemType Directory -Path $was, $now -Force | Out-Null
        $wasSave = Join-Path $was '76561197960000001_0.sav'
        [System.IO.File]::WriteAllBytes($wasSave, (New-Object byte[] 128))
        [System.IO.File]::WriteAllBytes((Join-Path $now 'SomeFutureName_0.sav'), (New-Object byte[] 128))
        (Get-Item $wasSave).LastWriteTime = (Get-Date).AddDays(-30)
        Check 'a folder under a new name does take over' `
            ((Get-ActiveSavePath -SourcePaths @($was) -Configured $was) -eq $now)

        # ---- and an empty configured folder gives way to whatever has saves ----
        $sg10 = Join-Path $tmp 'emptied\Voyage\Saved\SaveGames'
        $gone = Join-Path $sg10 '76561197960000001'
        $live = Join-Path $sg10 '76561197960000002'
        New-Item -ItemType Directory -Path $gone, $live -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $live '76561197960000002_0.sav'), (New-Object byte[] 128))
        Check 'an emptied folder gives way even to another Steam ID' `
            ((Get-ActiveSavePath -SourcePaths @($gone) -Configured $gone) -eq $live)

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
