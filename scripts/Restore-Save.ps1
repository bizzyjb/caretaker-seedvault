<#
.SYNOPSIS
    Caretaker SeedVault - put an old save back into the game.

.DESCRIPTION
    Lists what's in the vault newest-first and copies your choice back over the matching
    save slot. Your current save is copied into the vault first, so restoring an old save
    never destroys the one you have now.

.EXAMPLE
    .\Restore-Save.ps1
    .\Restore-Save.ps1 -Slot AutoSave -Last 60
    .\Restore-Save.ps1 -Index 2 -Yes      # no prompts; used by the self-test
#>
[CmdletBinding()]
param(
    [string]$Slot,
    [int]   $Last = 30,
    [string]$VaultPath,
    [string]$SavePath,
    [int]   $Index,      # pick this entry instead of asking
    [string]$ToSlot,     # put it in a different slot: 0, 1, 2, 3 ... or 'auto'
    [switch]$Yes         # skip the confirmation prompt
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$cfg = Read-SeedVaultConfig
if (-not $VaultPath) {
    if (-not $cfg) { throw "Not set up yet. Run Setup.cmd first." }
    $VaultPath = $cfg.ArchivePath
}
if (-not $SavePath) {
    if (-not $cfg) { throw "Not set up yet. Run Setup.cmd first." }
    # The first watched folder is the live save folder; the rest are the game's backups.
    $SavePath = @($cfg.SourcePaths)[0]
}

function Get-SlotName {
    param([string]$FileName)
    # Our naming:            <slot>__2026-08-27_08-30-57[_2].sav
    if ($FileName -match '^(.*?)__\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(_\d+)?\.[^.]+$') { return $Matches[1] }
    # The game's own naming: <slot>_2026-08-27_08_16_21[_2].sav
    if ($FileName -match '^(.*?)_\d{4}-\d{2}-\d{2}_\d{2}_\d{2}_\d{2}(_\d+)?\.[^.]+$')  { return $Matches[1] }
    return [System.IO.Path]::GetFileNameWithoutExtension($FileName)
}

<#
    Split "76561197961167679_AutoSave_0" into its profile id and its slot designator.
    Autosave has to be checked first, or the trailing digit of "AutoSave_0" would be
    mistaken for the slot number.
#>
function Split-SlotName {
    param([string]$SlotName)
    if ($SlotName -match '^(.*)_(AutoSave_\d+)$') { return @{ Profile = $Matches[1]; Designator = $Matches[2] } }
    if ($SlotName -match '^(.*)_(\d+)$')          { return @{ Profile = $Matches[1]; Designator = $Matches[2] } }
    return @{ Profile = $SlotName; Designator = '' }
}

# Accept "2", "slot 2", "auto", "autosave" and so on.
function Resolve-SlotDesignator {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -match '^(?i)a(uto)?(save)?(_?\d+)?$') {
        if ($t -match '(\d+)$') { return "AutoSave_$($Matches[1])" }
        return 'AutoSave_0'
    }
    if ($t -match '(\d+)\s*$') { return $Matches[1] }
    return $null
}

# Show what is in each slot right now, so picking a target is an informed choice.
function Show-CurrentSlots {
    param([string]$SavePath, [string]$Profile)
    $live = @(Get-ChildItem -LiteralPath $SavePath -Filter '*.sav' -File -ErrorAction SilentlyContinue)
    Write-Host ''
    Write-Host "  Slots in use right now:" -ForegroundColor Cyan
    if ($live.Count -eq 0) { Write-Host "    (none)" -ForegroundColor DarkGray; return }
    foreach ($l in ($live | Sort-Object Name)) {
        $d = (Split-SlotName ([System.IO.Path]::GetFileNameWithoutExtension($l.Name))).Designator
        Write-Host ("    slot {0,-12} {1,9}   last saved {2}" -f $d, (Format-Size $l.Length), $l.LastWriteTime)
    }
}

Write-Banner 'Restore'

# Restoring underneath a running game means the game overwrites it moments later.
$running = @(Get-Process -ErrorAction SilentlyContinue |
             Where-Object { $_.ProcessName -match 'Voyage|Caretaker' })
if ($running.Count -gt 0 -and -not $Yes) {
    Write-Host "  The game appears to be running." -ForegroundColor Red
    Write-Host "  Close it first, or it will overwrite whatever you restore." -ForegroundColor Red
    Write-Host ''
    $go = Read-Host "  Type CONTINUE to restore anyway, or press Enter to stop"
    if ($go -ne 'CONTINUE') { Write-Host '  Stopped. Nothing was changed.'; return }
}

if (-not (Test-Path -LiteralPath $VaultPath)) { throw "Vault not found: $VaultPath" }

$all = @(Get-ChildItem -LiteralPath $VaultPath -Recurse -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Extension -eq '.sav' } |
         Sort-Object LastWriteTime -Descending)

if ($Slot) { $all = @($all | Where-Object { (Get-SlotName $_.Name) -like "*$Slot*" }) }

if ($all.Count -eq 0) {
    Write-Host "  Nothing in the vault yet." -ForegroundColor Yellow
    if ($Slot) { Write-Host "  (Filtering on '$Slot' - try without -Slot.)" -ForegroundColor Gray }
    return
}

$shown = @($all | Select-Object -First $Last)

Write-Host "  Saves in the vault, newest first:" -ForegroundColor Cyan
Write-Host ''
Write-Host '     #   When                    Size      Slot' -ForegroundColor DarkGray
Write-Host '   ---   -------------------   --------   ----------------' -ForegroundColor DarkGray
for ($i = 0; $i -lt $shown.Count; $i++) {
    $f = $shown[$i]
    Write-Host ("   {0,3}   {1}   {2,8}   {3}" -f ($i + 1),
        $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv),
        (Format-Size $f.Length),
        (Get-SlotName $f.Name))
}
if ($all.Count -gt $shown.Count) {
    Write-Host ''
    Write-Host "   ... and $($all.Count - $shown.Count) older. Use -Last $($all.Count) to see them all." -ForegroundColor DarkGray
}

Write-Host ''
$idx = 0
if ($Index -gt 0) {
    $idx = $Index
    if ($idx -gt $shown.Count) {
        Write-Host "  There is no entry number $idx (only $($shown.Count) listed)." -ForegroundColor Red
        return
    }
    Write-Host "  Restoring entry $idx (chosen with -Index)." -ForegroundColor Cyan
} else {
    $pick = Read-Host "  Restore which number? (Enter to cancel)"
    if ([string]::IsNullOrWhiteSpace($pick)) { Write-Host '  Cancelled.'; return }
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $shown.Count) {
        Write-Host "  '$pick' isn't one of the numbers listed." -ForegroundColor Red
        return
    }
}

$chosen   = $shown[$idx - 1]
$slotName = Get-SlotName $chosen.Name
$parts    = Split-SlotName $slotName
$fromSlot = $parts.Designator

# ---- which slot should it go into? ----

$targetSlot = $fromSlot
if ($PSBoundParameters.ContainsKey('ToSlot') -and $ToSlot) {
    $targetSlot = Resolve-SlotDesignator $ToSlot
    if (-not $targetSlot) { Write-Host "  '$ToSlot' is not a slot I understand." -ForegroundColor Red; return }
} elseif (-not $Yes) {
    Write-Host ''
    Write-Host "  This save came from slot '$fromSlot'." -ForegroundColor Cyan
    Show-CurrentSlots -SavePath $SavePath -Profile $parts.Profile
    Write-Host ''
    Write-Host "  Press Enter to put it back in slot '$fromSlot', or type another slot" -ForegroundColor Gray
    Write-Host "  (a number like 0, 1, 2, 3 - or 'auto' for the autosave slot)." -ForegroundColor Gray
    $answer = Read-Host "  Slot"
    if (-not [string]::IsNullOrWhiteSpace($answer)) {
        $resolved = Resolve-SlotDesignator $answer
        if (-not $resolved) { Write-Host "  '$answer' is not a slot I understand. Nothing was changed." -ForegroundColor Red; return }
        $targetSlot = $resolved
    }
}

$target = Join-Path $SavePath ("$($parts.Profile)_$targetSlot" + $chosen.Extension)

Write-Host ''
Write-Host "   Restoring : $($chosen.Name)" -ForegroundColor Green
Write-Host "   From      : $($chosen.LastWriteTime)" -ForegroundColor Green
Write-Host "   Into slot : $targetSlot$(if ($targetSlot -ne $fromSlot) { "   (originally slot $fromSlot)" })" -ForegroundColor Yellow
Write-Host "   File      : $target" -ForegroundColor DarkGray
if (Test-Path -LiteralPath $target) {
    $cur = Get-Item -LiteralPath $target
    Write-Host "   Replacing : $(Format-Size $cur.Length) from $($cur.LastWriteTime)" -ForegroundColor Yellow
    Write-Host "               (this will be kept in the vault, not lost)" -ForegroundColor DarkGray
}

if ($targetSlot -ne $fromSlot) {
    Write-Host ''
    Write-Host "   Heads up: a save records inside itself which slot it belongs to, and" -ForegroundColor Yellow
    Write-Host "   that stays saying '$fromSlot'. The game will load it from slot $targetSlot fine," -ForegroundColor Yellow
    Write-Host "   but if it uses that internal value when saving, your next save could" -ForegroundColor Yellow
    Write-Host "   land back in slot $fromSlot. After loading, save once and check which slot" -ForegroundColor Yellow
    Write-Host "   actually changed. Nothing can be lost either way - it is all in the vault." -ForegroundColor Yellow
}
if ($targetSlot -like 'AutoSave*') {
    Write-Host ''
    Write-Host "   Note: the game overwrites the autosave slot on its own schedule, so a" -ForegroundColor Yellow
    Write-Host "   save restored there may not survive long. A numbered slot is safer." -ForegroundColor Yellow
}
# The moment this actually bites is right here, so mention it here rather than only
# in a README the user reads after a restore has already reverted on them.
if (Test-SteamCloudSaves -SourcePaths @($SavePath)) {
    Write-Host ''
    Show-SteamCloudAdvice -Short
}
Write-Host ''
if (-not $Yes) {
    $confirm = Read-Host "  Type YES to go ahead"
    if ($confirm -ne 'YES') { Write-Host '  Cancelled. Nothing was changed.'; return }
}

# Never destroy the present to recover the past.
if (Test-Path -LiteralPath $target) {
    $cur       = Get-Item -LiteralPath $target
    $safetyDir = Join-Path $VaultPath ('_before-restore\' + (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss', $script:Inv))
    New-Item -ItemType Directory -Path $safetyDir -Force | Out-Null
    Copy-Item -LiteralPath $target -Destination (Join-Path $safetyDir $cur.Name)
    Write-Host ''
    Write-Host "  Your current save was kept here:" -ForegroundColor Cyan
    Write-Host "    $safetyDir" -ForegroundColor Cyan
}

Copy-Item -LiteralPath $chosen.FullName -Destination $target -Force

# Vault files are read-only, and Copy-Item carries that flag across. A read-only save
# would stop the game writing to that slot.
$restored = Get-Item -LiteralPath $target
if ($restored.IsReadOnly) { $restored.IsReadOnly = $false }
$restored.LastWriteTime = $chosen.LastWriteTime

Write-Host ''
Write-Host "  Done. Start the game and load slot $targetSlot." -ForegroundColor Green
if ($targetSlot -ne $fromSlot) {
    Write-Host "  Remember to check which slot your next in-game save writes to." -ForegroundColor Yellow
}
Write-Host ''
