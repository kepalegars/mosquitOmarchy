#!/usr/bin/env bash
# Shared cleanup of the launcher entries Wine publishes for a program that
# mosquitOmarchy installs AND uninstalls itself.
#
# Why this file exists: a Windows installer drops its shortcuts into the Windows
# Start Menu (ProgramData/Microsoft/Windows/Start Menu/Programs), and Wine then
# republishes every one of them into
# ~/.local/share/applications/wine/Programs/<vendor>/<app>/*.desktop. For an app
# mosquitOmarchy manages, those entries are pure noise:
#
#   * "Uninstall" launches unins000.exe from the app launcher, while the whole
#     point of the module is that uninstalling happens from mosquitOmarchy;
#   * "Manual" opens a PDF in a wine window;
#   * "Guitar Pro 8" duplicates the entry the module already wrote, so the same
#     application shows up twice;
#   * the whole "Wine / Programs / …" publisher chain stays in the menu even
#     once every entry inside it is gone.
#
# What is NEVER touched: the file-association entries (wine-extension-* /
# wine-protocol-*, NoDisplay=true). Those are what makes "open a .gp5 with
# Guitar Pro" work, and they are not launcher clutter.
#
# Source it, do not execute it.

# ── Locations ────────────────────────────────────────────────────────────────
MQ_WM_APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
MQ_WM_DD="${XDG_DATA_HOME:-$HOME/.local/share}/desktop-directories"
MQ_WM_ROOT="$MQ_WM_APPS/wine"
MQ_WM_PROGRAMS="$MQ_WM_ROOT/Programs"

# Refresh the menu caches after having touched the entries.
mosquitomarchy_wine_menu_refresh() {
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$MQ_WM_APPS" >/dev/null 2>&1
  return 0
}

# Wine names a publisher after its path: wine/Programs/<a>/<b> becomes
# "wine-Programs-a-b.directory" (slashes become dashes, spaces are kept).
# The name is only ever *written*, never parsed back — a folder whose name
# contains a dash would make the reverse mapping ambiguous, so the orphan sweep
# below rebuilds the set of live names from the tree instead.
mosquitomarchy_wine_menu_publisher_name() {
  local rel="${1#"$MQ_WM_ROOT"}"
  printf 'wine%s.directory' "${rel//\//-}"
}
mosquitomarchy_wine_menu_publisher_file() {
  local rel="${1#"$MQ_WM_ROOT"/}"
  [[ -n $rel && $rel != "$1" ]] || return 1
  printf '%s/%s' "$MQ_WM_DD" "$(mosquitomarchy_wine_menu_publisher_name "$1")"
}

# Drop a directory and every now-empty ancestor up to wine/, taking the matching
# .directory publishers with them. Emptiness is what decides: a publisher whose
# folder still holds an entry stays, so a partially cleaned vendor tree does
# not lose its menu row.
mosquitomarchy_wine_menu_prune() {
  local d="$1" pub pruned=0
  while [[ -n $d && $d == "$MQ_WM_ROOT"* && $d != "$MQ_WM_ROOT" ]]; do
    [[ -d $d ]] || { d="$(dirname "$d")"; continue; }
    # -print -quit: a directory holding only hidden files is not empty either.
    if [[ -n $(find "$d" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
      break
    fi
    if pub="$(mosquitomarchy_wine_menu_publisher_file "$d")" && [[ -f $pub ]]; then
      rm -f "$pub" && pruned=$((pruned + 1))
    fi
    rmdir "$d" 2>/dev/null || break
    pruned=$((pruned + 1))
    d="$(dirname "$d")"
  done
  printf '%s' "$pruned"
}

# Is this .desktop one of our own entries (a real launcher) or a hidden
# file-association helper? NoDisplay=true means "do not show me in a menu",
# which is exactly the association entries: keep them.
mosquitomarchy_wine_menu_is_launcher() {
  local f="$1"
  [[ -f $f ]] || return 1
  grep -qiE '^[[:space:]]*NoDisplay[[:space:]]*=[[:space:]]*true' "$f" && return 1
  return 0
}

# mosquitomarchy_wine_menu_remove <pattern>...
#   Removes every wine/Programs entry whose path or content matches one of the
#   (extended regex, case-insensitive) patterns, prunes the emptied publisher
#   chain and refreshes the caches. Prints one line per removal.
mosquitomarchy_wine_menu_remove() {
  (($#)) || return 0
  local f pat removed=0
  [[ -d $MQ_WM_PROGRAMS ]] || return 0
  while IFS= read -r -d '' f; do
    mosquitomarchy_wine_menu_is_launcher "$f" || continue
    for pat in "$@"; do
      if printf '%s' "$f" | grep -qiE "$pat" || grep -qiE "$pat" "$f" 2>/dev/null; then
        rm -f "$f" && { printf 'removed %s\n' "${f#"$MQ_WM_APPS"/}"; removed=1; }
        mosquitomarchy_wine_menu_prune "$(dirname "$f")" >/dev/null
        break
      fi
    done
  done < <(find "$MQ_WM_PROGRAMS" -type f -name '*.desktop' -print0 2>/dev/null)
  ((removed)) && mosquitomarchy_wine_menu_refresh
  return 0
}

# mosquitomarchy_wine_menu_remove_for_prefix <prefix>...
#   Same, but scoped by the WINEPREFIX an entry pins in its Exec=. That is the
#   precise way to clean "everything this prefix published": it cannot touch a
#   shortcut belonging to a prefix mosquitOmarchy does not own.
mosquitomarchy_wine_menu_remove_for_prefix() {
  (($#)) || return 0
  local f pfx removed=0
  [[ -d $MQ_WM_PROGRAMS ]] || return 0
  while IFS= read -r -d '' f; do
    mosquitomarchy_wine_menu_is_launcher "$f" || continue
    for pfx in "$@"; do
      if grep -qF "WINEPREFIX=$pfx" "$f" 2>/dev/null; then
        rm -f "$f" && { printf 'removed %s\n' "${f#"$MQ_WM_APPS"/}"; removed=1; }
        mosquitomarchy_wine_menu_prune "$(dirname "$f")" >/dev/null
        break
      fi
    done
  done < <(find "$MQ_WM_PROGRAMS" -type f -name '*.desktop' -print0 2>/dev/null)
  ((removed)) && mosquitomarchy_wine_menu_refresh
  return 0
}

# mosquitomarchy_wine_menu_prune_orphans
#   Drops every wine-Programs*.directory with nothing left to publish: the
#   folder is gone (a manual rm, an earlier version of this file) or empty. The
#   live set is rebuilt from the tree rather than parsed out of the file names,
#   so a vendor whose name contains a dash cannot lose a live publisher.
mosquitomarchy_wine_menu_prune_orphans() {
  [[ -d $MQ_WM_DD ]] || return 0
  local live="" f d name
  while IFS= read -r -d '' d; do
    # Only a directory that still holds something is worth a menu row.
    [[ -n $(find "$d" -mindepth 1 -print -quit 2>/dev/null) ]] || continue
    live+=" $(mosquitomarchy_wine_menu_publisher_name "$d")"
  done < <(find "$MQ_WM_ROOT" -mindepth 1 -type d -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    name="$(basename "$f")"
    [[ $live == *" $name "* ]] && continue
    rm -f "$f" && printf 'removed %s\n' "${f#"$HOME/.local/share/"}"
  done < <(find "$MQ_WM_DD" -maxdepth 1 -type f -name 'wine*.directory' -print0 2>/dev/null)
  return 0
}

# mosquitomarchy_wine_menu_sweep [prefix...]
#   The call a module makes at the end of its own setup: drop every launcher
#   entry those prefixes published, plus the orphaned publishers left behind by
#   an earlier run. With no argument it only prunes what is already empty.
mosquitomarchy_wine_menu_sweep() {
  local d
  if (($#)); then
    mosquitomarchy_wine_menu_remove_for_prefix "$@"
  fi
  # Second pass: publishers whose folder is empty — a previous run, or a manual
  # rm, leaves those behind and the menu keeps an empty "Wine/Programs" row.
  if [[ -d $MQ_WM_ROOT ]]; then
    while IFS= read -r -d '' d; do
      mosquitomarchy_wine_menu_prune "$d" >/dev/null
    done < <(find "$MQ_WM_ROOT" -mindepth 1 -type d -print0 2>/dev/null)
    # wine/ itself, once empty, is dead weight too.
    [[ -n $(find "$MQ_WM_ROOT" -mindepth 1 -print -quit 2>/dev/null) ]] || rmdir "$MQ_WM_ROOT" 2>/dev/null
  fi
  mosquitomarchy_wine_menu_prune_orphans
  mosquitomarchy_wine_menu_refresh
  return 0
}


# mosquitomarchy_wine_menu_disable_publishing <prefix>
#   Stops Wine from republishing Start-Menu shortcuts in that prefix, by
#   clearing the winemenubuilder override the way ableton-linux's installer
#   does. Only for prefixes whose associations nobody needs: it also stops the
#   wine-extension-*/wine-protocol-* files from being (re)created.
mosquitomarchy_wine_menu_disable_publishing() {
  local pfx="${1:?prefix required}" wine_bin="${2:-wine}"
  [[ -d $pfx ]] || return 0
  WINEPREFIX="$pfx" "$wine_bin" reg add 'HKCU\Software\Wine\DllOverrides' \
    /v winemenubuilder.exe /t REG_SZ /d '' /f >/dev/null 2>&1
}

# mosquitomarchy_wine_menu_report
#   One line per launcher entry still published, for a --status/doctor display.
mosquitomarchy_wine_menu_report() {
  local f
  [[ -d $MQ_WM_PROGRAMS ]] || return 0
  while IFS= read -r -d '' f; do
    mosquitomarchy_wine_menu_is_launcher "$f" || continue
    printf '%s\n' "${f#"$MQ_WM_APPS"/}"
  done < <(find "$MQ_WM_PROGRAMS" -type f -name '*.desktop' -print0 2>/dev/null)
  return 0
}
