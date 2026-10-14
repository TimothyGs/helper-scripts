# helper-scripts
Some scripts to make my life easier. Vibe coded with Claude Opus 5.5 Extra

## steamos-easyeffects

Simple systemd config and Xvfb helper script to launch easyeffects in headless mode in gamescope-session providing me my sweet nectarine of equalized audio (hehe). 
Requirements is that you have easy effects installed of course


### How to use
Easy to install, just clone the repo and run

`install -m 644 easyeffects-gamescope.service ~/.config/systemd/user/`
`sudo install -m 755 easyeffects-xvfb /usr/local/bin/easyeffects-xvfb`

then

`systemctl --user daemon-reload`
`systemctl --user start easyeffects-gamescope.service`

## consolidate-steam-libraries

Three helper scripts that can assist you when you want to symlink all your secondary and tertiary drive saves from Steam into your main folder. 
Also makes it easier to back up with Ludusavi.

### Scripts

| Script                    | Purpose                                                                  |
| ------------------------- | ------------------------------------------------------------------------ |
| `consolidate-prefixes.sh` | One-time: merge all library prefixes into the main folder, link libraries |
| `switch-prefix.sh`        | Afterwards: change which copy of one game's prefix is active             |
| `rollback-prefixes.sh`    | Restore the exact state from before the consolidation                    |

All three support `DRY_RUN=1`, refuse to run while Steam is running, and never delete anything.

### Configuration

Edit `LIBS` at the top of `consolidate-prefixes.sh`. Each entry is `label=path`, where the path is the library's `path` value from `~/.local/share/Steam/steamapps/libraryfolders.vdf` plus `/steamapps`, and the label is used to name backups:

```bash
LIBS=(
  "games=/mnt/games/SteamLibrary/steamapps"
  "general_storage=/mnt/general_storage/SteamLibrary/steamapps"
)
```

The other two scripts read the library list from the manifest, so they need no configuration.

## Usage

The examples use `env VAR=value ./script`, which works in both bash and fish.

### 1. Consolidate

Quit Steam completely and take a Ludusavi backup first. Then preview:

```sh
env DRY_RUN=1 ./consolidate-prefixes.sh | grep -v '\[dry\]'
```

Every game is listed as either *only in library* (copied to main) or *conflict* (a prefix exists in more than one place). For each conflict, the output shows the game name and the newest save file on each side, plus the decision:

```
  3751260 (The Blood of Dawnwalker): conflict
      main (main)      2026-10-10 00:03  AppData/Local/Dawnwalker/Saved/...
      general_storage  2026-10-10 00:00  AppData/Local/Dawnwalker/Saved/...
      -> keeping main copy (newer or equal), general_storage copy stays in compatdata.old
```

**How conflicts are decided:** the copy with the most recently modified save file wins. Files that change without the game saving are ignored: Steam Cloud markers (`steam_autocloud.vdf`), logs, crash dumps, `.ini` / `Config/` files, shader caches, temp folders, and NVIDIA / Epic / Microsoft runtime folders.

If a decision is wrong, force a side per game (space-separated app IDs):

```sh
env FORCE_LIBRARY="3751260" DRY_RUN=1 ./consolidate-prefixes.sh | grep -v '\[dry\]'
env FORCE_LIBRARY="3751260" ./consolidate-prefixes.sh
```

`FORCE_MAIN` works the other way around.

A real run first writes a manifest to `~/prefix-consolidation/<timestamp>/` (override with `MANIFEST_ROOT`), then copies, verifies and links. Rerunning once all libraries are linked does nothing; use `switch-prefix.sh` instead.

### 2. Fix a single game afterwards

If a game turns out to load the wrong saves, switch its active prefix to another original copy:

```sh
ls ~/prefix-consolidation/
env DRY_RUN=1 ./switch-prefix.sh ~/prefix-consolidation/<timestamp> 3751260 general_storage
./switch-prefix.sh ~/prefix-consolidation/<timestamp> 3751260 general_storage
./switch-prefix.sh ~/prefix-consolidation/<timestamp> 3751260 main
```

The last argument is `main` (the original main-SSD copy) or a library label (that library's original copy). The currently active copy is kept as a backup, so switching back and forth is safe. This only works while the `compatdata.old` folders and `.bak-*` backups still exist.

Tip: check a game's load menu before playing. If it shows the wrong save, quit without saving, so neither a new save nor a cloud upload lands on top.

### 3. Roll back

```sh
env DRY_RUN=1 ./rollback-prefixes.sh ~/prefix-consolidation/<timestamp>
./rollback-prefixes.sh ~/prefix-consolidation/<timestamp>
```

This undoes every recorded action in reverse (including switches), then checks every restored prefix against the fingerprint taken before the consolidation. Copies from the consolidated state, including any progress made since, are moved to `~/.local/share/Steam/steamapps/compatdata-rollback-<timestamp>/` rather than deleted. If anything the rollback needs is missing, it stops before changing anything.

## Safety

- **Nothing is deleted.** Original library folders are kept as `compatdata.old`; displaced copies in main are kept as `<appid>.bak-<origin>` (`.bak-main`, `.bak-games`, ...).
- **Every copy is verified** against its source with a content fingerprint (SHA-256 over the prefix's user folder and registry files). On a mismatch the script stops before linking and points to the rollback.
- **Manifest** (`~/prefix-consolidation/<timestamp>/`):

  | File                   | Contents                                                        |
  | ---------------------- | --------------------------------------------------------------- |
  | `inventory-before.tsv` | Every prefix before any change: location, game, newest save, size, fingerprint |
  | `actions.tsv`          | Every change, in order (consolidation and later switches)       |
  | `libraries.tsv`        | Library labels and paths                                        |
  | `config.env`           | Main Steam paths                                                |
  | `log.txt`              | Full output of the run                                          |

## Cleanup

Once every conflicted game has been launched and shows the right saves:

```sh
rm -r /mnt/games/SteamLibrary/steamapps/compatdata.old
rm -r /mnt/general_storage/SteamLibrary/steamapps/compatdata.old
rm -r ~/.local/share/Steam/steamapps/compatdata/*.bak-*
```

After cleanup, neither `switch-prefix.sh` nor `rollback-prefixes.sh` can restore the removed copies. Keep the manifest folder; it's small.

To check that a library is still linked:

```sh
ls -l /mnt/games/SteamLibrary/steamapps/compatdata
# compatdata -> /home/<user>/.local/share/Steam/steamapps/compatdata
```

## References

- [GE-Proton9-3 release notes](https://github.com/GloriousEggroll/proton-ge-custom/releases/tag/GE-Proton9-3): documents the `-steamdeck` prefix location change in gamescope sessions
- [Valve Proton wiki: Using a NTFS disk with Linux and Windows](https://github.com/ValveSoftware/Proton/wiki/Using-a-NTFS-disk-with-Linux-and-Windows): the same `compatdata` symlink approach
- [CachyOS forum: shared Steam library](https://discuss.cachyos.org/t/how-to-set-up-shared-steam-library-between-users/17814): symlinking a library's `compatdata` to the home folder
- [Ludusavi docs: Roots](https://github.com/mtkennerly/ludusavi/blob/master/docs/help/roots.md)
