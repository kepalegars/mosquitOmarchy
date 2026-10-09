#!/usr/bin/env bash
# setup-pipewire-settings.sh — install the mosquitOmarchy PipeWire settings plugin.
#
# Three things, all idempotent:
#   1. the backend script, which is the only thing that talks to PipeWire;
#   2. the shell plugin (a panel summoned from the Omarchy menu);
#   3. the menu entry that summons it.
#
# Deliberately NOT installed: nothing. This plugin configures the audio graph you
# already have; it does not pull in a package, a daemon or a service. PipeWire
# itself is required and is expected to be there already.
#
# Usage:
#   ./setup-pipewire-settings.sh            # install (idempotent)
#   ./setup-pipewire-settings.sh --remove   # remove the plugin + menu entry
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="mosquito.pipewire"
PLUGIN_SRC="$SCRIPT_DIR/omarchy-plugins/$PLUGIN_ID"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
BIN_DIR="$HOME/.local/bin"
BACKEND_SRC="$SCRIPT_DIR/pipewire-settings"
BACKEND_BIN="$BIN_DIR/mosquitomarchy-pipewire-settings"

SHELL_JSON="$HOME/.config/omarchy/shell.json"
MENU_FILE="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
BLOCK_START="// >>> Omarchy_Custom_Scripts - pipewire-settings (managed by setup-pipewire-settings.sh)"
BLOCK_END="// <<< Omarchy_Custom_Scripts - pipewire-settings (managed by setup-pipewire-settings.sh)"

G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1;34m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){  printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf "${R}✗${N} %s\n" "$*" >&2; }

# ── The menu entry ───────────────────────────────────────────────────────────
#
# The Omarchy menu is a JSONC map of "trigger.<group>.<name>" entries — JSONC,
# not JSON: it carries // comments, so json.load cannot read it. The repo already
# manages entries here with a marked text block (septabee, live-mode and
# mega-caffeine all do), and a block needs no parser: insert between markers,
# remove between markers.
#
# The one subtlety is the comma, and it is a two-sided trap. The block becomes
# the LAST member of the top-level object, so:
#
#   - the entry before it must GAIN a trailing comma — whatever was last in the
#     file had nothing after it and therefore needed none;
#   - the new entry must NOT have one, because now IT is last.
#
# Getting either wrong produces a file that is no longer valid JSONC, which takes
# the whole Omarchy menu down. So every write is parsed before it replaces
# anything, and a file that would not parse is left exactly as it was.
MENU_SPLICE_PY=$(cat << 'PYEOF'
import json, os, sys

mode       = os.environ["MENU_SPLICE_PY"]
path       = os.environ["MENU_FILE"]
start_mark = os.environ["BLOCK_START"]
end_mark   = os.environ["BLOCK_END"]
backend    = os.environ["BACKEND_BIN"]

lines = open(path).read().split("\n")

def is_noise(line):
    s = line.strip()
    return not s or s.startswith("//")

def parses(text):
    stripped = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("//"))
    try:
        json.loads(stripped)
        return True
    except json.JSONDecodeError:
        return False

# Drop an existing block first, so installing is also updating.
out, skipping = [], False
for line in lines:
    if start_mark in line:
        skipping = True
        continue
    if end_mark in line:
        skipping = False
        continue
    if not skipping:
        out.append(line)

if mode == "remove":
    # Undo the comma `add` gave the entry that used to be last. Leaving it there
    # strands a comma in front of the closing brace once the block is gone, and
    # that is exactly what "removal would not parse" was reporting.
    last = None
    for i in range(len(out) - 1, -1, -1):
        if not is_noise(out[i]):
            last = i
            break
    if last is not None and out[last].strip() == "}":
        prev = last - 1
        while prev >= 0 and is_noise(out[prev]):
            prev -= 1
        if prev >= 0 and out[prev].rstrip().endswith("},"):
            out[prev] = out[prev].rstrip()[:-1]
    result = "\n".join(out)
    if not parses(result):
        sys.stderr.write("removal would not parse\n")
        sys.exit(1)
    open(path, "w").write(result)
    sys.exit(0)

block = [
    start_mark,
    # Folder comes from the key's prefix, so this used to land under Trigger while
    # every other mosquito entry (manager, audio-plugins, move, live, jam) sits in
    # the setup.mosquito.* namespace. Renamed to join them.
    '  "setup.mosquito.pipewire": {',
    '    // An emoji, not a Nerd Font code: the mark is a waveform and there is no',
    '    // symbolic glyph for one, so \uf188 (a generic audio icon) stood in and',
    '    // simply did not look like the thing. The menu renders each entry in one',
    '    // foreground colour, but a COLOUR emoji brings its own — which is why the',
    '    // bar icon is drawn in barForeground and this one is not.',
    '    "icon": "\U0001F39A",',
    '    "label": "PipeWire Settings",',
    '    "description": "Sample rate and buffer size for the audio graph, with force and persist",',
    '    "aliases": ["pipewire", "pw", "sample-rate", "buffer", "quantum", "audio-settings"],',
    '    "when": "test -x %s",' % backend,
    '    "action": "omarchy-shell shell summon mosquito.pipewire \'{}\'"',
    '  }',
    end_mark,
]

# The last meaningful line is the closing brace of the top-level object.
close = None
for i in range(len(out) - 1, -1, -1):
    if not is_noise(out[i]):
        close = i
        break
if close is None or out[close].strip() != "}":
    sys.stderr.write("no top-level closing brace found\n")
    sys.exit(1)

# Whatever was last had no comma because nothing followed it. Now something does.
prev = close - 1
while prev >= 0 and is_noise(out[prev]):
    prev -= 1
if prev >= 0 and out[prev].rstrip().endswith("}"):
    out[prev] = out[prev].rstrip() + ","

result = "\n".join(out[:close] + block + out[close:])
if not parses(result):
    sys.stderr.write("the spliced file would not parse\n")
    sys.exit(1)
open(path, "w").write(result)
PYEOF
)

menu_is_valid_jsonc(){
  [[ -f $MENU_FILE ]] || return 1
  MENU_SPLICE_PY=check MENU_FILE="$MENU_FILE" \
  BLOCK_START="$BLOCK_START" BLOCK_END="$BLOCK_END" BACKEND_BIN="$BACKEND_BIN" \
  python3 -c "$MENU_SPLICE_PY"
}

add_menu_block(){
  menu_is_valid_jsonc || { warn "$MENU_FILE is missing or not valid JSONC — not touching it"; return 1; }
  MENU_SPLICE_PY=add MENU_FILE="$MENU_FILE" \
  BLOCK_START="$BLOCK_START" BLOCK_END="$BLOCK_END" BACKEND_BIN="$BACKEND_BIN" \
  python3 -c "$MENU_SPLICE_PY" || { warn "could not add the menu entry — add it by hand, see README.md"; return 1; }
}

remove_menu_block(){
  menu_is_valid_jsonc || return 1
  MENU_SPLICE_PY=remove MENU_FILE="$MENU_FILE" \
  BLOCK_START="$BLOCK_START" BLOCK_END="$BLOCK_END" BACKEND_BIN="$BACKEND_BIN" \
  python3 -c "$MENU_SPLICE_PY"
}

# ── Enabling the plugin in shell.json ─────────────────────────────────────────
#
# Installing the files is NOT enough. `omarchy-shell shell summon` refused with
# "plugin not enabled, not summoning" on a plugin that was present on disk and in
# the menu: a local plugin has to be listed in shell.json's `plugins` array before
# the shell will load it at all.
#
# shell.json is plain JSON (unlike the menu, which is JSONC), and this appends
# only if the id is absent, so re-running never doubles it.
enable_plugin(){
  [[ -f $SHELL_JSON ]] || { warn "$SHELL_JSON not found — enable the plugin by hand"; return 1; }
  PLUGIN_ID="$PLUGIN_ID" SHELL_JSON="$SHELL_JSON" python3 - <<'PY'
import json, os
path = os.environ["SHELL_JSON"]
pid  = os.environ["PLUGIN_ID"]
with open(path) as f:
    cfg = json.load(f)
plugins = cfg.setdefault("plugins", [])
if any(isinstance(p, dict) and p.get("id") == pid for p in plugins):
    sys_exit = 0
else:
    plugins.append({"id": pid})
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
PY
}

disable_plugin(){
  [[ -f $SHELL_JSON ]] || return 0
  PLUGIN_ID="$PLUGIN_ID" SHELL_JSON="$SHELL_JSON" python3 - <<'PY'
import json, os
path = os.environ["SHELL_JSON"]
pid  = os.environ["PLUGIN_ID"]
with open(path) as f:
    cfg = json.load(f)
plugins = cfg.get("plugins", [])
kept = [p for p in plugins if not (isinstance(p, dict) and p.get("id") == pid)]
if len(kept) != len(plugins):
    cfg["plugins"] = kept
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
PY
}

# ── Putting the plugin in the bar ────────────────────────────────────────────
#
# Being "enabled" is not enough to exist. shell.qml mounts bar widgets THROUGH the
# bar layout: a plugin that is installed, enabled and listed in the menu but absent
# from bar.layout is never instantiated, so it has no IPC handler and
# `omarchy-shell shell summon mosquito.pipewire` answers "unknown". The menu entry
# opens nothing, which is worse than having no menu entry at all.
#
# Right section, next to omarchy.audio: both are audio, and that is where a
# glance for them expects to find it.
BAR_SECTION="right"

add_to_bar(){
  [[ -f $SHELL_JSON ]] || { warn "$SHELL_JSON not found"; return 1; }
  PLUGIN_ID="$PLUGIN_ID" SHELL_JSON="$SHELL_JSON" BAR_SECTION="$BAR_SECTION" python3 - <<'PY'
import json, os, sys
path = os.environ["SHELL_JSON"]
pid  = os.environ["PLUGIN_ID"]
sect = os.environ["BAR_SECTION"]
with open(path) as f:
    cfg = json.load(f)
layout = cfg.setdefault("bar", {}).setdefault("layout", {})
items = layout.setdefault(sect, [])
if any(isinstance(i, dict) and i.get("id") == pid for i in items):
    sys.exit(0)
items.append({"id": pid})
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
}

remove_from_bar(){
  [[ -f $SHELL_JSON ]] || return 0
  PLUGIN_ID="$PLUGIN_ID" SHELL_JSON="$SHELL_JSON" python3 - <<'PY'
import json, os
path = os.environ["SHELL_JSON"]
pid  = os.environ["PLUGIN_ID"]
with open(path) as f:
    cfg = json.load(f)
changed = False
for sect, items in cfg.get("bar", {}).get("layout", {}).items():
    kept = [i for i in items if not (isinstance(i, dict) and i.get("id") == pid)]
    if len(kept) != len(items):
        cfg["bar"]["layout"][sect] = kept
        changed = True
if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
PY
}

# ── install / remove ─────────────────────────────────────────────────────────

install_plugin(){
  if ! command -v pw-metadata >/dev/null 2>&1; then
    warn "pw-metadata not found — the panel would have nothing to talk to."
    warn "On Arch: sudo pacman -S pipewire"
  fi

  [[ -f $BACKEND_SRC ]] || { err "backend missing: $BACKEND_SRC"; return 1; }
  [[ -d $PLUGIN_SRC ]]  || { err "plugin sources missing: $PLUGIN_SRC"; return 1; }

  mkdir -p "$BIN_DIR"
  install -m 0755 "$BACKEND_SRC" "$BACKEND_BIN"
  ok "backend installed: $BACKEND_BIN"

  mkdir -p "$PLUGIN_DIR"
  cp -a "$PLUGIN_SRC/." "$PLUGIN_DIR/"
  ok "plugin installed: $PLUGIN_DIR"

  if enable_plugin; then ok "plugin enabled in shell.json"; fi
  if add_to_bar; then ok "plugin added to the bar ($BAR_SECTION)"; fi
  if add_menu_block; then ok "menu entry added under mosquitOmarchy"; fi

  msg "Reload the shell to pick the plugin up: omarchy-restart-shell"
}

remove_plugin(){
  msg "Removing the PipeWire settings plugin"
  rm -rf "$PLUGIN_DIR"
  ok "plugin removed"
  rm -f "$BACKEND_BIN"
  ok "backend removed"

  # The persisted graph config is LEFT ALONE on purpose: it is the user's audio
  # setting, not ours. Removing the plugin must not silently unconfigure
  # PipeWire — say where it is and let them decide.
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/90-mosquitomarchy-pipewire.conf"
  [[ -f $conf ]] && warn "persisted PipeWire config left in place: $conf"

  # Loud on failure: the plugin files are already gone at this point, so a silent
  # no-op here would leave a menu entry pointing at a plugin that is no longer
  # installed — a row that opens nothing.
  if remove_from_bar; then ok "plugin removed from the bar"; fi
  if disable_plugin; then ok "plugin disabled in shell.json"; fi

  if remove_menu_block; then
    ok "menu entry removed"
  else
    err "menu entry NOT removed — $MENU_FILE still refers to the plugin"
  fi
}

main(){
  local action="${1:-}"
  case "$action" in
    --remove) remove_plugin ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' ;;
    # run_pipewire_settings() invokes this with -y for unattended runs, the way every
    # other setup script in the repo is called. It used to be rejected as an unknown
    # option, so installing PipeWire Settings from Setup died on its very first step;
    # the plugin only worked because it had been installed by hand.
    -y|--yes)  install_plugin ;;
    "")        install_plugin ;;
    *)         err "unknown option: $action"; return 1 ;;
  esac
}

main "$@"