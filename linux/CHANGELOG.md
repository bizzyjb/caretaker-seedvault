# Changelog — Linux edition

Both editions share one version number, so 1.2.1 here and 1.2.1 there are the same
feature set on two platforms. See the top-level `CHANGELOG.md` for the history of the
features themselves.

## 1.2.1 — the game moved the saves

The Last Caretaker update of 31 August 2026 changed where it saves on Linux, from
`SaveGames/<SteamID>/<SteamID>_0.sav` to `SaveGames/LocalSteamUser/VoyageSaveGame_0.sav`.
Three things in 1.2.0 handled that badly, all now fixed.

- **The monitor followed the old folder into oblivion.** The folder chosen at setup was
  the only one ever watched, and after the update it still existed and still held the old
  saves — so nothing errored, nothing looked wrong, and nothing was being backed up. Every
  profile folder alongside the watched one is now watched too, rechecked as the monitor
  runs, so a folder the game invents mid-session is picked up within about five minutes
  and logged when it happens. No need to re-run setup, and the next rename is covered in
  advance.
- **Restores used the old file name.** A save archived as `<SteamID>_3.sav` was written
  back under that name, into a folder where the game only looks for `VoyageSaveGame_3.sav`
  — it landed in exactly the right place and the slot still showed up empty. A restore now
  takes its name from the saves that are actually in the folder, and says so when it
  renames. It also restores into the folder the game is writing to now, not the one setup
  happened to pick.
- **`status` now says when the game has moved**, and lists every folder being watched
  rather than only the configured one.

Two bugs found while fixing the above, both present in 1.2.0:

- **Setting up with a path you typed in watched nothing at all.** The path was validated
  in a subshell, so the result never made it back out and the config was written with no
  folders in it. This affected `--save-path` and the "paste a path" fallback — the exact
  route anyone takes when auto-detection misses.
- **A profile folder with no matching `SaveGameBackups` folder shifted setup's other
  fields along by one**, showing a save count as the folder name and writing a nonsense
  `SourcePath=1` into the config. Harmless before the update, because every profile had a
  backup folder; the new `LocalSteamUser` folder does not, so it triggered on any fresh
  install after the update.

Three new self-test checks cover the rename, and two cover the bugs above — 22 in total.

## 1.2.0 — first Linux release

Feature parity with the Windows edition as of 1.1.2, as one self-contained Bash script. It needs
`bash` 4+ and coreutils and nothing else — no Python, no interpreter version to match,
no packages to install, and no root.

**Finding your saves.** The game is Windows-only, so on Linux it lives inside a Proton
prefix. Detection covers the normal Steam layout (`~/.local/share/Steam`, which is what
Bazzite and SteamOS use), Flatpak Steam, the Debian/Ubuntu and Snap packages, and every
extra library listed in `libraryfolders.vdf` — so a game installed on a second drive or a
Steam Deck SD card is found too. Wine, Lutris, Heroic and Bottles prefixes are covered as
well. If none of that hits, it offers to search your home directory, and you can always
paste a path in yourself.

Detection matches on the `Voyage/Saved/SaveGames` path rather than on the Steam AppID, so
it keeps working if the AppID ever changes and it finds non-Steam installs for free.

**Starting automatically.** Installs as a *systemd user service*, which is what makes it
run in Steam Deck Game Mode and not just Desktop Mode. `Restart=always` replaces the
Windows build's scheduled-task self-heal: if the monitor ever dies it is back within
fifteen seconds. Where there is no systemd user session it falls back to a desktop
autostart entry, and says which one it used. Everything installs under `$HOME`, so an
immutable root filesystem — Bazzite, SteamOS — changes nothing.

**Waiting for a save to finish being written.** Windows can be asked to refuse a read
while a file is being written; Linux cannot, so that check is replaced with two others.
A save must look unchanged across consecutive polls, and the kernel is asked directly,
through `/proc/<pid>/fdinfo`, whether the game still has that file open *for writing* —
checking the access mode rather than mere openness, since a save the game keeps open
read-only would otherwise look busy forever. That wait is capped at about two minutes:
never archiving would be far worse than a copy the post-copy re-verification would catch
and retry anyway.

**Never overwriting a vault file.** The copy is committed by hard-linking it into place,
which fails outright if the name is already taken — where `mv` would silently clobber and
`mv -n` would fail without saying so. Vault files are then set to mode `444`.

**One monitor per vault.** An advisory lock (`flock`, with an atomic-`mkdir` fallback that
detects a dead holder) is taken on the vault rather than on the program, so two monitors
cannot race on the same temporary file. A second monitor for the same vault exits with
status 2 and says why; the systemd unit knows not to treat that as a crash worth
restarting.

**Configuration** is plain `KEY=VALUE` at `~/.config/caretaker-seedvault/config` rather
than JSON, so there is no `jq` dependency. It is parsed key by key rather than sourced, so
a stray line in the file cannot execute anything.

**Self-test** covers 16 checks, three more than the Windows edition: that a name already
present in the vault is never written over, that the save is stored alongside it instead,
and that a second monitor refuses to share a vault. Run it with
`caretaker-seedvault status --self-test`; it only ever touches throwaway files in a
temporary directory.

Verified on Ubuntu 24.04 as both root and an unprivileged user, against a real
`systemd --user` session (including killing the monitor and watching it come back), and
against synthetic Proton, Flatpak-Steam and second-library installs. Clean under
`shellcheck -S warning`.
