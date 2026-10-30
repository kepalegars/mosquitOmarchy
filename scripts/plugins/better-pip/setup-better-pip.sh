#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - Better PiP
# =============================================================================
# Fork of ricardo-ti.pip-solver (MIT, (c) 2026 Ricardo Franco)
#   https://github.com/rfranco-ti/pip-solver
#
# Every picture-in-picture window (Firefox, Zen, Chromium, Brave, Edge, Meet):
#   • floats, unpinned, on its own workspace — it no longer stays above every
#     window and does not follow you when you switch workspaces;
#   • keeps the video aspect ratio and a grabbable border;
#   • holds an idle inhibitor while it exists (no screensaver / lock).
#
# Changes from upstream:
#   • also matches the French/localized Zen title "Incrustation vidéo";
#   • pinning removed (upstream kept the PiP always on top on every workspace).
#
# Usage:
#   ./setup-better-pip.sh            # install + enable (idempotent)
#   ./setup-better-pip.sh --remove   # disable + delete the plugin
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

PLUGIN_ID="mosquito.better-pip"
UPSTREAM_ID="ricardo-ti.pip-solver"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m  !\033[0m $*"; }

if [[ ! -d /usr/share/omarchy ]]; then
  echo "This script is meant for Omarchy." >&2
  exit 1
fi

if [[ $EUID -eq 0 && -n ${SUDO_USER:-} ]]; then
  REAL_USER="$SUDO_USER"
else
  REAL_USER="${USER:-$(id -un)}"
fi
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-$HOME}"
PLUGINS_DIR="$REAL_HOME/.config/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"

REMOVE=false
[[ ${1:-} == --remove ]] && REMOVE=true

reload_plugins() { omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true; }

write_plugin() {
  mkdir -p "$PLUGIN_DIR"

  cat >"$PLUGIN_DIR/manifest.json" <<'JSON'
{
  "schemaVersion": 1,
  "id": "mosquito.better-pip",
  "name": "Better PiP",
  "version": "1.0.0",
  "author": "mosquito",
  "license": "MIT",
  "description": "Floats picture-in-picture windows on their own workspace (never pinned), keeps the video aspect ratio and a grabbable border, and holds an idle inhibitor while active.",
  "kinds": ["service"],
  "entryPoints": {
    "service": "Service.qml"
  }
}
JSON

  cat >"$PLUGIN_DIR/PiPModel.js" <<'JS'
// Browsers localize the PiP window title (French Firefox/Zen uses this one).
var TITLE_PATTERNS = ["^Picture.?in.?[Pp]icture$", "^Incrustation vidéo$", "^Meet - .+"]

var TITLE_REGEXES = TITLE_PATTERNS.map(function(pattern) {
  return new RegExp(pattern, "i")
})

// Never pin: a PiP is a plain floating window that stays on its own workspace.
var RULE_EFFECTS = {
  float: true,
  pin: false,
  keep_aspect_ratio: true,
  border_size: 2,
  idle_inhibit: "always"
}

function matchesTitle(title) {
  if (typeof title !== "string" || title === "") return false
  return TITLE_REGEXES.some(function(regex) {
    return regex.test(title)
  })
}

function windowRuleEffects() {
  return Object.assign({}, RULE_EFFECTS)
}

function actionsFor() {
  return ["float", "unpin", "props"]
}

function toAddress(address) {
  var hex = String(address || "").replace(/^0x/, "")
  return hex ? "0x" + hex : ""
}

function toSelector(address) {
  var hex = toAddress(address)
  return hex ? "address:" + hex : ""
}

function luaString(value) {
  return "'" + String(value).replace(/\\/g, "\\\\").replace(/'/g, "\\'") + "'"
}

function luaValue(value) {
  if (value === true) return "true"
  if (value === false) return "false"
  if (typeof value === "number") return String(value)
  if (value !== null && typeof value === "object") return luaTable(value)
  return luaString(value)
}

function luaTable(object) {
  var entries = Object.keys(object || {}).sort().map(function(key) {
    return key + " = " + luaValue(object[key])
  })
  return "{ " + entries.join(", ") + " }"
}

function ruleLuaList() {
  return TITLE_PATTERNS.map(function(pattern) {
    return luaTable(Object.assign({ match: { title: pattern } }, windowRuleEffects()))
  })
}

if (typeof module !== "undefined") {
  module.exports = {
    matchesTitle: matchesTitle,
    windowRuleEffects: windowRuleEffects,
    actionsFor: actionsFor,
    toAddress: toAddress,
    toSelector: toSelector,
    luaTable: luaTable,
    ruleLuaList: ruleLuaList
  }
}
JS

  cat >"$PLUGIN_DIR/Service.qml" <<'QML'
import QtQuick
import Quickshell.Hyprland
import Quickshell.Io
import "PiPModel.js" as PiPModel

Item {
  id: root

  property var tracked: ({})
  property var pendingCommands: []
  property var history: []
  property string lastAction: ""

  function noteCommand(label, exitCode) {
    var entry = { command: label, exitCode: exitCode }
    var next = root.history.slice(-7)
    next.push(entry)
    root.history = next
    root.lastAction = label + " -> exit " + exitCode
  }

  function track(address) {
    var next = Object.assign({}, root.tracked)
    next[address] = true
    root.tracked = next
  }

  function forget(address) {
    if (!(address in root.tracked)) return
    var next = {}
    for (var existing in root.tracked) {
      if (existing !== address) next[existing] = true
    }
    root.tracked = next
  }

  function runHyprctl(args) {
    root.pendingCommands.push(args)
    pumpCommandQueue()
  }

  function pumpCommandQueue() {
    if (commandProcess.running || root.pendingCommands.length === 0) return
    var args = root.pendingCommands.shift()
    commandProcess.currentLabel = args.join(" ")
    commandProcess.command = args
    commandProcess.running = true
  }

  function registerRules() {
    PiPModel.ruleLuaList().forEach(function(rule) {
      root.runHyprctl(["hyprctl", "eval", "hl.window_rule(" + rule + ")"])
    })
  }

  function scanWindows() {
    if (scanProcess.running) return
    scanProcess.running = true
  }

  function applyToClient(client) {
    if (!PiPModel.matchesTitle(client.title)) return
    var address = PiPModel.toAddress(client.address)
    root.track(address)
    root.applyActions(PiPModel.toSelector(address), PiPModel.actionsFor())
  }

  function considerWindow(address, title) {
    if (!PiPModel.matchesTitle(title)) return
    var canonical = PiPModel.toAddress(address)
    root.track(canonical)
    root.applyActions(PiPModel.toSelector(canonical), PiPModel.actionsFor())
  }

  function applyActions(selector, actions) {
    actions.forEach(function(action) {
      if (action === "float") {
        root.runHyprctl(dispatchCall("float", { action: "on", window: selector }))
      } else if (action === "unpin") {
        root.runHyprctl(dispatchCall("pin", { action: "off", window: selector }))
      } else if (action === "props") {
        root.runHyprctl(dispatchCall("set_prop", { prop: "keep_aspect_ratio", value: "1", window: selector }))
        root.runHyprctl(dispatchCall("set_prop", { prop: "border_size", value: "2", window: selector }))
        root.runHyprctl(dispatchCall("set_prop", { prop: "idle_inhibit", value: "1", window: selector }))
      }
    })
  }

  function dispatchCall(fn, args) {
    return ["hyprctl", "dispatch", "hl.dsp.window." + fn + "(" + PiPModel.luaTable(args) + ")"]
  }

  function statusJson() {
    return JSON.stringify({
      tracked: Object.keys(root.tracked),
      lastAction: root.lastAction,
      history: root.history
    })
  }

  Component.onCompleted: {
    registerRules()
    scanWindows()
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (name === "openwindow") {
        var opened = event.parse(4)
        root.considerWindow(opened[0], opened[3])
      } else if (name === "windowtitlev2") {
        var retitled = event.parse(2)
        root.considerWindow(retitled[0], retitled[1])
      } else if (name === "closewindow") {
        root.forget(PiPModel.toAddress(String(event.data || "")))
      } else if (name === "configreloaded") {
        root.registerRules()
        root.scanWindows()
      }
    }
  }

  Process {
    id: commandProcess

    property string currentLabel: ""

    onExited: function(exitCode) {
      root.noteCommand(currentLabel, exitCode)
      root.pumpCommandQueue()
    }
  }

  Process {
    id: scanProcess

    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var clients
        try {
          clients = JSON.parse(this.text)
        } catch (error) {
          return
        }
        clients.forEach(function(client) {
          root.applyToClient(client)
        })
        root.lastAction = "scan applied to " + clients.filter(function(client) {
          return PiPModel.matchesTitle(client.title)
        }).length + " window(s)"
      }
    }
  }

  IpcHandler {
    target: "better-pip"

    function status(): string {
      return root.statusJson()
    }
  }
}
QML

  cat >"$PLUGIN_DIR/LICENSE" <<'TXT'
MIT License

Copyright (c) 2026 Ricardo Franco
Copyright (c) 2026 mosquito (fork: Better PiP)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
TXT
}

retire_upstream() {
  [[ -d "$PLUGINS_DIR/$UPSTREAM_ID" ]] || return 1
  omarchy plugin disable "$UPSTREAM_ID" >/dev/null 2>&1 || true
  rm -rf "$PLUGINS_DIR/$UPSTREAM_ID"
  ok "Upstream $UPSTREAM_ID disabled and removed (replaced by $PLUGIN_ID)"
  return 0
}

if [[ $REMOVE == true ]]; then
  omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
  if [[ -d "$PLUGIN_DIR" ]]; then
    rm -rf "$PLUGIN_DIR"
    ok "Plugin $PLUGIN_ID removed"
  else
    ok "Plugin $PLUGIN_ID already absent"
  fi
  reload_plugins
  info "Better PiP removed. Restart the shell if anything lingers: omarchy restart shell"
  exit 0
fi

write_plugin
omarchy plugin validate "$PLUGIN_DIR" >/dev/null \
  || { echo "Invalid plugin written to $PLUGIN_DIR" >&2; exit 1; }

reload_plugins
sleep 1
if ! omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1; then
  reload_plugins
  sleep 1
  omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 \
    || warn "Could not enable $PLUGIN_ID automatically; enable it from the Omarchy menu."
fi

retired=0
retire_upstream && retired=1 || true
reload_plugins

# Stale rules from the upstream plugin stay in the compositor until a config
# reload; the new service re-registers on configreloaded.
if (( retired )); then
  hyprctl reload >/dev/null 2>&1 || true
fi

info "Better PiP installed and enabled"
echo "  • Plugin      -> $PLUGIN_DIR"
echo "  • Behavior    -> floating PiP, NOT pinned (stays on its workspace)"
echo "  • Diagnostics -> omarchy-shell better-pip status"
