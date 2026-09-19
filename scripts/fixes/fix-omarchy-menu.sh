#!/bin/bash
# fix-omarchy-menu.sh — Recovery for a broken Omarchy menu / empty Apps list.
#
# Symptom this recovers from: the menu renders blank rows (or stops listing
# applications in Apps) after a first-party menu plugin (omarchy.menu) was
# cloned to user space (<user>.menu) and hot-swapped at runtime. Root cause:
# cloning swaps the bar's menu widget at runtime; a stale AppLibrary proxy or
# a single missing row field in the clone's QML breaks the whole ListView.
#
# The recovery (idempotent, safe to re-run):
#   1. removes every user-space clone of omarchy.menu (omarchy plugin remove
#      auto-restores the original when the clone was enabled),
#   2. re-enables the stock omarchy.menu,
#   3. repaints the bar's menu widget reference back to omarchy.menu,
#   4. restarts the shell so all plugins and services bind fresh.

echo "=== Fix Omarchy menu (blank rows / empty Apps) ==="

PLUGINS="$HOME/.config/omarchy/plugins"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

# ---------------------------------------------------------------------------
# 1. Remove any user-space clone of the first-party menu plugin.
# ---------------------------------------------------------------------------
removed_any=0
clone_ids=()
if command -v omarchy >/dev/null 2>&1; then
  while IFS= read -r id; do
    clone_ids+=("$id")
    echo "  • Removing cloned menu plugin: $id"
    # --yes: non-interactive; the command auto-restores omarchy.menu when the
    # clone was the enabled one.
    omarchy plugin remove "$id" --yes >/dev/null 2>&1 || { rm -rf "$PLUGINS/$id"; }
    removed_any=1
  done < <(
    for mf in "$PLUGINS"/*/manifest.json; do
      [[ -f $mf ]] || continue
      if grep -q '"clonedFrom": *"omarchy.menu"' "$mf" 2>/dev/null; then
        basename "$(dirname "$mf")"
      fi
    done
  )
  if (( removed_any )); then
    echo "  ✓ Menu plugin clones removed."
  else
    echo "  • No menu plugin clone found — nothing to remove."
  fi

  # 2. Ensure the stock menu is the enabled one.
  if omarchy plugin enable omarchy.menu >/dev/null 2>&1; then
    echo "  ✓ Stock omarchy.menu enabled."
  else
    echo "  ! Could not enable omarchy.menu via plugin command." >&2
  fi

  # 3. Repoint bar references that name a removed clone.
  if [[ -f $SHELL_JSON && ${#clone_ids[@]} -gt 0 ]]; then
    for pattern in "${clone_ids[@]}"; do
      if grep -q "\"$pattern\"" "$SHELL_JSON" 2>/dev/null; then
        cp "$SHELL_JSON" "$SHELL_JSON.bak.fix-menu-$(date +%s)"
        sed -i "s/$pattern/omarchy.menu/g" "$SHELL_JSON"
        echo "  ✓ Bar reference repainted to omarchy.menu (backup kept)."
        break
      fi
    done
  fi

  # 4. Restart the shell so every plugin/service rebinds cleanly.
  if omarchy restart shell >/dev/null 2>&1; then
    echo "  ✓ Omarchy shell restarted."
  else
    echo "  ! omarchy restart shell failed — run it manually." >&2
    exit 1
  fi
else
  echo "  ! omarchy command not found — cannot repair from here." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4b. Repair a corrupted custom omarchy-menu.jsonc.
#     A bug in remove_menu_blocks deleted object KEYS by name (e.g. "setup.*":)
#     while leaving their bodies, corrupting the JSON and dropping the
#     mosquitOmarchy / setup.* entries on any module uninstall. Detect that.
# ---------------------------------------------------------------------------
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f $MENU ]]; then
  menu_ok=1
  python3 - "$MENU" >/dev/null 2>&1 <<'PY' || menu_ok=0
import json, re, sys
t = open(sys.argv[1], encoding="utf-8").read()
t = re.sub(r'^\s*//[^\n]*', '', t, flags=re.M)
t = re.sub(r',(\s*[}\]])', r'\1', t)
json.loads(t)
PY
  has_launcher=1; grep -q '"install.mosquitomarchy"' "$MENU" || has_launcher=0
  if (( !menu_ok || !has_launcher )); then
    newest="$(ls -1t "$MENU".bak* 2>/dev/null | head -1)"
    if (( !menu_ok )) && [[ -n $newest ]]; then
      cp -f "$newest" "$MENU"
      echo "  ✓ omarchy-menu.jsonc restored from $(basename "$newest")"
    fi
    if [[ -f "$REPO/setup-customarchy.sh" ]] && ! grep -q '"install.mosquitomarchy"' "$MENU"; then
      ( export GUI_RUN_EXEC=1 MOSQUITOMARCHY_LIB_ONLY=1
        # shellcheck source=/dev/null
        source "$REPO/setup-customarchy.sh"; install_menu_entry ) >/dev/null 2>&1 \
        && echo "  ✓ mosquitOmarchy menu entry re-registered" \
        || echo "  ! Could not re-register the mosquitOmarchy menu entry" >&2
    fi
  else
    echo "  • omarchy-menu.jsonc is valid and lists mosquitOmarchy."
  fi
fi

# ---------------------------------------------------------------------------
# 5. Verify.
# ---------------------------------------------------------------------------
sleep 2
if omarchy-shell shell ping >/dev/null 2>&1 || omarchy shell shell ping >/dev/null 2>&1; then
  echo "  ✓ Shell is healthy again."
else
  echo "  ! Shell not reachable yet — wait a few seconds and re-open the menu." >&2
fi
desktops=$(find /usr/share/applications "$HOME/.local/share/applications" -name '*.desktop' 2>/dev/null | wc -l)
echo "  • $desktops .desktop entries present (Apps should list them again)."
echo "Fix Omarchy menu done. Open the menu to confirm."
