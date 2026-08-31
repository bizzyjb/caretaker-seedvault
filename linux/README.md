# Caretaker SeedVault — Linux edition

**Every save preserved. Nothing overwritten.**

A tiny tool that keeps a timestamped copy of every save *The Last Caretaker* writes, so
you can go back to any moment — not just the last few minutes.

In the game you gather seeds and keep them safe so nothing is lost for good. This does
the same thing for your progress.

Works on any Linux distribution, including **Bazzite** and the **Steam Deck**. It is a
single Bash script — no Python, no packages to install, no root.

### [⬇ Download the latest version](https://github.com/bizzyjb/caretaker-seedvault/releases/latest)

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

```bash
chmod +x caretaker-seedvault
./caretaker-seedvault setup
```

Setup asks two questions — which saves to watch, and where to keep the vault — then
starts protecting them. It installs itself to `~/.local/share/caretaker-seedvault/` and
starts automatically at every login from then on. **No root, and nothing outside your
home directory**, which is what makes it work unchanged on an immutable system like
Bazzite or SteamOS.

**One thing worth doing afterwards: [turn off Steam Cloud for this game](#turn-off-steam-cloud-for-this-game).**
Otherwise Steam can quietly undo your restores. Setup reminds you about this too.

### On the Steam Deck

Run setup from **Desktop Mode** (that is the only place you have a terminal). Once it is
installed it runs in **Game Mode as well** — it is registered as a systemd *user service*,
which starts with your session whichever mode you boot into, rather than as a desktop
autostart entry that would only fire in Desktop Mode.

### Checking it's working

```bash
caretaker-seedvault status
```

It shows whether the monitor is running, how many saves it has kept, and how far back you
can go.

To prove the whole thing actually works, run the self-test — it uses throwaway files in a
temporary folder and never touches your real saves:

```bash
caretaker-seedvault status --self-test
```

It runs 16 checks covering **both halves**: that saves get captured (including that a
vault file is never overwritten, that identical content is not stored twice, and that two
monitors cannot fight over one vault), and that restoring puts the right save back, clears
the read-only flag so the game can still write to it, and keeps the save it replaced. If
that passes on your machine, the tool works on your machine.

---

## Where your saves actually are

The Last Caretaker is a Windows game, so on Linux it runs under Proton and its saves live
inside the compatibility prefix:

```
~/.local/share/Steam/steamapps/compatdata/1783560/pfx/drive_c/users/steamuser/
    AppData/Local/Voyage/Saved/SaveGames/<your-steam-id>/
```

The game update of **31 August 2026** changed that last folder on Linux. Saves now go to
`SaveGames/LocalSteamUser/`, and the files inside are named `VoyageSaveGame_0.sav` rather
than `<your-steam-id>_0.sav`. Nothing needs doing about it: the monitor watches both
folders, notices within about five minutes if the game starts using a new one, and a
restore of a save from before the change is written back under the name the game looks
for now. Your old saves are still in the old folder, untouched, and still in the vault.

On **Flatpak Steam** the same path sits under
`~/.var/app/com.valvesoftware.Steam/.local/share/Steam/…` instead, and if you installed
the game to a second drive or a Deck SD card it will be under that library's folder.

Setup finds all of these for you, including extra Steam libraries listed in
`libraryfolders.vdf`, and Wine, Lutris, Heroic and Bottles prefixes. If it comes up empty
it offers to search your home directory, and you can always paste a path in yourself.

> **Why "Voyage"?** That's the game's internal project codename. Right folder, don't worry.

---

## Turn off Steam Cloud for this game

**Do this if you're on Steam.** The game syncs its saves through Steam Cloud, and that
works directly against restoring: if Steam decides its cloud copy is newer than the save
you just put back, it can overwrite your restored save when the game next starts. The
restore then looks like it silently failed, which is a miserable thing to debug.

> Steam → Library → right-click the game → **Properties** → **General** →
> untick **Keep game saves in the Steam Cloud**

**You lose nothing by doing this.** Your saves stay on your PC, and SeedVault keeps its own
complete history. The only thing it stops is Steam syncing *this game's* saves between
computers — every other game is unaffected.

### How it guesses whether you've already done this

Steam leaves its marker file (`steam_autocloud.vdf`) next to your saves even after you
turn cloud off, so its presence proves nothing on its own. But Steam keeps that file's
timestamp current while it *is* syncing — so the tool compares it against your newest save:

- **You've saved more recently than Steam touched its marker** → Steam probably isn't
  syncing this game any more, so it says the setting looks handled and stays quiet.
- **Otherwise** → it shows the full advice.

Comparing against your save activity rather than the clock matters: if it just looked for
an "old" file, anyone who hadn't played for a week would be told cloud was off when it
wasn't.

It's a hint, never a verdict, and it's biased toward nagging you — telling someone
"you're fine" when they aren't would walk them straight into the bug. Two known cases
where it errs cautious: right after you change the setting (Steam touches the file, so it
reads as active until you next play), and on a brand-new install with no save history.

**Symptom to watch for:** you restore an old save, launch the game, and you're back at
your most recent progress instead. That's Steam Cloud, not a failed restore — your save is
still safe in the vault.

---

## Getting a save back

```bash
caretaker-seedvault restore
```

It lists everything in the vault, newest first:

```
     #   When                    Size      Slot
   ---   -------------------   --------   ----------------
     1   2026-03-14 21:04:11    19.0 MB   AutoSave_0
     2   2026-03-14 20:49:07    19.0 MB   AutoSave_0
     3   2026-03-14 20:33:58    19.1 MB   0
```

Pick a number, confirm, done. **Close the game first** — it warns you if it's still
running, because the game will overwrite whatever you restore the moment it saves again.

Your current save is copied into the vault *before* anything is replaced, so restoring an
old save never costs you the one you have now. If you restore the wrong one, just restore
again.

### Restoring into a different slot

By default a save goes back where it came from. You can also send it somewhere else —
handy for comparing two points in time, or for parking an old save in a spare slot instead
of overwriting the one you're playing.

After you pick a save, it shows which slots are in use and offers to put it elsewhere.
Press Enter to keep the original slot, or type a slot number (or `auto` for the autosave
slot). From the command line:

```bash
caretaker-seedvault restore --index 3 --to-slot 2
```

**One caveat worth knowing.** A save records inside itself which slot it belongs to, and
restoring elsewhere does not rewrite that. The game loads it from the new slot fine, but
if it uses that internal value when saving, your next save may land back in the *original*
slot. After loading a save you've moved, save once and check which slot actually changed.
Nothing can be lost either way — every version is in the vault.

---

## What ends up in the vault

```
YourVault/
├─ 2026-03-14/                    saves, grouped by day
├─ _snapshot_2026-03-14_18-22-05/ everything that existed when you first set it up
├─ _before-restore/               your live save, kept automatically before each restore
├─ _manifest.csv                  every event: what, when, size, SHA-256 checksum
├─ _hashes.tsv                    checksum index, so identical saves aren't stored twice
├─ _lock                          empty; stops two monitors sharing one vault
└─ _log.txt                       plain-English activity log
```

File names carry the time the save was **made**, not the time it was copied:

```
76561198000000000_AutoSave_0__2026-03-14_21-04-11.sav
```

So sorting by name and sorting by date give you the same answer, which is what you want
when you're hunting for "where I was about an hour ago".

Vault files are stored read-only (mode `444`) so nothing can clobber them by accident.

### Space

Saves are large — roughly 20 MB each. A long session might produce a few hundred MB.
Nothing is ever pruned by default, which is deliberate: the whole point is that the save
you need is still there. `caretaker-seedvault status` shows what it's currently using.

If you're tight on space you can set an age limit — see **Settings** below.

---

## Settings

Setup writes `~/.config/caretaker-seedvault/config`. It's plain `KEY=VALUE`, one per line
— no JSON, so there's nothing to install to read or edit it:

```ini
SourcePath=/home/you/.local/share/Steam/steamapps/compatdata/1783560/pfx/drive_c/users/steamuser/AppData/Local/Voyage/Saved/SaveGames/7656...
SourcePath=/home/you/.local/share/Steam/steamapps/compatdata/1783560/pfx/drive_c/users/steamuser/AppData/Local/Voyage/Saved/SaveGameBackups/7656...
ArchivePath=/home/you/CaretakerSeedVault
PollSeconds=4
FilePattern=*.sav
Dedupe=true
ReadOnly=true
MinFreeGB=10
PruneAfterDays=0
```

| Setting | What it does |
|---|---|
| `SourcePath` | A folder to watch. Repeat the line to watch more than one. |
| `ArchivePath` | Where the vault lives. |
| `PollSeconds` | How often to check. 4 is fine; lower is not meaningfully better. |
| `FilePattern` | Which files count as saves. |
| `Dedupe` | Skip saves whose contents are byte-identical to one already stored. |
| `ReadOnly` | Mark vault files read-only so nothing can clobber them by accident. |
| `MinFreeGB` | Warn in the log when the vault drive drops below this. |
| `PruneAfterDays` | `0` means never delete. Set to e.g. `30` to cap growth. |

Edit the file, then:

```bash
caretaker-seedvault restart
```

---

## Everyday commands

```bash
caretaker-seedvault status              # is it running, and what has it kept?
caretaker-seedvault restore             # put an older save back
caretaker-seedvault log 40              # last 40 lines of the vault's activity log
caretaker-seedvault log -f              # follow it live
caretaker-seedvault stop | start | restart
caretaker-seedvault uninstall
```

If `~/.local/bin` isn't on your `PATH`, use the full path
`~/.local/share/caretaker-seedvault/caretaker-seedvault` instead, or add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

---

## Uninstalling

```bash
caretaker-seedvault uninstall
```

It stops the monitor, removes the systemd service, and deletes the installed files.

**Your vault is never deleted** — the saves stay exactly where they are. Delete that
folder yourself if you want the space back.

---

## How it works

Deliberately boring, because the job is *not losing data*:

- **Polls** the save folders every few seconds rather than using inotify, which drops
  events when its queue overflows and behaves inconsistently with apps that write via
  temp-file-and-rename — which is exactly what a game under Proton does.
- **Waits for the write to finish.** A save is only copied once its size and timestamp are
  unchanged across two consecutive checks. Saves are tens of megabytes and take real time
  to land; without this you'd fill the vault with truncated files — worse than no backup,
  because you'd trust them.
- **Asks the kernel whether the game still has the file open for writing**, via
  `/proc/<pid>/fdinfo`, and waits if it does. Linux has no mandatory file locking, so
  unlike on Windows a read mid-write would simply succeed; this check is what replaces
  that. It deliberately looks at the *access mode* rather than mere openness — a save the
  game keeps open read-only would otherwise look busy forever — and it gives up waiting
  after a couple of minutes rather than risk never archiving at all.
- **Copies to a temporary file first**, verifies the length, and only then moves it into
  place. An interrupted copy can never masquerade as a valid save.
- **Re-checks the source after copying.** If the game rewrote the file mid-copy, the copy
  is thrown away and retried.
- **Never writes over an existing file.** Names are timestamped, and the copy is committed
  by *hard-linking* it into place — which fails outright if the name is taken, rather than
  silently clobbering the way `mv` would. If the name is taken it adds a suffix instead.
  There is no code path that overwrites a vault file.
- **Hashes with SHA-256** to avoid storing the same bytes twice. The game copies each
  outgoing save into its own backup folder, so identical content legitimately shows up in
  both watched folders.
- **Takes a lock on the vault**, not on the program. Two monitors writing to one vault
  could race on the same temporary file and commit a mixed-content save that still passed
  its length check — corruption in the one place that must never have any. A second
  monitor for the same vault exits immediately and says so; a monitor for a *different*
  vault is free to run alongside.

It also watches the game's own backup folder. Going forward that's mostly redundant, but
it means saves are still captured during any window where the monitor wasn't running.

---

## FAQ

**Will this slow my game down?**
No. It reads files that are already written and copies them, at `nice 10` with idle I/O
priority. It does no work at all between saves.

**Does it need root?**
No. Everything lives in your home directory: `~/.local/share`, `~/.config`, and whatever
vault folder you choose. That's also why it works on an immutable distro like Bazzite or
SteamOS without touching the read-only root.

**What does it need installed?**
`bash` 4 or newer and standard coreutils — which every distro already has. It's one
script; there's nothing to package, no interpreter version to match, no dependencies to
break on an update.

**Will it survive a SteamOS update?**
Yes. System updates replace the OS image but leave `/home` alone, and everything this
installs lives there.

**Does it work in Game Mode on the Deck?**
Yes, when it installs as a systemd user service — which it does by default. If it had to
fall back to desktop autostart (it says which one it used), that only starts in Desktop
Mode.

**Can I use it for a different game?**
Yes, though it only auto-detects this one. Point `SourcePath` at any folder and set
`FilePattern` to match. Nothing else is game-specific.

**Is my vault safe from a disk failure?**
Only if you put it on a different drive from your saves — setup will suggest one if you
have it. It fully protects against the game overwriting saves either way, but a copy on
the same physical disk dies with that disk. Copying the vault elsewhere occasionally is
worth doing.

**I restored an old save but the game loaded my newest one.**
That's Steam Cloud overwriting the restored file — see
[Turn off Steam Cloud for this game](#turn-off-steam-cloud-for-this-game). Nothing is lost;
your save is still in the vault. Turn cloud off for the game and restore again.

**Something looks wrong.**
Run `caretaker-seedvault status`, check `_log.txt` in your vault (or
`journalctl --user -u caretaker-seedvault -n 50`), and open an issue with what it says.

---

## Requirements

Any Linux distribution with `bash` 4+ and coreutils. `systemd` is used for autostart if
present; if it isn't, it falls back to a desktop autostart entry.

Tested on Ubuntu 24.04 and against a real `systemd --user` session, with and without root,
and against synthetic Proton, Flatpak-Steam and second-library installs.

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
