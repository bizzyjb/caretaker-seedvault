# Changelog

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
