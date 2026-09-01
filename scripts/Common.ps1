<#
    Caretaker SeedVault - shared helpers.
    Dot-sourced by the other scripts; not meant to be run directly.
#>

$script:AppName    = 'Caretaker SeedVault'
$script:AppSlug    = 'CaretakerSeedVault'
$script:AppVersion = '1.2.1'
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

<#
    Splitting a save file name into the part that names the profile and the part that
    names the slot. Both live here rather than in Restore-Save.ps1 because working out
    what the game currently calls its saves needs them too.
#>
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

<#
    The game does not necessarily keep writing to the profile folder it used on the day
    you set this up. Its update of 31 August 2026 moved the saves on Linux from
    SaveGames\<SteamID>\<SteamID>_0.sav to SaveGames\LocalSteamUser\VoyageSaveGame_0.sav,
    and left the old folder behind, still holding the old saves. Nothing errors and
    nothing goes missing, so a monitor pinned to the folder named in its config carries on
    watching a folder the game has stopped writing to - silence being the worst way for a
    backup tool to fail.

    Windows still uses the Steam ID form. Doing this here anyway costs one directory
    listing per poll and means the same change arriving on Windows is a non-event: every
    sibling profile folder under the same SaveGames / SaveGameBackups parent is watched
    too, so both names are covered whichever way round a rename goes.
#>
function Test-DirHasSaves {
    param([string]$Path, [string]$Pattern = '*.sav')
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    return @(Get-ChildItem -LiteralPath $Path -Filter $Pattern -File -ErrorAction SilentlyContinue).Count -gt 0
}

# The full watch list: the configured folders first, then any sibling profile folder that
# holds saves. No duplicates.
function Get-ExpandedSourcePaths {
    param([string[]]$SourcePaths, [string]$Pattern = '*.sav')

    $out  = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($s in @($SourcePaths)) {
        if ($s -and $seen.Add($s)) { $out.Add($s) }
    }
    foreach ($s in @($SourcePaths)) {
        if (-not $s) { continue }
        $parent = Split-Path $s -Parent
        if (-not $parent) { continue }
        # A folder typed in by hand from somewhere else has no siblings worth guessing at;
        # only the game's own layout is predictable.
        if ((Split-Path $parent -Leaf) -notin @('SaveGames', 'SaveGameBackups')) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-DirHasSaves $d.FullName $Pattern)) { continue }
            if ($seen.Add($d.FullName)) { $out.Add($d.FullName) }
        }
    }
    return @($out)
}

# A folder name that is nothing but digits is a Steam ID, and a Steam ID means a person.
function Test-SteamIdName {
    param([string]$Name)
    return ($Name -match '^\d+$')
}

<#
    Which folder a restore should be written into. Not quite the same question as "where
    is the newest save", and the difference matters.

    The folder chosen at setup wins by default. Two Steam accounts on one machine means
    two profile folders side by side, and following whichever was played last would drop
    a restored save into the other person's game. Watching both is harmless - a spare
    copy costs disk and nothing else - but writing into the wrong one is not.

    It gives way only when it has plainly been left behind: it is gone, or it holds no
    saves at all, or another folder holds newer saves *and* the two names are not both
    Steam IDs. Two all-digit names are two accounts. Digits giving way to a name is the
    game changing its own scheme - and nothing here knows or cares what that name is, so
    a different one next time is handled the same way.

    The game's own backup ring is never a candidate; restoring into it would achieve
    nothing. With no configured folder given, this is just "newest save wins".
#>
function Get-ActiveSavePath {
    param([string[]]$SourcePaths, [string]$Configured)

    $best     = $null
    $bestTime = [datetime]::MinValue
    $confTime = $null

    foreach ($p in (Get-ExpandedSourcePaths -SourcePaths $SourcePaths)) {
        if ((Split-Path (Split-Path $p -Parent) -Leaf) -eq 'SaveGameBackups') { continue }
        $newest = Get-ChildItem -LiteralPath $p -Filter '*.sav' -File -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $newest) { continue }
        if ($Configured -and $p -eq $Configured) { $confTime = $newest.LastWriteTime }
        if ($newest.LastWriteTime -gt $bestTime) {
            $bestTime = $newest.LastWriteTime
            $best     = $p
        }
    }

    if (-not $best) { return $null }
    if ($best -eq $Configured) { return $best }

    # The configured folder still holds saves, and the busier one is just another account
    # rather than the game renaming things. Stay where we were put.
    if ($null -ne $confTime -and
        (Test-SteamIdName (Split-Path $Configured -Leaf)) -and
        (Test-SteamIdName (Split-Path $best -Leaf))) {
        return $Configured
    }
    return $best
}

<#
    The name the game currently gives its own saves in a folder - everything before the
    slot designator. Read off the newest save actually sitting in the folder, because the
    folder is the only thing that knows the answer for certain.
#>
function Get-LiveSavePrefix {
    param([string]$SavePath)

    if (-not $SavePath -or -not (Test-Path -LiteralPath $SavePath)) { return $null }
    $newest = Get-ChildItem -LiteralPath $SavePath -Filter '*.sav' -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { return $null }

    $parts = Split-SlotName (Get-SlotName $newest.Name)
    # No slot designator means this is not one of the game's slot files, so its name says
    # nothing about the naming scheme in use.
    if (-not $parts.Designator) { return $null }
    return $parts.Profile
}

# ----------------------------------------------------------------- utility ----

<#
    Find the running monitor process(es).

    Matching on the bare script name is dangerous: any process whose command line merely
    mentions it - the shell that launched Setup, a terminal where the path was typed -
    would match, and Setup would end up killing its own caller. So match the exact
    '-File "<path>"' form the monitor is really launched with, and never match ourselves.
#>
function Get-MonitorProcess {
    param([string]$WatcherPath = (Join-Path (Get-AppDir) 'Watch-Saves.ps1'))
    $marker = '-File "' + $WatcherPath + '"'
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($marker) })
}

<#
    Does this game sync its saves through Steam Cloud?

    Steam drops steam_autocloud.vdf beside the saves. Note that the file STAYS after cloud
    is turned off for the game, so this detects "this game uses Steam Cloud", not "cloud is
    currently enabled" - the advice is worded to suit.
#>
function Test-SteamCloudSaves {
    param([string[]]$SourcePaths)
    foreach ($p in @($SourcePaths)) {
        if ($p -and (Test-Path -LiteralPath (Join-Path $p 'steam_autocloud.vdf'))) { return $true }
    }
    return $false
}

<#
    Guess whether Steam Cloud is still switched on for this game.

    Steam keeps the marker file's timestamp current while it is syncing, so comparing it
    against the newest save is more telling than the file merely existing. If you have
    played since Steam last touched its marker, Steam is probably not syncing this game
    any more.

    Comparing against save activity rather than the clock matters: someone who has not
    played for a week would look "stale" by wall-clock even with cloud fully enabled.

    This is a hint, never a verdict. Wrongly telling someone cloud is off would send them
    straight into the bug this warns about, so an inconclusive read always falls back to
    showing the full advice.
#>
function Get-SteamCloudHint {
    param([string[]]$SourcePaths)

    $marker = $null
    foreach ($p in @($SourcePaths)) {
        if (-not $p) { continue }
        $candidate = Join-Path $p 'steam_autocloud.vdf'
        if (Test-Path -LiteralPath $candidate) { $marker = Get-Item -LiteralPath $candidate; break }
    }
    if (-not $marker) { return [PSCustomObject]@{ Present = $false; Verdict = 'none' } }

    $newest = $null
    foreach ($p in @($SourcePaths)) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $s = Get-ChildItem -LiteralPath $p -Filter '*.sav' -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($s -and (-not $newest -or $s.LastWriteTime -gt $newest.LastWriteTime)) { $newest = $s }
    }

    # A little slack, so a save written moments before Steam synced isn't read as "off".
    $verdict = 'unclear'
    if ($newest) {
        if ($newest.LastWriteTime -gt $marker.LastWriteTime.AddMinutes(15)) { $verdict = 'likely-off' }
        else { $verdict = 'likely-on' }
    }

    [PSCustomObject]@{
        Present        = $true
        Verdict        = $verdict
        MarkerTime     = $marker.LastWriteTime
        NewestSaveTime = $(if ($newest) { $newest.LastWriteTime } else { $null })
    }
}

<#
    Steam Cloud can silently undo a restore, so say so in one place and use it everywhere.
#>
function Show-SteamCloudAdvice {
    param([switch]$Short, $Hint)

    # Softer wording when the evidence suggests it is already dealt with - but never
    # silence: a wrong "you're fine" would walk the user into the exact bug.
    if ($Hint -and $Hint.Verdict -eq 'likely-off') {
        Write-Host ''
        Write-Host "  Steam Cloud: probably already off for this game." -ForegroundColor Green
        Write-Host "    Steam last touched its marker file on $($Hint.MarkerTime.ToString('yyyy-MM-dd HH:mm'))," -ForegroundColor Gray
        Write-Host "    but you have saved since then ($($Hint.NewestSaveTime.ToString('yyyy-MM-dd HH:mm'))), so it does not" -ForegroundColor Gray
        Write-Host "    look like Steam is syncing this game any more. That is a guess, not a fact." -ForegroundColor Gray
        if (-not $Short) {
            Write-Host ''
            Write-Host "    If you would rather be certain: Steam -> Library -> right-click the game" -ForegroundColor DarkGray
            Write-Host "    -> Properties -> General -> 'Keep game saves in the Steam Cloud'." -ForegroundColor DarkGray
        }
        return
    }

    if ($Short) {
        Write-Host "  Reminder: if Steam Cloud is on for this game, it can replace your restored" -ForegroundColor Yellow
        Write-Host "  save when the game next starts. See the README if a restore seems to undo itself." -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host '   Worth doing: turn off Steam Cloud for this game' -ForegroundColor Yellow
    Write-Host '  ------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  This game can sync its saves through Steam Cloud. That works against you" -ForegroundColor Gray
    Write-Host "  when restoring: if Steam decides its cloud copy is newer than the save you" -ForegroundColor Gray
    Write-Host "  just put back, it can overwrite your restored save when the game starts -" -ForegroundColor Gray
    Write-Host "  so the restore looks like it silently failed." -ForegroundColor Gray
    Write-Host ''
    Write-Host "  To turn it off for this one game:" -ForegroundColor White
    Write-Host "    Steam  ->  Library  ->  right-click the game  ->  Properties" -ForegroundColor Cyan
    Write-Host "           ->  General  ->  untick 'Keep game saves in the Steam Cloud'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  You lose nothing by doing this. Your saves stay on this PC and SeedVault" -ForegroundColor Gray
    Write-Host "  keeps its own full history. It only stops Steam syncing THIS game's saves" -ForegroundColor Gray
    Write-Host "  between computers - every other game is unaffected." -ForegroundColor Gray
    Write-Host ''
    if ($Hint -and $Hint.MarkerTime) {
        Write-Host "  (Steam last touched its marker file here on $($Hint.MarkerTime.ToString('yyyy-MM-dd HH:mm')) -" -ForegroundColor DarkGray
        Write-Host "   recent enough that it may still be syncing. Steam leaves that file behind" -ForegroundColor DarkGray
        Write-Host "   even once cloud is off, so this is a hint rather than a reading of your" -ForegroundColor DarkGray
        Write-Host "   actual setting.)" -ForegroundColor DarkGray
    } else {
        Write-Host "  (Steam leaves its marker file behind either way, so this tool cannot tell" -ForegroundColor DarkGray
        Write-Host "   whether you have already turned it off.)" -ForegroundColor DarkGray
    }
}

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
