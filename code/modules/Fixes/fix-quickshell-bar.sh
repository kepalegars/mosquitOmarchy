#!/usr/bin/env bash
# fix-quickshell-bar.sh — restore the Omarchy (Quickshell) bar from a backup.
#
# shell.json is the bar: which widget sits in which zone and every widget's
# settings. A half-written file, or a layout naming a widget this machine does
# not have, empties the bar or takes the whole shell down (no bar, no tray,
# black wallpaper). This puts a known-good layout back.
#
# Sources, newest first: the local ~/.config/omarchy/shell.json.* backups, then
# the mosquitomarchy-backup-*.tar.gz[.gpg] archives in the repo's
# mosquitomarchy-backups/ (or $OMARCHY_BACKUP_DIR), read from the
# config-backup.tar.gz they carry. The first one that parses and has a bar
# wins. Widgets this machine does not have are dropped before the file lands,
# so a layout from another machine cannot re-break the shell. The current file
# is kept as shell.json.broken.<ts>, and the shell is restarted.
#
# A running shell with a readable shell.json counts as healthy: nothing is
# overwritten unless --force is given. An encrypted archive needs
# OMARCHY_BACKUP_PASSPHRASE or a terminal for the passphrase prompt.
#
# Usage:
#   ./fix-quickshell-bar.sh                 # restore if the bar is broken
#   ./fix-quickshell-bar.sh --force         # restore even if it looks healthy
#   ./fix-quickshell-bar.sh <file>          # shell.json or a backup archive
#   ./fix-quickshell-bar.sh -h              # this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
BACKUP_DIR="${OMARCHY_BACKUP_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)/mosquitomarchy-backups}"

FORCE=0
EXPLICIT=""
for a in "$@"; do
  case $a in
    -f|--force) FORCE=1 ;;
    -h|--help) sed -n '1,29p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*) echo "Unknown option: $a (supported: --force -h)" >&2; exit 1 ;;
    *) EXPLICIT="$a" ;;
  esac
done

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m  !\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m  ✗\033[0m $*" >&2; }

command -v jq >/dev/null 2>&1 || { err "jq is required (pacman -S jq)."; exit 1; }

# A usable config: a real bar with at least one widget in one of its zones.
LAYOUT_OK='(.bar | type) == "object" and ((.bar.layout | type) == "object") and ([.bar.layout[]?[]?] | length > 0)'

bar_healthy() {
  [[ -f $SHELL_JSON ]] || return 1
  jq -e "$LAYOUT_OK" "$SHELL_JSON" >/dev/null 2>&1 || return 1
  command -v omarchy >/dev/null 2>&1 || return 1
  omarchy-shell shell ping >/dev/null 2>&1 || omarchy shell shell ping >/dev/null 2>&1
}

# The plugin ids this machine can load: Omarchy's own plugins/widgets plus the
# user's installed plugins. Same list restore_shell_json uses.
known_plugin_ids() {
  local -a ids=()
  local f id
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    id="$(jq -r '.id // empty' "$f" 2>/dev/null)"
    [[ -n $id ]] && ids+=("$id")
  done < <(find /usr/share/omarchy/shell/plugins -maxdepth 3 \
             \( -name 'manifest.json' -o -name '*.manifest.json' \) -type f 2>/dev/null)
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    id="$(jq -r '.id // empty' "$f" 2>/dev/null)"
    [[ -n $id ]] && ids+=("$id")
  done < <(find "$HOME/.config/omarchy/plugins" -maxdepth 2 -name 'manifest.json' -type f 2>/dev/null)
  ((${#ids[@]})) || return 0
  printf '%s\n' "${ids[@]}" | jq -R . | jq -s 'unique' 2>/dev/null
}

# Extract .config/omarchy/shell.json from a mosquitomarchy backup archive
# (through its config-backup.tar.gz) into <dest>.
extract_shell_json() { # <archive> <dest>
  local arc="$1" dest="$2" tmp member cb src pass
  tmp="$(mktemp -d)"
  if [[ $arc == *.gpg ]]; then
    command -v gpg >/dev/null 2>&1 || { warn "gpg is needed to open $(basename "$arc")"; rm -rf "$tmp"; return 1; }
    pass="${OMARCHY_BACKUP_PASSPHRASE:-}"
    if [[ -z $pass ]]; then
      if [[ -t 0 ]]; then
        read -rsp "Passphrase for $(basename "$arc"): " pass
        echo
      else
        warn "encrypted backup skipped (set OMARCHY_BACKUP_PASSPHRASE or pass a plain archive)"
        rm -rf "$tmp"; return 1
      fi
    fi
    if ! printf '%s' "$pass" | gpg --batch --yes --decrypt --cipher-algo AES256 \
        --passphrase-fd 0 -o "$tmp/backup.tar.gz" "$arc" 2>/dev/null; then
      warn "could not decrypt $(basename "$arc")"
      rm -rf "$tmp"; return 1
    fi
    arc="$tmp/backup.tar.gz"
  fi
  member="$(tar tzf "$arc" 2>/dev/null | grep -E '(^|/)(\./)?config-backup\.tar\.gz$' | head -1 || true)"
  [[ -n $member ]] || { rm -rf "$tmp"; return 1; }
  tar xzf "$arc" -C "$tmp" "$member" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  cb="$tmp/$member"
  member="$(tar tzf "$cb" 2>/dev/null | grep -E '(^|/)(\./)?\.config/omarchy/shell\.json$' | head -1 || true)"
  [[ -n $member ]] || { rm -rf "$tmp"; return 1; }
  mkdir -p "$tmp/cfg"
  tar xzf "$cb" -C "$tmp/cfg" "$member" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  src="$tmp/cfg/$member"
  [[ -f $src ]] || { rm -rf "$tmp"; return 1; }
  cp -f "$src" "$dest"
  rm -rf "$tmp"
}

if (( ! FORCE )) && bar_healthy; then
  ok "The bar is up and shell.json is readable — nothing restored."
  echo "  Re-run with --force to put a backup back anyway."
  exit 0
fi

info "Looking for a usable shell.json backup"
shopt -s nullglob
candidates=()
[[ -n $EXPLICIT ]] && candidates+=("$EXPLICIT")
while IFS= read -r f; do
  [[ $f == *.broken.* ]] || candidates+=("$f")
done < <(
  local_baks=("$HOME/.config/omarchy"/shell.json.*)
  ((${#local_baks[@]})) && ls -1t "${local_baks[@]}" 2>/dev/null || true
)
archives=("$BACKUP_DIR"/mosquitomarchy-backup-*.tar.gz* "$BACKUP_DIR"/omarchy-backup-*.tar.gz*)
if ((${#archives[@]})); then
  while IFS= read -r f; do candidates+=("$f"); done < <(ls -1t "${archives[@]}" 2>/dev/null || true)
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chosen=""
for cand in "${candidates[@]}"; do
  src=""
  case $cand in
    *.tar.gz|*.tar.gz.gpg)
      extract_shell_json "$cand" "$tmp/from-archive.json" && src="$tmp/from-archive.json" ;;
    *)
      [[ -f $cand ]] && src="$cand" ;;
  esac
  [[ -n $src ]] || continue
  if jq -e "$LAYOUT_OK" "$src" >/dev/null 2>&1; then
    chosen="$src"
    ok "Using $(basename "$cand")"
    break
  fi
  warn "$(basename "$cand") is not a usable bar config — trying older"
done
if [[ -z $chosen ]]; then
  err "No valid shell.json backup found (looked in ~/.config/omarchy and $BACKUP_DIR)."
  exit 1
fi

# Drop widgets this machine cannot load, exactly like the backup restore does:
# a dead plugin id in the layout kills the bar (or the whole shell).
known="$(known_plugin_ids || true)"
if [[ -n $known ]]; then
  if jq --argjson known "$known" '
      def knownid: . as $x | ($known | index($x)) != null;
      def known: (.id // "") | knownid;
      .plugins = ((.plugins // []) | map(select(known)))
      | .bar = ((.bar // {}) | .layout = ((.layout // {}) | with_entries(
          .value = ((.value // []) | map(select(known))))))
      | (if (.bar.id // "") != "" and ((.bar.id) as $id | ($known | index($id)) == null)
           then .bar |= del(.id) else . end)
      | .disabledPlugins = ((.disabledPlugins // []) | map(select(knownid)))
      | .cloneSourceRestores = ((.cloneSourceRestores // []) | map(select(knownid)))
    ' "$chosen" > "$tmp/pruned.json" 2>/dev/null; then
    chosen="$tmp/pruned.json"
    ok "Widgets this machine does not have were dropped"
  else
    warn "shell.json could not be pruned — restoring it as it was"
  fi
fi

mkdir -p "$(dirname "$SHELL_JSON")"
if [[ -f $SHELL_JSON ]]; then
  cp -a "$SHELL_JSON" "$SHELL_JSON.broken.$(date +%s)" 2>/dev/null || true
fi
if ! cp -f "$chosen" "$SHELL_JSON"; then
  err "Could not write $SHELL_JSON"
  exit 1
fi
chmod 0600 "$SHELL_JSON" 2>/dev/null || true
ok "shell.json restored"

if command -v omarchy >/dev/null 2>&1; then
  info "Restarting the Omarchy shell"
  if omarchy restart shell >/dev/null 2>&1; then
    alive=0
    for _ in {1..15}; do
      if omarchy-shell shell ping >/dev/null 2>&1 || omarchy shell shell ping >/dev/null 2>&1; then
        alive=1; break
      fi
      sleep 1
    done
    if ((alive)); then
      ok "Shell is back — the bar should be drawn again."
    else
      warn "Shell did not answer yet; wait a moment, then run: omarchy restart shell"
    fi
  else
    warn "Could not restart the shell; run: omarchy restart shell"
  fi
else
  warn "omarchy not found — restart the shell yourself to redraw the bar."
fi
