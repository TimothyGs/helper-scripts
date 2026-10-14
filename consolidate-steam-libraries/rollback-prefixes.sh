#!/usr/bin/env bash
# rollback-prefixes.sh
#
# Restores the state from before consolidate-prefixes.sh, using the manifest
# that run wrote, then checks every restored prefix against the fingerprint
# recorded before the run.
#
# Nothing is deleted. Copies the consolidation placed in main (including any
# progress you made in them since) are moved to compatdata-rollback-<timestamp>
# next to compatdata, so you can still pull saves out of them.
#
# Usage:
#   DRY_RUN=1 ./rollback-prefixes.sh ~/prefix-consolidation/<timestamp>
#   ./rollback-prefixes.sh ~/prefix-consolidation/<timestamp>

set -euo pipefail

M="${1:?usage: rollback-prefixes.sh <manifest folder>}"
M=${M%/}
DRY_RUN="${DRY_RUN:-0}"

if [ ! -f "$M/actions.tsv" ] || [ ! -f "$M/config.env" ]; then
  echo "No manifest found in $M" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$M/config.env"   # STEAMAPPS, HCD
RB="$STEAMAPPS/compatdata-rollback-$(basename "$M")"

run() {
  if [ "$DRY_RUN" = 1 ]; then echo "      [dry] $*"; else "$@"; fi
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

# Free name in the rollback folder: <appid>, <appid>.1, ...
rbname() {
  local b="$RB/$1" n=1
  while [ -e "$b" ]; do b="$RB/$1.$n"; n=$((n + 1)); done
  echo "$b"
}

if pgrep -x steam >/dev/null; then
  echo "Steam is running. Quit it completely first." >&2
  exit 1
fi

# Actions newest first
mapfile -t ACTIONS < <(tail -n +2 "$M/actions.tsv" | tac)
if [ "${#ACTIONS[@]}" -eq 0 ]; then
  echo "The manifest records no changes; nothing to roll back."
  exit 0
fi

# Check everything needed is still there before touching anything
missing=0
declare -A RESTORED=()
for line in "${ACTIONS[@]}"; do
  IFS=$'\t' read -r act id from to <<<"$line"
  case $act in
    link)
      if [ ! -L "$to" ]; then echo "  expected a symlink: $to"; missing=1; fi ;;
    rename)
      if [ ! -d "$to" ]; then echo "  missing: $to"; missing=1; fi ;;
    displace)
      if [ ! -d "$to" ]; then echo "  missing backup: $to"; missing=1; fi
      case "$to" in *.bak-main|*.bak-main.*) RESTORED["$from"]=1 ;; esac ;;
  esac
done
if [ "$missing" = 1 ]; then
  echo "Rollback stopped before changing anything: the paths above are gone." >&2
  exit 1
fi

[ "$DRY_RUN" = 1 ] && echo "DRY RUN: nothing will be changed."
echo "Rolling back $M"
run mkdir -p "$RB"

for line in "${ACTIONS[@]}"; do
  IFS=$'\t' read -r act id from to <<<"$line"
  case $act in
    link)
      echo "  remove link    $to"
      run rm -- "$to"
      ;;
    rename)
      echo "  restore        $from"
      run mv -- "$to" "$from"
      ;;
    copy)
      if [ -e "$to" ] || [ "$DRY_RUN" = 1 ]; then
        dest=$(rbname "$id")
        echo "  set aside      $id -> $dest"
        run mv -- "$to" "$dest"
      fi
      ;;
    displace)
      if [ "$DRY_RUN" != 1 ] && [ -e "$from" ]; then
        dest=$(rbname "$id")
        echo "  set aside      $id -> $dest"
        mv -- "$from" "$dest"
      fi
      echo "  restore        $id from $(basename "$to")"
      run mv -- "$to" "$from"
      ;;
  esac
done

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "Dry run done. Run without DRY_RUN=1 to roll back."
  exit 0
fi

echo
echo "Checking restored prefixes against the inventory from before the run..."
ok=0; active=0; bad=0
while IFS=$'\t' read -r loc id name t f size fp path; do
  now=$(fingerprint "$path")
  if [ "$now" = "$fp" ]; then
    ok=$((ok + 1))
  elif [ "$loc" = main ] && [ -z "${RESTORED[$path]:-}" ]; then
    # Stayed in use the whole time, so changes are your own play since
    active=$((active + 1))
  else
    echo "  !! $id ($name) at $path does not match its recorded fingerprint"
    bad=$((bad + 1))
  fi
done < <(tail -n +2 "$M/inventory-before.tsv")

echo "  $ok prefixes restored exactly as they were."
[ "$active" -gt 0 ] && echo "  $active main prefixes changed since the run; they stayed in use throughout, so that is your own play, kept as is."
[ "$bad" -gt 0 ] && echo "  $bad prefixes do NOT match; see the lines above."
if [ -d "$RB" ] && [ -n "$(ls -A "$RB")" ]; then
  echo "Copies from the consolidated state (with any progress since) are in:"
  echo "  $RB"
else
  rmdir "$RB" 2>/dev/null || true
fi
