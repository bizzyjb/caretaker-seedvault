# Changelog

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
