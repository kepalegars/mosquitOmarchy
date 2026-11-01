#!/usr/bin/env bash
# tweak-wine-theme.sh — make native Wine windows follow the Omarchy theme.
#
# WHAT THIS DOES
#   Every Wine prefix keeps its system colours in the prefix's user.reg, under
#   `[Control Panel\\Colors]` (what GetSysColor reads, i.e. what the classic
#   Win32 widgets use). Wine ships those as light greys, so Wine's own windows —
#   the little "Configuration in progress / Updating…" dialogs, uninstallers,
#   file pickers, and any app that draws stock controls — stay light even when
#   the desktop is dark.
#
#   This writes the palette matching the CURRENT Omarchy theme mode (dark or
#   light, read from the theme's colors.toml `mode`) into every Wine prefix it
#   finds, then installs a theme-set hook so the palette is re-applied on every
#   theme change. It edits user.reg directly: no wine binary, no prefix boot,
#   no winetricks, works on patched Wine builds too.
#
#   This is a preference, not a repair: Wine works fine without it.
#
# WHAT IT CANNOT DO
#   Apps that draw their own chrome (Qt/Electron/GTK UI, custom-drawn skins)
#   ignore these colours — no registry setting reaches them.
#
# Usage:
#   ./tweak-wine-theme.sh                 # apply (idempotent)
#   ./tweak-wine-theme.sh --status        # read-only report
#   ./tweak-wine-theme.sh --remove        # restore the saved user.reg files
#   ./tweak-wine-theme.sh --prefix DIR    # also/only target this prefix (repeatable)
#   ./tweak-wine-theme.sh --quiet         # for the theme-set hook (terse)
#   ./tweak-wine-theme.sh -h
#
# Environment: WINE_PREFIXES (space-separated extra prefixes), OMARCHY_PATH.
set -euo pipefail

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){  printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf "${Y} !${N} %s\n" "$*"; }
err(){ printf "${R} ✗${N} %s\n" "$*" >&2; }

REAL_HOME="${HOME}"
STATE_DIR="$REAL_HOME/.local/state/mosquitomarchy/wine-theme"
MODE_FILE="$STATE_DIR/mode"
BACKUP_DIR="$STATE_DIR/backups"
HOOK_DIR="${XDG_CONFIG_HOME:-$REAL_HOME/.config}/omarchy/hooks/theme-set.d"
HOOK_FILE="$HOOK_DIR/wine-theme"
SELF="$(readlink -f "$0")"
COLORS_TSV="$STATE_DIR/colors.tsv"

STATUS_ONLY=false REMOVE=false QUIET=false
EXTRA_PREFIXES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS_ONLY=true; shift ;;
    --remove|--uninstall) REMOVE=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --prefix) [[ -n ${2:-} ]] && EXTRA_PREFIXES+=("$2"); shift 2 ;;
    --prefix=*) EXTRA_PREFIXES+=("${1#--prefix=}"); shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

theme_mode(){
  local toml="$REAL_HOME/.local/state/omarchy/current/theme/colors.toml"
  if [[ -r $toml ]]; then
    awk -F'"' '/^[[:space:]]*mode[[:space:]]*=/{print $2; exit}' "$toml"
  fi
}

# color-name <Tab> "R G B" per line. Kept in a file so both the writer and the
# --remove restorer read the exact same key set.
write_palette(){
  local mode="$1"
  if [[ $mode == light ]]; then
    cat > "$COLORS_TSV" <<'EOF'
ActiveBorder	255 255 255
ActiveTitle	50 150 250
AppWorkSpace	128 128 128
Background	37 111 149
ButtonAlternateFace	255 255 255
ButtonDkShadow	106 106 106
ButtonFace	245 245 245
ButtonHilight	255 255 255
ButtonLight	227 227 227
ButtonShadow	166 166 166
ButtonText	0 0 0
GradientActiveTitle	50 150 250
GradientInactiveTitle	128 128 128
GrayText	106 106 106
Hilight	48 150 250
HilightText	255 255 255
HotTrackingColor	48 150 250
InactiveBorder	255 255 255
InactiveTitle	128 128 128
InactiveTitleText	200 200 200
InfoText	0 0 0
InfoWindow	255 255 255
Menu	255 255 255
MenuBar	255 255 255
MenuHilight	48 150 250
MenuText	0 0 0
Scrollbar	255 255 255
TitleText	0 0 0
Window	255 255 255
WindowFrame	158 158 158
WindowText	0 0 0
EOF
  else
    cat > "$COLORS_TSV" <<'EOF'
ActiveBorder	60 60 60
ActiveTitle	40 40 40
AppWorkSpace	45 45 45
Background	45 45 45
ButtonAlternateFace	60 60 60
ButtonDkShadow	30 30 30
ButtonFace	60 60 60
ButtonHilight	85 85 85
ButtonLight	70 70 70
ButtonShadow	40 40 40
ButtonText	230 230 230
GradientActiveTitle	70 70 70
GradientInactiveTitle	50 50 50
GrayText	120 120 120
Hilight	90 120 160
HilightText	255 255 255
HotTrackingColor	120 160 220
InactiveBorder	60 60 60
InactiveTitle	50 50 50
InactiveTitleText	180 180 180
InfoText	230 230 230
InfoWindow	45 45 45
Menu	45 45 45
MenuBar	45 45 45
MenuHilight	90 120 160
MenuText	230 230 230
Scrollbar	55 55 55
TitleText	255 255 255
Window	35 35 35
WindowFrame	60 60 60
WindowText	230 230 230
EOF
  fi
}

# Discover Wine prefixes: ~/.wine and every ~/.wine-* carrying a drive_c, plus
# any --prefix/WINE_PREFIXES given. Deduped, stable order.
discover_prefixes(){
  local -a out=()
  local d p
  for d in "$REAL_HOME"/.wine "$REAL_HOME"/.wine-*; do
    [[ -d $d/drive_c ]] || continue
    out+=("$d")
  done
  for p in "${EXTRA_PREFIXES[@]:-}" ${WINE_PREFIXES:-}; do
    [[ -n $p && -d $p/drive_c ]] && out+=("$(readlink -f "$p")")
  done
  local -A seen=()
  for p in "${out[@]:-}"; do
    [[ -n $p ]] || continue
    [[ -n ${seen[$p]:-} ]] && continue
    seen[$p]=1
    printf '%s\n' "$p"
  done
}

# Rewrite the [Control Panel\\Colors] section of a user.reg from a palette file
# (name<TAB>value, its path in argv[2]). Every palette key is set; other keys in
# the section are preserved. Prints "changed" or "unchanged".
apply_reg(){
  local reg="$1" pal="$2"
  python3 - "$reg" "$pal" <<'PY'
import sys, re
reg = sys.argv[1]
palette = {}
with open(sys.argv[2], "r", encoding="utf-8") as pf:
    for line in pf:
        line = line.rstrip("\n")
        if not line or "\t" not in line:
            continue
        name, val = line.split("\t", 1)
        palette[name] = val

SECTIONS = ("Control Panel\\\\Colors",
            "Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\ThemeManager\\\\Control Panel\\\\Colors")

with open(reg, "r", encoding="utf-8", errors="surrogateescape") as fh:
    lines = fh.readlines()

changed = False
out = []
i = 0
n = len(lines)
while i < n:
    line = lines[i]
    m = re.match(r"^\[(.+?)\](?:\s.*)?$", line)
    if m and m.group(1) in SECTIONS:
        out.append(line)
        i += 1
        # consume the section body up to the next section header / EOF,
        # rewriting known keys as we go
        seen = set()
        while i < n and not re.match(r"^\[.+?\]", lines[i]):
            bl = lines[i]
            km = re.match(r'^"([^"]+)"=(.*)$', bl.rstrip("\n"))
            if km and km.group(1) in palette:
                seen.add(km.group(1))
                new = '"%s"="%s"' % (km.group(1), palette[km.group(1)])
                if bl.rstrip("\n") != new:
                    changed = True
                    bl = new + "\n"
            out.append(bl)
            i += 1
        missing = [k for k in palette if k not in seen]
        if missing:
            changed = True
            for k in missing:
                out.append('"%s"="%s"\n' % (k, palette[k]))
        continue
    out.append(line)
    i += 1

if changed:
    with open(reg, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.writelines(out)
print("changed" if changed else "unchanged")
PY
}

# Remove the palette keys (restores whatever the section had, i.e. Wine's own
# defaults, since we only ever touch keys we own... unless a backup is restored).
backup_path(){
  local p="$1"
  printf '%s/%s.user.reg' "$BACKUP_DIR" "$(printf '%s' "$p" | sed 's#^/##; s#/#_#g')"
}

status(){
  local mode; mode="$(theme_mode)"; mode="${mode:-unknown}"
  msg "Wine theme tweak — status"
  printf '    system theme mode : %s\n' "$mode"
  printf '    recorded mode     : %s\n' "$([[ -f $MODE_FILE ]] && cat "$MODE_FILE" || echo '<none>')"
  printf '    theme-set hook    : %s\n' "$([[ -x $HOOK_FILE ]] && echo "$HOOK_FILE" || echo '<none>')"
  echo
  local p reg cur
  local found=false
  while IFS= read -r p; do
    found=true
    reg="$p/user.reg"
    if [[ -r $reg ]] && grep -q '"ButtonFace"="60 60 60"' "$reg" 2>/dev/null; then
      cur="dark"
    elif [[ -r $reg ]] && grep -q '"ButtonFace"="245 245 245"' "$reg" 2>/dev/null; then
      cur="light"
    else
      cur="<other/unknown>"
    fi
    printf '    %-32s ButtonFace=%s\n' "${p/#$REAL_HOME/~}" "$cur"
  done < <(discover_prefixes)
  $found || warn "no Wine prefix found (~/.wine* with drive_c)."
}

apply(){
  local mode; mode="$(theme_mode)"
  if [[ -z $mode ]]; then
    err "could not read the Omarchy theme mode (expected mode = in colors.toml)."
    return 1
  fi
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  write_palette "$mode"

  local p reg rc=0 n=0
  while IFS= read -r p; do
    reg="$p/user.reg"
    if [[ ! -f $reg ]]; then
      warn "no user.reg in ${p/#$REAL_HOME/~} (prefix never booted?) — skipped"
      continue
    fi
    local bak; bak="$(backup_path "$p")"
    if [[ ! -f $bak ]]; then
      cp "$reg" "$bak"
    fi
    local res
    if res="$(apply_reg "$reg" "$COLORS_TSV")"; then
      n=$((n + 1))
      $QUIET || ok "palette '$mode' written to ${p/#$REAL_HOME/~} ($res)"
    else
      rc=1; err "failed to update ${p/#$REAL_HOME/~}/user.reg"
    fi
  done < <(discover_prefixes)

  printf '%s\n' "$mode" > "$MODE_FILE"

  # Hook: re-apply on every theme change. Bake in the absolute path of this
  # script (resolve symlinks so the hook survives a linked checkout).
  mkdir -p "$HOOK_DIR"
  cat > "$HOOK_FILE" <<EOF
#!/usr/bin/env bash
# Installed by mosquitOmarchy (tweak-wine-theme.sh): keep native Wine windows on
# the desktop's dark/light palette after every Omarchy theme change.
exec "$SELF" --quiet
EOF
  chmod +x "$HOOK_FILE"

  if (( n == 0 )); then
    warn "no Wine prefix with a user.reg found — nothing written."
  fi
  $QUIET || ok "Wine windows now follow the '$mode' Omarchy theme ($n prefix(es))."
  $QUIET || echo "    Restart Wine apps to pick the colours up.  Undo:  $0 --remove"
  (( rc == 0 ))
}

# --remove: restore the saved user.reg files (exact previous state) and drop the
# hook. Falls back to stripping nothing when no backup exists.
remove(){
  local p reg bak rc=0 n=0
  while IFS= read -r p; do
    reg="$p/user.reg"; bak="$(backup_path "$p")"
    if [[ -f $bak && -f $reg ]]; then
      cp "$bak" "$reg"; rm -f "$bak"
      n=$((n + 1)); ok "restored ${p/#$REAL_HOME/~}/user.reg"
    fi
  done < <(discover_prefixes)
  rm -f "$HOOK_FILE" "$MODE_FILE" "$COLORS_TSV" 2>/dev/null || true
  rmdir "$BACKUP_DIR" 2>/dev/null || true
  ok "Wine theme tweak removed ($n prefix(es) restored); theme-set hook dropped."
  (( rc == 0 ))
}

if $REMOVE; then
  remove
elif $STATUS_ONLY; then
  status
else
  apply
fi
