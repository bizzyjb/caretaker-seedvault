<#
    Caretaker SeedVault - shared helpers.
    Dot-sourced by the other scripts; not meant to be run directly.
#>

$script:AppName    = 'Caretaker SeedVault'
$script:AppSlug    = 'CaretakerSeedVault'
$script:AppVersion = '1.0.1'
$script:TaskName   = 'CaretakerSeedVault'

# Culture-invariant formatting. On a machine with a different locale, culture-aware
# formatting can rewrite date separators and produce unsortable or invalid filenames.
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture

function Get-InstallRoot {
    Join-Path $env:LOCALAPPDATA $script:AppSlug
}

function Get-ConfigPath {
    Join-Path (Get-InstallRoot) 'config.json'
}

function Get-AppDir {
    Join-Path (Get-InstallRoot) 'app'
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

function Write-Banner {
    param([string]$Subtitle)
    Write-Host ''
    Write-Host '  ############################################################' -ForegroundColor DarkCyan
    Write-Host '  #                                                          #' -ForegroundColor DarkCyan
    Write-Host '  #             C A R E T A K E R   S E E D V A U L T        #' -ForegroundColor Cyan
    Write-Host '  #                                                          #' -ForegroundColor DarkCyan
    Write-Host '  #        Every save preserved. Nothing overwritten.        #' -ForegroundColor DarkCyan
    Write-Host '  #                                                          #' -ForegroundColor DarkCyan
    Write-Host '  ############################################################' -ForegroundColor DarkCyan
    if ($Subtitle) {
        Write-Host "  $Subtitle" -ForegroundColor Gray
    }
    Write-Host "  v$script:AppVersion" -ForegroundColor DarkGray
    Write-Host ''
}

# ------------------------------------------------------------------ config ----

function Read-SeedVaultConfig {
    $path = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warning "Config at $path is unreadable: $($_.Exception.Message)"
        return $null
    }
    # ConvertFrom-Json collapses single-element arrays; force them back.
    [PSCustomObject]@{
        Version        = $raw.Version
        SourcePaths    = @($raw.SourcePaths)
        ArchivePath    = $raw.ArchivePath
        PollSeconds    = [int]$raw.PollSeconds
        FilePattern    = $raw.FilePattern
        Dedupe         = [bool]$raw.Dedupe
        ReadOnly       = [bool]$raw.ReadOnly
        MinFreeGB      = [int]$raw.MinFreeGB
        PruneAfterDays = [int]$raw.PruneAfterDays
        InstalledAt    = $raw.InstalledAt
    }
}

function Write-SeedVaultConfig {
    param([Parameter(Mandatory)]$Config)
    $root = Get-InstallRoot
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-ConfigPath) -Encoding UTF8
}

function New-DefaultConfig {
    param([string[]]$SourcePaths, [string]$ArchivePath)
    [PSCustomObject]@{
        Version        = 1
        SourcePaths    = @($SourcePaths)
        ArchivePath    = $ArchivePath
        PollSeconds    = 4
        FilePattern    = '*.sav'
        Dedupe         = $true
        ReadOnly       = $true
        MinFreeGB      = 10
        PruneAfterDays = 0     # 0 = never delete anything
        InstalledAt    = (Get-Date).ToString('o', $script:Inv)
    }
}

# --------------------------------------------------------------- detection ----

<#
    The Last Caretaker stores saves under a folder named "Voyage" - that is the
    game's internal project codename, not a different game. Layout:

        %LOCALAPPDATA%\Voyage\Saved\SaveGames\<SteamID>\*.sav
        %LOCALAPPDATA%\Voyage\Saved\SaveGameBackups\<SteamID>\*.sav

    The second folder is the game's own backup ring - it keeps only a few copies
    per slot and deletes the rest, which is exactly the gap this tool closes.
#>
function Find-CaretakerSaves {
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Voyage\Saved'),
        (Join-Path $env:APPDATA      'Voyage\Saved'),
        (Join-Path $env:USERPROFILE  'Documents\My Games\Voyage\Saved'),
        (Join-Path $env:USERPROFILE  'Saved Games\Voyage\Saved')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $found = @()
    foreach ($root in $roots) {
        $saveRoot = Join-Path $root 'SaveGames'
        if (-not (Test-Path -LiteralPath $saveRoot)) { continue }

        # One subfolder per profile (usually the Steam ID).
        $profiles = @(Get-ChildItem -LiteralPath $saveRoot -Directory -ErrorAction SilentlyContinue)
        if ($profiles.Count -eq 0) { $profiles = @(Get-Item -LiteralPath $saveRoot) }

        foreach ($p in $profiles) {
            $saves = @(Get-ChildItem -LiteralPath $p.FullName -Filter '*.sav' -File -ErrorAction SilentlyContinue)
            if ($saves.Count -eq 0) { continue }

            $sources = @($p.FullName)

            # Pick up the game's own backup ring for the same profile, if present.
            $bakDir = Join-Path (Join-Path $root 'SaveGameBackups') $p.Name
            if (Test-Path -LiteralPath $bakDir) { $sources += $bakDir }

            $latest = ($saves | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            $found += [PSCustomObject]@{
                ProfileId   = $p.Name
                SavePath    = $p.FullName
                BackupPath  = $(if (Test-Path -LiteralPath $bakDir) { $bakDir } else { $null })
                SourcePaths = @($sources)
                SaveCount   = $saves.Count
                TotalBytes  = ($saves | Measure-Object Length -Sum).Sum
                LastPlayed  = $latest.LastWriteTime
            }
        }
    }
    return @($found | Sort-Object LastPlayed -Descending)
}

<#
    Validate a folder the user typed in, and opportunistically pair it with a
    sibling SaveGameBackups folder so manual entry gets the same coverage as
    auto-detection.
#>
function Resolve-ManualSavePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $Path = $Path.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  That folder does not exist." -ForegroundColor Red
        return $null
    }
    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer) {
        Write-Host "  That is a file, not a folder. Enter the folder that contains your .sav files." -ForegroundColor Red
        return $null
    }

    $saves = @(Get-ChildItem -LiteralPath $Path -Filter '*.sav' -File -ErrorAction SilentlyContinue)
    if ($saves.Count -eq 0) {
        Write-Host "  No .sav files in that folder." -ForegroundColor Yellow
        $anyway = Read-Host "  Use it anyway? (y/N)"
        if ($anyway -notmatch '^[Yy]') { return $null }
    }

    $sources = @($Path)

    # .../Saved/SaveGames/<id>  ->  .../Saved/SaveGameBackups/<id>
    $profileName = Split-Path $Path -Leaf
    $savesParent = Split-Path $Path -Parent
    if ((Split-Path $savesParent -Leaf) -eq 'SaveGames') {
        $sibling = Join-Path (Join-Path (Split-Path $savesParent -Parent) 'SaveGameBackups') $profileName
        if (Test-Path -LiteralPath $sibling) {
            $sources += $sibling
            Write-Host "  Also found the game's own backup folder - it will be watched too." -ForegroundColor Green
        }
    }

    return [PSCustomObject]@{
        ProfileId   = $profileName
        SavePath    = $Path
        SourcePaths = @($sources)
        SaveCount   = $saves.Count
        TotalBytes  = ($saves | Measure-Object Length -Sum).Sum
    }
}

# ----------------------------------------------------------------- utility ----

function Test-IsCloudSyncedPath {
    param([string]$Path)
    # 20MB saves landing in a synced folder every few minutes is a bad time.
    $markers = @('OneDrive', 'Dropbox', 'Google Drive', 'iCloudDrive')
    foreach ($m in $markers) { if ($Path -like "*$m*") { return $m } }
    return $null
}

function Get-DriveFreeBytes {
    param([string]$Path)
    try {
        $qualifier = (Split-Path $Path -Qualifier) -replace ':', ''
        return (Get-PSDrive -Name $qualifier -ErrorAction Stop).Free
    } catch {
        return $null
    }
}
