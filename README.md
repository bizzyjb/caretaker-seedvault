# Caretaker SeedVault

**Every save preserved. Nothing overwritten.**

A tiny Windows tool that keeps a timestamped copy of every save *The Last Caretaker*
writes, so you can go back to any moment — not just the last few minutes.

In the game you gather seeds and keep them safe so nothing is lost for good. This does
the same thing for your progress.

### [⬇ Download the latest version](https://github.com/bizzyjb/caretaker-seedvault/releases/latest)

Unzip it, double-click `Setup.cmd`, done. No admin rights, no accounts, nothing to install.

---

## The problem it solves

The game saves into a small set of files and **overwrites them in place**. It does keep
its own backups, but only **a few per slot** — once that limit is reached, the oldest is
deleted to make room.

Autosaves land roughly every 15 minutes, so the autosave history covers **well under an
hour**. If something goes wrong with your world and you don't notice immediately — a
corrupted state, a bad decision, a bug — the save you actually wanted is very likely
already gone by the time you go looking for it.

Caretaker SeedVault removes that ceiling. Every save that gets written is copied
somewhere safe, and **nothing in the vault is ever overwritten or deleted**.

---

## Quick start

1. [Download the latest release](https://github.com/bizzyjb/caretaker-seedvault/releases/latest)
   and **unzip the whole folder**.
2. Double-click **`Setup.cmd`**.
3. Answer two questions: which saves to watch, and where to keep the vault.

That's it. It runs quietly in the background from then on and starts automatically
whenever you log in. No administrator rights needed.

> **Tip:** before unzipping, right-click the `.zip` → **Properties** → tick **Unblock**.
> Windows flags anything downloaded from the internet, and this saves you some prompts.

### Checking it's working

Double-click **`Status.cmd`**. It shows whether the monitor is running, how many saves
it has kept, and how far back you can go.

To prove the whole thing actually works, run a self-test — it uses throwaway files and
never touches your real saves:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Show-Status.ps1 -SelfTest
```

---

## Getting a save back

Double-click **`Restore.cmd`** (or *Start Menu → Caretaker SeedVault → Restore a Save*).

It lists everything in the vault, newest first:

```
     #   When                    Size      Slot
   ---   -------------------   --------   ----------------
     1   2026-03-14 21:04:11    19.0 MB   AutoSave_0
     2   2026-03-14 20:49:07    19.0 MB   AutoSave_0
     3   2026-03-14 20:33:58    19.1 MB   Slot_0
```

Pick a number, confirm, done. **Close the game first** — it warns you if it's still
running, because the game will overwrite whatever you restore the moment it saves again.

Your current save is copied into the vault *before* anything is replaced, so restoring an
old save never costs you the one you have now. If you restore the wrong one, just restore
again.

---

## What ends up in the vault

```
YourVault\
├─ 2026-03-14\                    saves, grouped by day
├─ _snapshot_2026-03-14_18-22-05\ everything that existed when you first set it up
├─ _before-restore\               your live save, kept automatically before each restore
├─ _manifest.csv                  every event: what, when, size, SHA-256 checksum
└─ _log.txt                       plain-English activity log
```

File names carry the time the save was **made**, not the time it was copied:

```
76561198000000000_AutoSave_0__2026-03-14_21-04-11.sav
```

So sorting by name and sorting by date give you the same answer, which is what you want
when you're hunting for "where I was about an hour ago".

### Space

Saves are large — roughly 20 MB each. A long session might produce a few hundred MB.
Nothing is ever pruned by default, which is deliberate: the whole point is that the save
you need is still there. `Status.cmd` shows what it's currently using.

If you're tight on space you can set an age limit — see **Settings** below.

---

## Settings

Setup writes `%LOCALAPPDATA%\CaretakerSeedVault\config.json`:

```json
{
  "SourcePaths":    ["C:\\Users\\You\\AppData\\Local\\Voyage\\Saved\\SaveGames\\7656..."],
  "ArchivePath":    "D:\\CaretakerSeedVault",
  "PollSeconds":    4,
  "FilePattern":    "*.sav",
  "Dedupe":         true,
  "ReadOnly":       true,
  "MinFreeGB":      10,
  "PruneAfterDays": 0
}
```

| Setting | What it does |
|---|---|
| `SourcePaths` | Folders being watched. Add more if you like. |
| `ArchivePath` | Where the vault lives. |
| `PollSeconds` | How often to check. 4 is fine; lower is not meaningfully better. |
| `Dedupe` | Skip saves whose contents are byte-identical to one already stored. |
| `ReadOnly` | Mark vault files read-only so nothing can clobber them by accident. |
| `PruneAfterDays` | `0` means never delete. Set to e.g. `30` to cap growth. |

Edit the file, then re-run `Setup.cmd` (or reboot) to pick up changes.

---

## Uninstalling

Double-click **`Uninstall.cmd`**. It stops the monitor and removes it from startup.

**Your vault is never deleted** — the saves stay exactly where they are. Delete that
folder yourself if you want the space back.

---

## How it works

Deliberately boring, because the job is *not losing data*:

- **Polls** the save folders every few seconds rather than using `FileSystemWatcher`,
  which silently drops events when its buffer overflows and behaves inconsistently with
  apps that write via temp-file-and-rename.
- **Waits for the write to finish.** A save is only copied once its size and timestamp
  are unchanged across two consecutive checks *and* the game is no longer holding a lock
  on it. Saves are tens of megabytes and take real time to land; without this you'd fill
  the vault with truncated files — worse than no backup, because you'd trust them.
- **Copies to a temporary file first**, verifies the length, and only then moves it into
  place. An interrupted copy can never masquerade as a valid save.
- **Re-checks the source after copying.** If the game rewrote the file mid-copy, the copy
  is thrown away and retried.
- **Never writes over an existing file.** Names are timestamped, and if a name is somehow
  taken it adds a suffix instead. There is no code path that overwrites a vault file.
- **Hashes with SHA-256** to avoid storing the same bytes twice. The game copies each
  outgoing save into its own backup folder, so identical content legitimately shows up in
  both watched folders.

It also watches the game's own backup folder. Going forward that's mostly redundant, but
it means saves are still captured during any window where the monitor wasn't running.

---

## FAQ

**Will this slow my game down?**
No. It reads files that are already written and copies them. It does no work at all
between saves.

**Why does it point at a folder called "Voyage"?**
That's the game's internal project codename. Right folder, don't worry.

**Does it need admin rights?**
No. If your machine blocks scheduled tasks, it falls back to the Startup folder
automatically.

**Can I use it for a different game?**
Yes, though it only auto-detects this one. Point `SourcePaths` at any folder and set
`FilePattern` to match. Nothing else is game-specific.

**Is my vault safe from a disk failure?**
Only if you put it on a different drive from your saves — Setup will suggest one if you
have it. It fully protects against the game overwriting saves either way, but a copy on
the same physical disk dies with that disk. Copying the vault to another drive
occasionally is worth doing.

**Something looks wrong.**
Run `Status.cmd`, check `_log.txt` in your vault, and open an issue with what it says.

---

## Requirements

Windows 10 or 11. Uses the PowerShell that ships with Windows — nothing to install.

## License

MIT — see [LICENSE](LICENSE). Use it, change it, pass it on.

## Disclaimer

An unofficial, community-made tool. Not affiliated with, endorsed by, or associated with
the developers or publishers of *The Last Caretaker*. All trademarks are the property of
their respective owners.

It only ever *reads* your save files. The one exception is the restore feature, which
writes a save you explicitly picked back into the game's folder — and it copies your
current save somewhere safe first. As with anything that touches your saves, it comes with
no warranty; see the LICENSE.
