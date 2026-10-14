#!/usr/bin/env bash
# switch-prefix.sh
#
# After consolidate-prefixes.sh: switch which copy of one game's prefix is
# active in main, e.g. when the consolidation picked the wrong one.
#
#   main             the original main-SSD copy from before consolidating
#   <library label>  that library's original copy (from its compatdata.old)
#
# The currently active copy is kept as <appid>.bak-<origin>[.N], the new one
# is copied and verified, and both steps are added to the manifest, so
# rollback-prefixes.sh still restores the original state afterwards.
#
# Usage:
#   DRY_RUN=1 ./switch-prefix.sh ~/prefix-consolidation/<timestamp> 3751260 general_storage
#   ./switch-prefix.sh ~/prefix-consolidation/<timestamp> 3751260 general_storage
#   ./switch-prefix.sh ~/prefix-consolidation/<timestamp> 3751260 main

set -euo pipefail

usage="usage: switch-prefix.sh <manifest folder> <appid> <main|library label>"
M="${1:?$usage}"; ID="${2:?$usage}"; WANT="${3:?$usage}"
M=${M%/}
DRY_RUN="${DRY_RUN:-0}"

for f in actions.tsv config.env libraries.tsv; do
  if [ ! -f "$M/$f" ]; then echo "Missing $M/$f; is this a consolidation manifest?" >&2; exit 1; fi
done
# shellcheck source=/dev/null
source "$M/config.env"   # STEAMAPPS, HCD

declare -A LIBPATH=()
while IFS=$'\t' read -r label path; do LIBPATH[$label]=$path; done < "$M/libraries.tsv"

run() {
  if [ "$DRY_RUN" = 1 ]; then echo "  [dry] $*"; else "$@"; fi
}

logact() {
  [ "$DRY_RUN" = 1 ] || printf '%s\t%s\t%s\t%s\n' "$@" >> "$M/actions.tsv"
}

# Same fingerprint as consolidate-prefixes.sh
fingerprint() (
  set +e +o pipefail
  [ -d "$1/pfx" ] || { echo none; exit 0; }
  cd "$1/pfx" || { echo none; exit 0; }
  { [ -d drive_c/users/steamuser ] && find drive_c/users/steamuser -type f -print0
    find . -maxdepth 1 -type f -name '*.reg' -print0; } 2>/dev/null \
    | sort -z | xargs -0 -r sha256sum | sha256sum | cut -c1-16
)

bakname() {
  local b="$1.bak-$2" n=1
  while [ -e "$b" ]; do b="$1.bak-$2.$n"; n=$((n + 1)); done
  echo "$b"
}

# Label of a library compatdata path, or "main" for a main-SSD backup
origin_of() {
  local from=$1 label
  for label in "${!LIBPATH[@]}"; do
    case "$from" in "${LIBPATH[$label]}"/compatdata/*|"${LIBPATH[$label]}"/compatdata.old/*) echo "$label"; return ;; esac
  done
  echo main
}

if pgrep -x steam >/dev/null; then
  echo "Steam is running. Quit it completely first." >&2
  exit 1
fi

DST="$HCD/$ID"

# Where the active copy came from: the last copy into main for this game,
# or the original main copy if nothing was ever copied over it
current=main
main_orig=""
while IFS=$'\t' read -r act id from to; do
  [ "$id" = "$ID" ] || continue
  if [ "$act" = copy ] && [ "$to" = "$DST" ]; then current=$(origin_of "$from"); fi
  if [ "$act" = displace ] && [ -z "$main_orig" ] && [ "$from" = "$DST" ]; then
    case "$to" in *.bak-main) main_orig=$to ;; esac
  fi
done < <(tail -n +2 "$M/actions.tsv")

if [ "$WANT" = "$current" ]; then
  echo "$ID already uses the $WANT copy; nothing to do."
  exit 0
fi

if [ "$WANT" = main ]; then
  if [ -z "$main_orig" ]; then
    echo "No original main copy of $ID recorded in this manifest." >&2
    exit 1
  fi
  SRC=$main_orig
elif [ -n "${LIBPATH[$WANT]:-}" ]; then
  SRC="${LIBPATH[$WANT]}/compatdata.old/$ID"
else
  echo "Unknown source '$WANT'. Use main or one of: ${!LIBPATH[*]}" >&2
  exit 1
fi

if [ ! -d "$SRC" ]; then
  echo "No $WANT copy of $ID at $SRC" >&2
  exit 1
fi

[ "$DRY_RUN" = 1 ] && echo "DRY RUN: nothing will be changed."
echo "$ID: switching active copy from $current to $WANT"

bak=""
if [ -e "$DST" ]; then
  bak=$(bakname "$DST" "$current")
  echo "  current copy kept as $(basename "$bak")"
  run mv -- "$DST" "$bak"
  logact displace "$ID" "$DST" "$bak"
fi

logact copy "$ID" "$SRC" "$DST"
run cp -a -- "$SRC" "$DST"

if [ "$DRY_RUN" != 1 ]; then
  a=$(fingerprint "$SRC"); b=$(fingerprint "$DST")
  if [ "$a" != "$b" ]; then
    echo "  !! The copy does not match its source ($a vs $b)." >&2
    [ -n "$bak" ] && echo "     Your previous copy is untouched at $bak" >&2
    exit 1
  fi
  echo "  copied and verified"
  printf '%s switch %s: %s -> %s\n' "$(date '+%F %T')" "$ID" "$current" "$WANT" >> "$M/log.txt"
fi
