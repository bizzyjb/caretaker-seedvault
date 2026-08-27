# Changelog

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
