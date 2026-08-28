# Changelog

## 1.2.0

- **There is now a Linux edition**, in `linux/`, at feature parity with the Windows one.
  It is a single self-contained Bash script needing only bash 4+ and coreutils — no
  Python, no interpreter version to match, no packages, no root. It works on Bazzite and
  the Steam Deck, where everything it installs stays under `$HOME` so the immutable root
  filesystem is never in the way.
- It finds saves inside the Proton prefix rather than assuming a path: the normal Steam
  layout, Flatpak Steam, the Debian and Snap packages, every extra library listed in
  `libraryfolders.vdf` (so a second drive or a Deck SD card is covered), and Wine, Lutris,
  Heroic and Bottles prefixes. The Steam AppID is not pinned, so detection survives it
  changing. Failing all that it offers to search your home folder, or you can paste a path.
- Autostart is a systemd *user* service, which is what makes it run in Steam Deck Game
  Mode rather than only in Desktop Mode, and `Restart=always` replaces the Windows
  scheduled-task self-heal.
- Two guarantees had to be rebuilt rather than ported. Windows can ask the filesystem to
  refuse a read while a file is being written; Linux has no mandatory locking, so instead
  the kernel is asked through `/proc/<pid>/fdinfo` whether the game still holds the save
  open *for writing* — access mode, not mere openness, since a save held read-only would
  otherwise look busy forever. And the never-overwrite rule is enforced by hard-linking
  the copy into place, which fails outright on a taken name where `mv` would clobber.
- Self-test covers 16 checks there, three more than the Windows edition: that an existing
  vault file is never written over, that the save is stored alongside it instead, and that
  a second monitor refuses to share a vault.
- The Windows edition is unchanged in this release apart from the version number, so both
  editions report the same version.

## 1.1.2

- **The Steam Cloud warning now checks whether you have already dealt with it.** Steam keeps
  its marker file's timestamp current while it is syncing, so the tool compares that against
  your newest save: if you have played since Steam last touched the marker, Steam probably
  is not syncing this game any more and the warning quietens down to a one-line note.
- Comparing against save activity rather than the clock is deliberate — looking for a merely
  "old" file would tell anyone who had not played for a week that cloud was off when it was not.
- The guess is biased toward nagging. It never says "you're fine" on weak evidence, because
  a false all-clear sends the user straight into the bug the warning exists for. It errs
  cautious right after you change the setting, and on a fresh install with no save history.

## 1.1.1

- **Setup now warns about Steam Cloud, and says how to turn it off.** Steam can overwrite a
  restored save when the game next starts, if it decides its cloud copy is newer — so a
  restore appears to silently fail. Setup detects that the game uses Steam Cloud and
  recommends disabling it for that one game, explaining that nothing is lost by doing so.
- The same reminder appears at restore time, which is the moment it actually matters, and
  the README has a section on it plus a troubleshooting entry for the symptom
  ("I restored an old save but the game loaded my newest one").
- Detection is honest about its limits: Steam leaves its marker file behind after cloud is
  disabled, so the tool can tell the game *uses* Steam Cloud but not whether it is
  currently on. The wording reflects that rather than guessing.

## 1.1.0

- **Restore into any slot you like.** A save goes back to its own slot by default, but you
  can now send it elsewhere — useful for comparing two points in time, or parking an old
  save in a spare slot instead of overwriting the one you are playing. The restore screen
  shows which slots are in use and offers a different target; `-ToSlot` does the same from
  the command line. `auto` targets the autosave slot.
- Note: a save records internally which slot it belongs to, and moving it does not rewrite
  that. The game loads it from the new slot, but if it uses that internal value when
  saving, the next save may land back in the original slot. The restore screen warns about
  this and tells you what to check. Nothing can be lost either way.
- Self-test extended to cover restoring into a different slot (13 checks).

## 1.0.5

- **Upgrading now actually replaces the running monitor.** Setup started the new monitor
  without stopping the old one, so after an upgrade you could end up with two monitors on
  one vault — or, once the vault lock landed in 1.0.3, with the new monitor backing off
  and the *old* code still running, meaning the fix you just installed never took effect.
- **Setup can no longer kill the wrong process.** It identified the monitor by looking for
  the script name anywhere in a process's command line, which could match the very window
  Setup was launched from. It now matches the exact command the monitor is started with,
  and never matches itself.
- **Setup never leaves you unprotected.** The old monitor is stopped as late as possible,
  immediately before its replacement starts, so a failure part-way through can't leave
  nothing watching. Setup now also verifies a monitor is running before reporting success,
  and says so loudly if it isn't.

## 1.0.4

- **Re-running Setup no longer duplicates your vault.** Setup took a fresh snapshot of
  every save each time it ran, including when re-run to upgrade — which is the documented
  upgrade path. On a vault that already had history that was several hundred MB of exact
  duplicates per upgrade, in a tool that never deletes anything. Setup now snapshots only
  when the vault is new, and keeps existing history untouched otherwise.

## 1.0.3

- **Two monitors can no longer write to the same vault.** The internal lock is now keyed
  on the vault folder rather than the app, so a second monitor pointed at a vault already
  being watched backs off instead of running alongside. Previously two monitors (for
  example an older install plus a new one, both aimed at the same folder) would race on
  the same temporary file, and could in principle commit a mixed-content save that still
  passed its length check. A monitor watching a *different* vault is still free to run at
  the same time, which previously was not possible.

## 1.0.2

Important fix for anyone running 1.0.0 or 1.0.1 — **please update.**

- **The monitor no longer shows a console window.** Task Scheduler launching
  `powershell.exe` displayed a console even with `-WindowStyle Hidden`, and closing that
  window silently killed the monitor — protection stopped with no warning. It now starts
  through a windowless launcher, so there is no window to close by accident.
- **Fixed the Startup-folder fallback, which never worked.** The generated launcher script
  had a quoting bug that made it fail with a "Windows Script Host" error dialog. This
  affected machines where scheduled tasks are unavailable.
- **The monitor now restarts itself.** A 15-minute check restarts it if it ever stops, so
  a crash no longer leaves you unprotected until the next logon. Redundant launches exit
  immediately, so the check costs effectively nothing.
- Status now reports whether the monitor is *actually running* rather than reading the
  scheduled task's state, which is misleading by design under the new launcher.
- Uninstall is now best-effort: a step that fails no longer aborts it, and anything left
  behind is reported so you can remove it by hand.

## 1.0.1

- **Self-test now covers restoring, not just backing up.** Five new checks confirm a
  chosen save is put back correctly, the read-only flag is cleared (a read-only save
  would stop the game writing that slot), the save being replaced is kept first, and
  nothing in the vault is destroyed. `Show-Status.ps1 -SelfTest` now runs 11 checks.
- Added `-Index` and `-Yes` to `Restore-Save.ps1` so a restore can be scripted without
  prompts. This is what the self-test uses.

## 1.0.0

First release.

- Watches the game's save folder and its own backup folder, copying every save that gets
  written to a timestamped vault.
- Vault files are never overwritten and never deleted.
- Waits for writes to finish (size and timestamp stable, file unlocked) before copying,
  so partial saves never enter the vault.
- Stages copies through a temporary file and verifies length before committing.
- SHA-256 deduplication, so identical content isn't stored twice.
- Auto-detects The Last Caretaker saves; falls back to asking for a path.
- Interactive setup, restore, status and uninstall — all double-clickable.
- Starts at logon via Scheduled Task, falling back to the Startup folder.
- Built-in self-test that verifies the capture pipeline without touching real saves.
