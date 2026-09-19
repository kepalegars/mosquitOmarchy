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
