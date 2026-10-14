#!/usr/bin/env bash
# consolidate-prefixes.sh
#
# Moves Proton prefixes from secondary Steam libraries into the main Steam
# compatdata folder, then replaces each library's compatdata with a symlink
# to it. Desktop and Game Mode then use the same prefixes.
#
# Conflicts (same game in both places): the copy with the most recently
# modified save file wins, ignoring files that change without the game
# saving (Steam Cloud markers, logs, configs, caches, temp). Force a side per
# game with FORCE_LIBRARY / FORCE_MAIN. Each conflict shows the game name and
# the file that decided it on each side.
#
# Nothing is deleted:
#   - a library's original folder is kept as compatdata.old
#   - a displaced copy is kept as <appid>.bak-<origin> (main, games, ...)
#   - every copy is verified against its source before anything is linked
#
# A real run first writes a manifest to ~/prefix-consolidation/<timestamp>/:
#   inventory-before.tsv  every prefix before any change, with a fingerprint
#   actions.tsv           every change, in order
#   log.txt               the full output
# rollback-prefixes.sh uses it to restore the original state.
#
# Usage:
#   DRY_RUN=1 ./consolidate-prefixes.sh      # show every decision, change nothing
#   ./consolidate-prefixes.sh                # do it
#   FORCE_LIBRARY="3751260" ./consolidate-prefixes.sh
#   FORCE_MAIN="2288340" ./consolidate-prefixes.sh

set -euo pipefail

STEAMAPPS="$HOME/.local/share/Steam/steamapps"
# Main Steam compatdata (where everything ends up)
HCD="$STEAMAPPS/compatdata"

# Secondary libraries as label=steamapps path. The label names backups
# (<appid>.bak-<label>); the path is the "path" value from
# libraryfolders.vdf plus /steamapps.
LIBS=(
  "games=/mnt/games/SteamLibrary/steamapps"
  "general_storage=/mnt/general_storage/SteamLibrary/steamapps"
)

DRY_RUN="${DRY_RUN:-0}"
FORCE_LIBRARY="${FORCE_LIBRARY:-}"
FORCE_MAIN="${FORCE_MAIN:-}"
MANIFEST_ROOT="${MANIFEST_ROOT:-$HOME/prefix-consolidation}"

LIB_PATHS=()
for e in "${LIBS[@]}"; do LIB_PATHS+=("${e#*=}"); done

run() {
  if [ "$DRY_RUN" = 1 ]; then echo "      [dry] $*"; else "$@"; fi
}

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# Files that change without the game saving, ignored when comparing:
# Steam Cloud sync markers, logs, crash dumps, config files, shader caches,
# temp folders and vendor runtime folders
NOISE=(
  -name steam_autocloud.vdf
  -o -iname '*.log' -o -iname '*.log.*' -o -iname '*.dmp' -o -iname '*.mdmp'
  -o -iname '*.ini'
  -o -iname '*pipelinecache*' -o -iname '*shadercache*' -o -iname '*.ushaderprecache'
  -o -ipath '*/Logs/*' -o -ipath '*/Crashes/*' -o -ipath '*/CrashReport*' -o -ipath '*/Config/*'
  -o -ipath '*/Temp/*'
  -o -ipath '*/NVIDIA Corporation/*' -o -ipath '*/Epic Games/*' -o -ipath '*/Microsoft/*' -o -ipath '*/D3DSCache/*'
)

# Newest non-noise file in a prefix's user folder: "<epoch><TAB><path>"
# (path relative to steamuser), or "0<TAB>-" if there are none
newest() {
  local line
  line=$(find "$1/pfx/drive_c/users/steamuser" -type f -not \( "${NOISE[@]}" \) \
           -printf '%T@\t%P\n' 2>/dev/null | sort -n | tail -1) || true
  if [ -z "$line" ]; then
    printf '0\t-\n'
  else
    printf '%s\t%s\n' "${line%%.*}" "${line#*$'\t'}"
  fi
}

# Whether a prefix holds Steam Cloud saves
has_cloud() {
  [ -n "$(find "$1/pfx/drive_c/users/steamuser" -name steam_autocloud.vdf -print -quit 2>/dev/null)" ]
}

# Content fingerprint of a prefix's user folder and registry files
# (everything a save can live in)
fingerprint() (
  set +e +o pipefail
  [ -d "$1/pfx" ] || { echo none; exit 0; }
  cd "$1/pfx" || { echo none; exit 0; }
  { [ -d drive_c/users/steamuser ] && find drive_c/users/steamuser -type f -print0
    find . -maxdepth 1 -type f -name '*.reg' -print0; } 2>/dev/null \
    | sort -z | xargs -0 -r sha256sum | sha256sum | cut -c1-16
)

fmt() {
  if [ "$1" = 0 ]; then echo "no save files   "; else date -d "@$1" '+%F %H:%M'; fi
}

# Game name from its appmanifest, if installed in any library
gname() {
  local f
  for f in "$STEAMAPPS/appmanifest_$1.acf" "${LIB_PATHS[@]/%//appmanifest_$1.acf}"; do
    if [ -f "$f" ]; then
      sed -n 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)"/\1/p' "$f" | head -1
      return
    fi
  done
  echo "not installed"
}

# Backup name by origin: <path>.bak-<origin>, then .1, .2, ... if taken
bakname() {
  local b="$1.bak-$2" n=1
  while [ -e "$b" ]; do b="$1.bak-$2.$n"; n=$((n + 1)); done
  echo "$b"
}

# Record a change in the manifest: action, appid, from, to
logact() {
  [ "$DRY_RUN" = 1 ] || printf '%s\t%s\t%s\t%s\n' "$@" >> "$M/actions.tsv"
}

# One TSV row per prefix in a compatdata folder
inventory() {
  local label=$1 dir=$2 d id t f size fp
  for d in "$dir"/*/; do
    [ -d "$d" ] || continue
    d=${d%/}; id=$(basename "$d")
    case "$id" in *[!0-9]*) continue ;; esac
    IFS=$'\t' read -r t f <<<"$(newest "$d")"
    size=$(du -sk "$d" 2>/dev/null | cut -f1) || size="?"
    fp=$(fingerprint "$d")
    FP["$d"]=$fp
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$label" "$id" "$(gname "$id")" "$(fmt "$t")" "$f" "$size" "$fp" "$d"
  done
}

# Copy a prefix and check the copy matches its source
copy_verified() {
  local id=$1 src=$2 dst=$3 a b
  logact copy "$id" "$src" "$dst"
  run cp -a "$src" "$dst"
  [ "$DRY_RUN" = 1 ] && return
  a=${FP[$src]:-$(fingerprint "$src")}
  b=$(fingerprint "$dst")
  if [ "$a" != "$b" ]; then
    echo "  !! Copy of $id does not match its source ($a vs $b). Stopping here." >&2
    echo "     Undo everything done so far with: ./rollback-prefixes.sh $M" >&2
    exit 1
  fi
  echo "      copied and verified"
}

if pgrep -x steam >/dev/null; then
  echo "Steam is running. Quit it completely first." >&2
  exit 1
fi

declare -A FP=() WIN_T=() WIN_F=() WIN_SRC=()
M=""

# Stop early if every library is already linked
todo=0
for e in "${LIBS[@]}"; do
  lp=${e#*=}
  if [ -d "$lp" ] && [ ! -L "$lp/compatdata" ]; then todo=1; fi
done
if [ "$todo" = 0 ]; then
  echo "Every library is already linked (or not mounted); nothing to do."
  echo "To change which copy of a game is active, use switch-prefix.sh."
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "DRY RUN: nothing will be changed, no manifest written."
else
  # New manifest folder per run; never reuse an existing one
  M="$MANIFEST_ROOT/$(date +%Y%m%d-%H%M%S)"
  n=1; base=$M
  while [ -e "$M" ]; do M="$base-$n"; n=$((n + 1)); done
  mkdir -p "$MANIFEST_ROOT"
  mkdir "$M"
  exec > >(tee -a "$M/log.txt") 2>&1
  printf 'STEAMAPPS=%q\nHCD=%q\n' "$STEAMAPPS" "$HCD" > "$M/config.env"
  for e in "${LIBS[@]}"; do printf '%s\t%s\n' "${e%%=*}" "${e#*=}"; done > "$M/libraries.tsv"
  printf 'action\tappid\tfrom\tto\n' > "$M/actions.tsv"
  echo "Manifest: $M"
  echo "Taking inventory of every prefix (reads each one once)..."
  {
    printf 'location\tappid\tname\tnewest_save\tnewest_save_file\tsize_kb\tfingerprint\tpath\n'
    if [ -d "$HCD" ]; then inventory main "$HCD"; fi
    for e in "${LIBS[@]}"; do
      lp=${e#*=}
      if [ -d "$lp/compatdata" ] && [ ! -L "$lp/compatdata" ]; then
        inventory "${e%%=*}" "$lp/compatdata"
      fi
    done
  } > "$M/inventory-before.tsv"
  echo "Inventory: $(($(wc -l < "$M/inventory-before.tsv") - 1)) prefixes recorded."
fi

run mkdir -p "$HCD"

for e in "${LIBS[@]}"; do
  label=${e%%=*}
  LIB=${e#*=}
  echo
  echo "== $label: $LIB"

  if [ ! -d "$LIB" ]; then
    echo "  not found (drive not mounted or wrong path), skipping"
    continue
  fi
  if [ -L "$LIB/compatdata" ]; then
    echo "  already a symlink -> $(readlink "$LIB/compatdata"), skipping"
    continue
  fi
  if [ -e "$LIB/compatdata.old" ]; then
    echo "  compatdata.old already exists; check it and remove or rename it first, skipping"
    continue
  fi
  if [ ! -d "$LIB/compatdata" ]; then
    echo "  no compatdata here, just creating the symlink"
    run ln -s "$HCD" "$LIB/compatdata"
    logact link - "$HCD" "$LIB/compatdata"
    continue
  fi

  for src in "$LIB"/compatdata/*/; do
    [ -d "$src" ] || continue
    src=${src%/}
    id=$(basename "$src")
    dst="$HCD/$id"

    IFS=$'\t' read -r s s_f <<<"$(newest "$src")"

    if [ ! -e "$dst" ] && [ -z "${WIN_T[$id]:-}" ]; then
      echo "  $id ($(gname "$id")): only in $label -> copying to main"
      copy_verified "$id" "$src" "$dst"
      WIN_T[$id]=$s; WIN_F[$id]=$s_f; WIN_SRC[$id]=$label
      continue
    fi

    if [ -n "${WIN_T[$id]:-}" ]; then
      d=${WIN_T[$id]}; d_f=${WIN_F[$id]}; d_src=${WIN_SRC[$id]}
    else
      IFS=$'\t' read -r d d_f <<<"$(newest "$dst")"
      d_src=main
    fi

    # Forcing applies against the original main copy; between two
    # libraries the newer one still wins.
    if in_list "$id" "$FORCE_LIBRARY" && [ "$d_src" = main ]; then
      choice=library; why="forced"
    elif in_list "$id" "$FORCE_MAIN" && [ "$d_src" = main ]; then
      choice=main; why="forced"
    elif [ "$s" -gt "$d" ]; then
      choice=library; why="newer"
    else
      choice=main; why="newer or equal"
    fi

    cloud=""
    if has_cloud "$src" || has_cloud "$dst"; then cloud=", Steam Cloud"; fi
    echo "  $id ($(gname "$id")): conflict$cloud"
    printf '      %-16s %s  %s\n' "main ($d_src)" "$(fmt "$d")" "$d_f"
    printf '      %-16s %s  %s\n' "$label" "$(fmt "$s")" "$s_f"

    if [ "$choice" = library ]; then
      bak=$(bakname "$dst" "$d_src")
      echo "      -> using $label copy ($why), current main copy kept as $(basename "$bak")"
      run mv "$dst" "$bak"
      logact displace "$id" "$dst" "$bak"
      copy_verified "$id" "$src" "$dst"
      WIN_T[$id]=$s; WIN_F[$id]=$s_f; WIN_SRC[$id]=$label
    else
      echo "      -> keeping main copy ($why), $label copy stays in compatdata.old"
      WIN_T[$id]=$d; WIN_F[$id]=$d_f; WIN_SRC[$id]=$d_src
    fi
  done

  run mv "$LIB/compatdata" "$LIB/compatdata.old"
  logact rename - "$LIB/compatdata" "$LIB/compatdata.old"
  run ln -s "$HCD" "$LIB/compatdata"
  logact link - "$HCD" "$LIB/compatdata"
  echo "  linked: $LIB/compatdata -> $HCD"
done

echo
echo "Done. Launch your games and check your saves."
if [ -n "$M" ]; then
  echo "Manifest: $M"
  echo "To restore the original state: ./rollback-prefixes.sh $M"
fi
echo "Once everything checks out, delete the compatdata.old folders and *.bak-* prefixes."
