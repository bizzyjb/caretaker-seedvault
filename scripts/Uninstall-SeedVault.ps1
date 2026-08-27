<#
.SYNOPSIS
    Caretaker SeedVault - turn it off and remove it.

.DESCRIPTION
    Stops the monitor and removes it from startup. Your vault of saved games is left
    exactly where it is - this never deletes your saves.
#>
[CmdletBinding()]
param(
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Write-Banner 'Uninstall'

$cfg = Read-SeedVaultConfig

if ($cfg -and (Test-Path -LiteralPath $cfg.ArchivePath)) {
    $files = @(Get-ChildItem -LiteralPath $cfg.ArchivePath -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -eq '.sav' })
    $bytes = ($files | Measure-Object Length -Sum).Sum
    Write-Host "  Your vault holds $($files.Count) save(s), $(Format-Size $bytes)." -ForegroundColor Cyan
    Write-Host "    $($cfg.ArchivePath)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  This will NOT be deleted. Uninstalling only stops new saves being kept." -ForegroundColor Green
    Write-Host "  Delete that folder yourself if and when you want the space back." -ForegroundColor Gray
    Write-Host ''
}

if (-not $Yes) {
    $go = Read-Host "  Type YES to stop and remove Caretaker SeedVault"
    if ($go -ne 'YES') { Write-Host '  Cancelled - nothing was changed.'; return }
}

# Scheduled task
$task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
if ($task) {
    try {
        if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $script:TaskName }
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
        Write-Host "  Removed the scheduled task." -ForegroundColor Green
    } catch {
        Write-Host "  Could not remove the scheduled task: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Startup-folder fallback
$vbs = Join-Path ([Environment]::GetFolderPath('Startup')) "$($script:AppSlug).vbs"
if (Test-Path -LiteralPath $vbs) {
    Remove-Item -LiteralPath $vbs -Force
    Write-Host "  Removed it from the Startup folder." -ForegroundColor Green
}

# Any monitor still running
$procs = @(Get-MonitorProcess)
foreach ($p in $procs) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "  Stopped the running monitor (PID $($p.ProcessId))." -ForegroundColor Green
}

# Every step below is best-effort. Stopping the monitor is the part that matters; a
# leftover shortcut must never abort the uninstall and leave things half-removed.
$leftovers = @()

# Start Menu shortcuts
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) $script:AppName
if (Test-Path -LiteralPath $menu) {
    try {
        Remove-Item -LiteralPath $menu -Recurse -Force -ErrorAction Stop
        Write-Host "  Removed the Start Menu shortcuts." -ForegroundColor Green
    } catch {
        $leftovers += $menu
        Write-Host "  Could not remove the Start Menu shortcuts." -ForegroundColor Yellow
    }
}

# Installed program files and settings. The vault itself is deliberately untouched.
$root = Get-InstallRoot
if (Test-Path -LiteralPath $root) {
    try {
        # Can't delete the folder holding the script that is currently executing, so
        # hand it to a detached shell that waits for us to exit first.
        $cmd = "ping 127.0.0.1 -n 3 > nul & rmdir /s /q `"$root`""
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -WindowStyle Hidden -ErrorAction Stop
        Write-Host "  Removing installed files from $root" -ForegroundColor Green
    } catch {
        $leftovers += $root
        Write-Host "  Could not remove $root" -ForegroundColor Yellow
    }
}

if ($leftovers.Count -gt 0) {
    Write-Host ''
    Write-Host "  The monitor is stopped and will not start again, but these could not be" -ForegroundColor Yellow
    Write-Host "  deleted automatically. Delete them by hand if you want them gone:" -ForegroundColor Yellow
    foreach ($l in $leftovers) { Write-Host "    $l" -ForegroundColor Yellow }
}

Write-Host ''
Write-Host "  Caretaker SeedVault has been removed." -ForegroundColor Green
if ($cfg) {
    Write-Host "  Your saved games are still safe in:" -ForegroundColor Cyan
    Write-Host "    $($cfg.ArchivePath)" -ForegroundColor Cyan
}
Write-Host ''
