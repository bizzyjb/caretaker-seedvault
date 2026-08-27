<#
.SYNOPSIS
    Caretaker SeedVault - interactive setup.

.DESCRIPTION
    Finds your saves, asks where the vault should live, takes a first snapshot, and
    sets the monitor to start automatically at logon. Needs no administrator rights.
#>
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$SavePath,
    [string]$VaultPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Read-Choice {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) { $answer = Read-Host "$Prompt [$Default]" } else { $answer = Read-Host $Prompt }
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

Write-Banner 'Setup'

Write-Host "  This keeps a copy of every save your game writes, each one stamped with the" -ForegroundColor Gray
Write-Host "  time it was made. Nothing in the vault is ever overwritten or deleted, so you" -ForegroundColor Gray
Write-Host "  can always go back to any point - not just the last few minutes." -ForegroundColor Gray
Write-Host ''

# ------------------------------------------------------- 1. find the saves ----

Write-Host "  [1/4] Looking for your saves..." -ForegroundColor Cyan
Write-Host ''

$chosen = $null

if ($SavePath) {
    $chosen = Resolve-ManualSavePath $SavePath
    if (-not $chosen) { throw "The save path given is not usable: $SavePath" }
} else {
    $candidates = @(Find-CaretakerSaves)

    if ($candidates.Count -gt 0) {
        Write-Host "  Found The Last Caretaker saves:" -ForegroundColor Green
        Write-Host ''
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $c = $candidates[$i]
            Write-Host ("    {0}) profile {1}" -f ($i + 1), $c.ProfileId) -ForegroundColor White
            Write-Host ("       {0} save(s), {1}, last played {2}" -f $c.SaveCount, (Format-Size $c.TotalBytes), $c.LastPlayed) -ForegroundColor Gray
            Write-Host ("       {0}" -f $c.SavePath) -ForegroundColor DarkGray
            if ($c.BackupPath) {
                Write-Host  "       + the game's own backup folder (will also be watched)" -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        Write-Host "    (The folder is called 'Voyage' - that's the game's internal codename,"  -ForegroundColor DarkGray
        Write-Host "     not a different game.)" -ForegroundColor DarkGray
        Write-Host ''

        if ($NonInteractive -or $candidates.Count -eq 1) {
            $chosen = $candidates[0]
            if (-not $NonInteractive) {
                $ok = Read-Choice "  Use this one? (Y/n, or 'm' to type a path yourself)" 'Y'
                if ($ok -match '^[Mm]') { $chosen = $null }
                elseif ($ok -match '^[Nn]') { $chosen = $null }
            }
        } else {
            $pick = Read-Choice "  Which one? (1-$($candidates.Count), or 'm' to type a path yourself)" '1'
            if ($pick -match '^[Mm]') {
                $chosen = $null
            } else {
                $idx = 0
                if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $candidates.Count) {
                    $chosen = $candidates[$idx - 1]
                }
            }
        }
    } else {
        Write-Host "  Could not find the game's saves automatically." -ForegroundColor Yellow
        Write-Host "  They are usually here:" -ForegroundColor Gray
        Write-Host "    $env:LOCALAPPDATA\Voyage\Saved\SaveGames\<your-steam-id>" -ForegroundColor DarkGray
        Write-Host ''
    }

    while (-not $chosen) {
        Write-Host "  Paste the full path to the folder containing your .sav files." -ForegroundColor Gray
        Write-Host "  (Open it in File Explorer and copy the address bar. Blank to cancel.)" -ForegroundColor DarkGray
        $manual = Read-Host "  Path"
        if ([string]::IsNullOrWhiteSpace($manual)) { Write-Host "  Setup cancelled."; return }
        $chosen = Resolve-ManualSavePath $manual
    }
}

Write-Host ''
Write-Host "  Watching: $($chosen.SavePath)" -ForegroundColor Green
foreach ($s in @($chosen.SourcePaths)) {
    if ($s -ne $chosen.SavePath) { Write-Host "           + $s" -ForegroundColor Green }
}

# ----------------------------------------------------- 2. where the vault ----

Write-Host ''
Write-Host "  [2/4] Where should the vault live?" -ForegroundColor Cyan
Write-Host ''

if (-not $VaultPath) {
    $saveDrive = (Split-Path $chosen.SavePath -Qualifier)
    $suggestions = @()

    # Prefer a drive that is not the one holding the saves: survives a disk failure.
    $others = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                Where-Object { $_.Free -gt 20GB -and "$($_.Name):" -ne $saveDrive -and $_.Name.Length -eq 1 })
    foreach ($d in $others) { $suggestions += "$($d.Name):\CaretakerSeedVault" }
    $suggestions += (Join-Path $env:USERPROFILE 'CaretakerSeedVault')

    for ($i = 0; $i -lt $suggestions.Count; $i++) {
        $free = Get-DriveFreeBytes $suggestions[$i]
        $note = if ($free) { "($(Format-Size $free) free)" } else { '' }
        $extra = if ((Split-Path $suggestions[$i] -Qualifier) -ne $saveDrive) { '  - different drive from your saves, safer' } else { '' }
        Write-Host ("    {0}) {1}  {2}{3}" -f ($i + 1), $suggestions[$i], $note, $extra) -ForegroundColor White
    }
    Write-Host ("    {0}) somewhere else - I'll type it" -f ($suggestions.Count + 1)) -ForegroundColor White
    Write-Host ''
    Write-Host "  Saves can be large. Expect a few hundred MB per long session." -ForegroundColor DarkGray
    Write-Host ''

    if ($NonInteractive) {
        $VaultPath = $suggestions[0]
    } else {
        $pick = Read-Choice "  Choose (1-$($suggestions.Count + 1))" '1'
        $idx = 0
        if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $suggestions.Count) {
            $VaultPath = $suggestions[$idx - 1]
        } else {
            while (-not $VaultPath) {
                $typed = Read-Host "  Full path for the vault folder"
                if ([string]::IsNullOrWhiteSpace($typed)) { Write-Host "  Setup cancelled."; return }
                $VaultPath = $typed.Trim().Trim('"')
            }
        }
    }
}

# Warn about choices that cause real problems, but let the user decide.
$cloud = Test-IsCloudSyncedPath $VaultPath
if ($cloud) {
    Write-Host ''
    Write-Host "  Warning: that folder looks like it syncs to $cloud." -ForegroundColor Yellow
    Write-Host "  Large saves landing there every few minutes will cause constant uploads." -ForegroundColor Yellow
    if (-not $NonInteractive) {
        $go = Read-Choice "  Use it anyway? (y/N)" 'N'
        if ($go -notmatch '^[Yy]') { Write-Host "  Setup cancelled - run again and pick another folder."; return }
    }
}
if ((Split-Path $VaultPath -Qualifier) -eq (Split-Path $chosen.SavePath -Qualifier)) {
    Write-Host ''
    Write-Host "  Note: the vault is on the same drive as your saves. That fully protects" -ForegroundColor Yellow
    Write-Host "  against the game overwriting them, but not against the drive failing." -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath $VaultPath)) {
    New-Item -ItemType Directory -Path $VaultPath -Force | Out-Null
}
Write-Host ''
Write-Host "  Vault: $VaultPath" -ForegroundColor Green

# ------------------------------------------------- 3. install + snapshot ----

Write-Host ''
Write-Host "  [3/4] Installing and taking a first snapshot..." -ForegroundColor Cyan

$appDir = Get-AppDir
if (-not (Test-Path -LiteralPath $appDir)) { New-Item -ItemType Directory -Path $appDir -Force | Out-Null }
Copy-Item -Path (Join-Path $PSScriptRoot '*.ps1') -Destination $appDir -Force
Write-Host "  Installed to $appDir" -ForegroundColor Gray
Write-Host "  (You can delete the folder you unzipped once setup finishes.)" -ForegroundColor DarkGray

$config = New-DefaultConfig -SourcePaths @($chosen.SourcePaths) -ArchivePath $VaultPath
Write-SeedVaultConfig $config

# Capture what exists right now, before the game recycles any of it. The game's own
# backup folder holds states that exist nowhere else and are deleted on a rolling basis.
$stamp    = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss', $script:Inv)
$snapDir  = Join-Path $VaultPath "_snapshot_$stamp"
$snapped  = 0
foreach ($sp in @($chosen.SourcePaths)) {
    if (-not (Test-Path -LiteralPath $sp)) { continue }
    $leaf = Split-Path (Split-Path $sp -Parent) -Leaf   # SaveGames | SaveGameBackups
    $dest = Join-Path $snapDir $leaf
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $files = @(Get-ChildItem -LiteralPath $sp -Filter '*.sav' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dest $f.Name) -Force
        $snapped++
    }
}
Write-Host "  Snapshot: $snapped save file(s) secured in $(Split-Path $snapDir -Leaf)" -ForegroundColor Green

# ------------------------------------------------------ 4. run at logon ----

Write-Host ''
Write-Host "  [4/4] Setting it to run automatically..." -ForegroundColor Cyan

$watcher    = Join-Path $appDir 'Watch-Saves.ps1'
$psArgs     = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Quiet' -f $watcher
$autoMethod = $null

try {
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    }
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Caretaker SeedVault - keeps a timestamped copy of every game save.' | Out-Null
    Start-ScheduledTask -TaskName $script:TaskName
    $autoMethod = 'Scheduled Task'
    Write-Host "  Registered a scheduled task and started it." -ForegroundColor Green
} catch {
    # Some machines block task registration. The Startup folder always works.
    Write-Host "  Scheduled task unavailable ($($_.Exception.Message.Split([Environment]::NewLine)[0]))." -ForegroundColor Yellow
    Write-Host "  Falling back to the Startup folder instead." -ForegroundColor Yellow
    $startup = [Environment]::GetFolderPath('Startup')
    $vbs     = Join-Path $startup "$($script:AppSlug).vbs"
    $vbsBody = @"
' Caretaker SeedVault - starts the save monitor hidden at logon.
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe $psArgs", 0, False
"@
    Set-Content -LiteralPath $vbs -Value $vbsBody -Encoding ASCII
    Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden
    $autoMethod = 'Startup folder'
    Write-Host "  Added to Startup and started it." -ForegroundColor Green
}

# Shortcuts, so people can find Restore without hunting for a script.
try {
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) $script:AppName
    if (-not (Test-Path -LiteralPath $menu)) { New-Item -ItemType Directory -Path $menu -Force | Out-Null }
    $sh = New-Object -ComObject WScript.Shell
    foreach ($pair in @(
        @{ Name = 'Restore a Save';   Script = 'Restore-Save.ps1';        Hidden = $false },
        @{ Name = 'SeedVault Status'; Script = 'Show-Status.ps1';         Hidden = $false },
        @{ Name = 'Uninstall';        Script = 'Uninstall-SeedVault.ps1'; Hidden = $false }
    )) {
        $lnk = $sh.CreateShortcut((Join-Path $menu "$($pair.Name).lnk"))
        $lnk.TargetPath       = 'powershell.exe'
        $lnk.Arguments        = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}"' -f (Join-Path $appDir $pair.Script)
        $lnk.WorkingDirectory = $appDir
        $lnk.Description      = "$($script:AppName) - $($pair.Name)"
        $lnk.Save()
    }
    $shortcutsMade = $true
} catch {
    $shortcutsMade = $false
}

# ------------------------------------------------------------- summary ----

Write-Host ''
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
Write-Host '   All set. Your saves are being preserved.' -ForegroundColor Green
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
Write-Host ''
Write-Host "   Vault      : $VaultPath"
Write-Host "   Watching   : $(@($chosen.SourcePaths).Count) folder(s)"
Write-Host "   Starts via : $autoMethod (automatically, at every logon)"
Write-Host "   Log        : $(Join-Path $VaultPath '_log.txt')"
if ($shortcutsMade) {
    Write-Host "   Shortcuts  : Start Menu > $script:AppName"
}
Write-Host ''
Write-Host "   To get a save back later, open Start Menu > $script:AppName > Restore a Save" -ForegroundColor Cyan
Write-Host "   (or run Restore.cmd from this folder)." -ForegroundColor Cyan
Write-Host ''
Write-Host "   Play normally. You don't need to do anything else." -ForegroundColor Gray
Write-Host ''
