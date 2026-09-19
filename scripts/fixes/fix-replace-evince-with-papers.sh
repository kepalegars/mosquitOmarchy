#!/usr/bin/env bash
# fix-replace-evince-with-papers.sh — Optional: replace Evince with Papers (GNOME documents).
#
# PART OF THE APPS MODULE, but NOT part of guis.catalog: replacing the system
# document viewer is a deliberate system-wide change, so it is a standalone
# OPTIONAL script (run it when you actually want the swap).
#
#   • Installs Papers (Arch official package `papers`, via yay).
#   • Makes Papers the default handler for every document MIME type it
#     advertises (application/pdf, ps, djvu, tiff, comics, …).
#   • Hides Evince from the app menu (XDG NoDisplay override). Evince itself
#     stays INSTALLED: gnome-sushi (the Nautilus previewer) depends on its
#     libraries, and evince's own PDF backend is what makes the in-file-manager
#     preview work. So after this script the user-facing viewer is Papers,
#     while Nautilus previews (sushi → evince) keep working — evince just
#     becomes an invisible backend.
#   • Floats Papers in Hyprland ("untiled"): a document viewer doesn't belong
#     tiled in a split — it opens as a normal floating window instead.
#   • Adapts GNOME/GTK apps to the current Omarchy theme (dark scheme + accent
#     color mapped to the palette) and registers a theme-set.d hook so every
#     future Omarchy theme switch re-applies it ("dynamic" theming). This is
#     interface-wide (org.gnome.desktop.interface): it covers Papers, Nautilus
#     and every other GNOME/GTK app, not just Papers.
#
# Usage :
#   ./fix-replace-evince-with-papers.sh            # apply the swap (asks nothing, idempotent)
#   ./fix-replace-evince-with-papers.sh -y         # same (no prompts)
#   ./fix-replace-evince-with-papers.sh --status   # current state, nothing done
#   ./fix-replace-evince-with-papers.sh --uninstall  # restore Evince as viewer, remove the
#                                  # menu-hide, the float rule and the hook
#                                  # (papers/evince packages are left alone)
#   ./fix-replace-evince-with-papers.sh -h
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.bash"

PAPERS="papers"
PAPERS_DESKTOP="org.gnome.Papers.desktop"
PAPERS_PREVIEW_APPID="org.gnome.Papers-previewer"
EVINCE_DESKTOPS=(org.gnome.Evince.desktop org.gnome.Evince-previewer.desktop)
# The Evince package must stay installed even after the swap: sushi (Nautilus
# preview) depends on it. Removing evince would break the file-manager preview.
NEED_KEEP_EVINCE=1

LOCAL_APPS_DIR="$HOME/.local/share/applications"
CONF="$HOME/.config/hypr/hyprland.lua"
HOOKS_DIR="$HOME/.config/omarchy/hooks/theme-set.d"
THEME_HOOK="$HOOKS_DIR/gnome-gtk-theme.sh"
PALETTE="$HOME/.local/state/omarchy/current/theme/colors.toml"

# Papers window(s) float rule — "untiled" (reuses Omarchy's floating-window
# tag, same pattern as scripts/fixes/fix-keepassxc-window.sh).
FLOAT_MARK_START="-- >>> papers-window-setup >>>"
FLOAT_MARK_END="-- <<< papers-window-setup <<<"

# Representative GNOME accent-color swatches (org.gnome.desktop.interface
# accent-color is an enum: blue teal green yellow orange red pink purple slate).
GNOME_ACCENTS="blue:3584e4 teal:2190a4 green:2ec27e yellow:f5c211 orange:ff7800 red:e01b24 pink:ff61a8 purple:9141ac slate:5e5c64"

YES=0 STATUS_ONLY=0 UNINSTALL=0
for a in "$@"; do case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --uninstall) UNINSTALL=1 ;;
  -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (see -h)" >&2; exit 1 ;;
esac; done

# Maps a palette accent hex to the nearest GNOME accent-color enum name.
gnome_accent(){
  local hex="${1#\#}"
  [[ $hex =~ ^[0-9A-Fa-f]{6}$ ]] || { echo ""; return 0; }
  local r g b aname
  if command -v awk >/dev/null; then
    local res
    res="$(echo "$GNOME_ACCENTS" | awk -v h="$hex" '
      function hr(x){ return strtonum("0x" substr(x,1,2)); }
      BEGIN{
        n=split("'"$GNOME_ACCENTS"'",a," ")   # a[i] = "name:rrggbb"
        hx=hr(h); hy=hr(substr(h,3,2)); hz=hr(substr(h,5,2))
        best="-1"; bd=1e9
        for(i=1;i<=n;i++){
          split(a[i],t,":"); c=t[2]
          dx=hx-hr(c); dy=hy-hr(substr(c,3,2)); dz=hz-hr(substr(c,5,2))
          d=dx*dx+dy*dy+dz*dz
          if(d<bd){ bd=d; best=t[1] }
        }
        print best
      }')"
    [[ -n $res ]] && echo "$res"
  fi
}

# Papers default handler for every MIME type it advertises
set_papers_defaults(){
  local mimes
  mimes="$(grep -E '^MimeType=' /usr/share/applications/$PAPERS_DESKTOP 2>/dev/null | sed 's/^MimeType=//' || true)"
  [[ -n $mimes ]] || { warn "No MimeType found in $PAPERS_DESKTOP — default handlers skipped."; return 0; }
  local m
  mimes="${mimes%;}"
  IFS=';' read -ra parts <<<"$mimes"
  local n=0
  for m in "${parts[@]:-}"; do
    [[ -n $m ]] || continue
    xdg-mime default "$PAPERS_DESKTOP" "$m" 2>/dev/null || true
    n=$((n+1))
  done
  ok "Papers set as default handler for $n document MIME types"
  echo "  default viewer for PDF/PS/DjVu/TIFF/comic books: $(xdg-mime query default application/pdf 2>/dev/null)"
}

# Hides Evince from the app menus (overrides in ~/.local/share/applications).
# The PACKAGE stays installed — sushi (Nautilus preview) needs it as a backend.
hide_evince_menus(){
  mkdir -p "$LOCAL_APPS_DIR"
  local d
  for d in "${EVINCE_DESKTOPS[@]}"; do
    if [[ -f /usr/share/applications/$d ]]; then
      cat > "$LOCAL_APPS_DIR/$d" <<EOF
[Desktop Entry]
NoDisplay=true
EOF
    fi
  done
  ok "Evince hidden from the app menus (NoDisplay) — package kept for Nautilus/Sushi previews"
}

show_evince_menus(){
  local d
  for d in "${EVINCE_DESKTOPS[@]}"; do
    rm -f "$LOCAL_APPS_DIR/$d"
  done
  [[ -f /usr/share/applications/${EVINCE_DESKTOPS[0]} ]] && ok "Evince visible again in the menu"
}

# Hyprland float rule for Papers (and its previewer window)
install_float_rule(){
  mkdir -p "$HOME/.config/hypr"
  touch "$CONF"
  sed -i "/$FLOAT_MARK_START/,/$FLOAT_MARK_END/d" "$CONF"
  cat >> "$CONF" <<EOF
$FLOAT_MARK_START float Papers instead of tiling it — a document viewer
-- opens as a normal ("untiled") floating window, like KeePassXC above.
o.window("org.gnome.Papers", { tag = "+floating-window" })
o.window("$PAPERS_PREVIEW_APPID", { tag = "+floating-window" })
$FLOAT_MARK_END
EOF
  hyprctl reload >/dev/null 2>&1 || true
  ok "Hyprland float rule for Papers installed/updated ($CONF)"
}

remove_float_rule(){
  [[ -f $CONF ]] && sed -i "/$FLOAT_MARK_START/,/$FLOAT_MARK_END/d" "$CONF"
  hyprctl reload >/dev/null 2>&1 || true
  ok "Papers float rule removed from $CONF"
}

# ──────────────────── GNOME/GTK dynamic theme (interface-wide) ────────────────────
# Reads the CURRENT Omarchy palette and pushes dark scheme + accent to
# org.gnome.desktop.interface (covers Papers, Nautilus and every GTK app).
apply_palette_now(){
  [[ -r $PALETTE ]] || { warn "No Omarchy palette at $PALETTE — theme adaptation skipped (runs on next theme change via the hook)."; return 0; }
  local mode accent
  mode="$(sed -n 's/^mode = "\([^"]*\)"/\1/p' "$PALETTE" | head -1)"
  accent="$(sed -n 's/^accent = "#\([0-9A-Fa-f]\{6\}\)"/\1/p' "$PALETTE" | head -1)"
  if [[ -n $mode ]] && command -v gsettings >/dev/null; then
    if [[ $mode == dark ]]; then gsettings set org.gnome.desktop.interface color-scheme prefer-dark 2>/dev/null || true
    else gsettings set org.gnome.desktop.interface color-scheme default 2>/dev/null || true; fi
    ok "GNOME color-scheme set to $(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null) (palette mode=$mode)"
  fi
  local gname
  gname="$(gnome_accent "$accent")"
  if [[ -n $gname ]] && command -v gsettings >/dev/null; then
    gsettings set org.gnome.desktop.interface accent-color "$gname" 2>/dev/null || true
    ok "GNOME accent-color set to $(gsettings get org.gnome.desktop.interface accent-color 2>/dev/null) (palette accent #$accent → $gname)"
  fi
}

write_theme_hook(){
  mkdir -p "$HOOKS_DIR"
  cat > "$THEME_HOOK" <<EOF
#!/bin/bash
# Installed by fix-replace-evince-with-papers.sh -- keeps GNOME/GTK apps (Papers, Nautilus, …)
# in sync with Omarchy's active theme every time it changes. Re-reads the
# CURRENT theme palette (~/.local/state/omarchy/current/theme/colors.toml)
# rather than the \$1 argument, so it stays correct even if invoked out of
# order (same pattern as the superfile-module theme hook).
PALETTE="\$HOME/.local/state/omarchy/current/theme/colors.toml"
[[ -r \$PALETTE ]] || exit 0
mode="\$(sed -n 's/^mode = "\\([^"]*\\)"/\\1/p' "\$PALETTE" | head -1)"
accent="\$(sed -n 's/^accent = "#\\([0-9A-Fa-f]\\{6\\}\\)"/\\1/p' "\$PALETTE" | head -1)"
command -v gsettings >/dev/null || exit 0
[[ -n \$mode ]] && { [[ \$mode == dark ]] && gsettings set org.gnome.desktop.interface color-scheme prefer-dark || gsettings set org.gnome.desktop.interface color-scheme default; }
[[ -n \$accent ]] && {
  gname="\$(echo "$GNOME_ACCENTS" | awk -v h="\$accent" '
    function hr(x){ return strtonum("0x" substr(x,1,2)); }
    BEGIN{
      n=split("'"$GNOME_ACCENTS"'",a," ")
      hx=hr(h); hy=hr(substr(h,3,2)); hz=hr(substr(h,5,2))
      best="-1"; bd=1e9
      for(i=1;i<=n;i++){ split(a[i],t,":"); c=t[2]
        dx=hx-hr(c); dy=hy-hr(substr(c,3,2)); dz=hz-hr(substr(c,5,2))
        d=dx*dx+dy*dy+dz*dz; if(d<bd){ bd=d; best=t[1] } }
      print best }')"
  [[ -n \$gname ]] && gsettings set org.gnome.desktop.interface accent-color "\$gname"
}
EOF
  chmod +x "$THEME_HOOK"
  ok "Omarchy theme-change hook registered ($THEME_HOOK) — GNOME theme follows every theme switch"
}

# ─────────────────────────────── Status ───────────────────────────────
do_status(){
  hr; msg "State of the Evince → Papers swap"
  printf "  %-38s %s\n" "papers package" "$(pkg_has $PAPERS && echo installed || echo NOT installed)"
  printf "  %-38s %s\n" "evince package (kept for sushi)" "$(pkg_has evince && echo installed || echo NOT installed)"
  printf "  %-38s %s\n" "PDF default handler" "$(xdg-mime query default application/pdf 2>/dev/null || echo none)"
  local hidden=0 d
  for d in "${EVINCE_DESKTOPS[@]}"; do [[ -f $HOME/.local/share/applications/$d ]] && hidden=1; done
  printf "  %-38s %s\n" "Evince hidden from menu" "$([[ $hidden == 1 ]] && echo yes || echo no)"
  grep -q -- "$FLOAT_MARK_START" "$CONF" 2>/dev/null && printf "  %-38s %s\n" "Hyprland float rule (Papers)" "active" || printf "  %-38s %s\n" "Hyprland float rule (Papers)" "inactive"
  printf "  %-38s %s\n" "GNOME theme hook" "$([[ -x $THEME_HOOK ]] && echo active || echo inactive)"
  printf "  %-38s %s\n" "GNOME color-scheme" "$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || echo n/a)"
  printf "  %-38s %s\n" "GNOME accent-color" "$(gsettings get org.gnome.desktop.interface accent-color 2>/dev/null || echo n/a)"
  hr
}

# ─────────────────────────────── Main ───────────────────────────────
main(){
  if ((STATUS_ONLY)); then do_status; exit 0; fi

  if ((UNINSTALL)); then
    hr
    msg "Restoring Evince as document viewer (Papers swap removal)"
    xdg-mime default org.gnome.Evince.desktop application/pdf 2>/dev/null || true
    show_evince_menus
    remove_float_rule
    rm -f "$THEME_HOOK"
    ok "Restored. Evince back as PDF default, menus restored, float rule and theme hook removed."
    ok "Note: Papers stays installed (pure switch, no package removed). Remove it with:  sudo pacman -Rns papers"
    hr
    exit 0
  fi

  hr
  msg "Optional: replacing Evince with Papers (GNOME documents)"

  # 1. Install Papers (Arch official package, refresh if needed)
  if ! pkg_has $PAPERS; then
    msg "Installing: $PAPERS"
    require_yay || exit 1
    yay -S --needed --noconfirm $PAPERS || { err "$PAPERS : INSTALL FAILED"; exit 1; }
    ok "$PAPERS : installed"
  else
    ok "$PAPERS : already installed"
  fi

  # 2. Papers default handler + 3. menu-hide for Evince (package kept for sushi)
  set_papers_defaults
  hide_evince_menus

  # 4. "Untiled": float Papers in Hyprland
  install_float_rule

  # 5. Dynamic theme: apply now + hook for every future theme switch
  apply_palette_now
  write_theme_hook

  hr
  ok "Done. Papers is now your document viewer (opens floating); Nautilus previews still work via sushi/evince."
  echo "  • Re-run this script any time to refresh defaults/hide (idempotent)."
  echo "  • Revert:  ./fix-replace-evince-with-papers.sh --uninstall"
  echo "  • Status:  ./fix-replace-evince-with-papers.sh --status"
  hr
}

main "$@"