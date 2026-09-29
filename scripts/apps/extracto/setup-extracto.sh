#!/usr/bin/env bash
# setup-extracto.sh — "extracto": a simple custom install script for file-roller.
#
# WHAT IT IS. A small custom installer that puts file-roller (the GNOME archive
# manager) on the machine and wires it into Nautilus. It is NOT an app and it
# adds NO desktop entry — the point is that Nautilus itself regains its archive
# actions, exactly as they were before Nautilus dropped built-in support.
#
# WHAT IT DOES.
#   - installs file-roller + 7zip + unrar. file-roller links
#     libnautilus-extension and ships the Nautilus C extension, so Nautilus
#     regains "Extract Here" / "Create Archive" and the per-archive actions
#     (list, test, open without extracting, delete inside an archive).
#   - 7zip backs the password-protected and exotic formats (zip AES, 7z, ISO,
#     lha, lrzip) that libarchive alone refuses; unrar is the only backend that
#     reliably applies a RAR password (libarchive silently fails on encrypted
#     RAR — file-roller's "Extract Here" does nothing for them).
#   - sets the common formats to open WITH file-roller (mimeapps.default), so
#     double-clicking an archive really opens it.
#   - hides file-roller's own package .desktop from the apps menu with a user
#     NoDisplay=true override (a FULL copy of the package file — see step 4 for
#     why a bare Hidden stub breaks "Open With"), so the menu is not cluttered
#     with a second archive entry.
#   - installs a Nautilus SCRIPT, "Extract with password"
#     (~/.local/share/nautilus/scripts/), which prompts for the password and
#     extracts with the backend that applies it. This is the fix for
#     password-protected RAR (and any archive file-roller cannot decrypt). It
#     appears in Nautilus' right-click → Scripts menu; it is not a desktop entry.
#   - adds a per-class Hyprland rule: file-roller is a floating GTK4 dialog, so
#     it is floated + centered and exempted from the default window opacity.
#
# Idempotent: may be re-run without risk.
#
# Usage:
#   ./setup-extracto.sh                 # interactive
#   ./setup-extracto.sh -y              # non-interactive (defaults)
#   ./setup-extracto.sh --status        # current state, changes nothing
#   ./setup-extracto.sh --remove        # remove our glue (keeps packages)
#   ./setup-extracto.sh -h              # help
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOME="${HOME}"
HYPR="$REAL_HOME/.config/hypr/hyprland.lua"
APPS_DIR="$REAL_HOME/.local/share/applications"
NAUTILUS_SCRIPTS="$REAL_HOME/.local/share/nautilus/scripts"
FR_PKG_DESKTOP="$APPS_DIR/org.gnome.FileRoller.desktop"
START="-- >>> extracto-setup >>>"
END="-- <<< extracto-setup <<<"

# Archive MIME types we want double-click to open in file-roller. RAR and ISO
# cannot be CREATED by file-roller but opening/extracting them is exactly the
# case that had no working GUI before.
MIME_TYPES=(
  application/zip
  application/x-7z-compressed
  application/x-rar
  application/x-rar-compressed
  application/vnd.rar
  application/x-iso9660-image
  application/x-archive
  application/x-cpio
  application/x-tar
  application/gzip
  application/x-bzip2
  application/x-bzip
  application/x-xz
  application/x-zstd
  application/x-lz4
  application/x-compress
  application/x-compressed-tar
  application/x-xz-c
)

msg()  { echo "==> $*"; }
ok()   { echo "  ok $*"; }
warn() { echo "  !  $*"; }
err()  { echo "  xx $*" >&2; }

YES=0 STATUS_ONLY=0 REMOVE=0
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  --status) STATUS_ONLY=1 ;;
  --remove) REMOVE=1 ;;
  -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (supported: -y --status --remove)" >&2; exit 1 ;;
esac; shift; done

have() { command -v "$1" >/dev/null 2>&1; }
# grep/sed need a guard: the Hyprland markers start with "-", read as an option.
has_block() { grep -qF -- "$1" "$2" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
  msg "extracto status:"
  if have file-roller; then
    ok "file-roller present ($(file-roller --version 2>/dev/null | head -1))"
  else
    warn "file-roller NOT installed — Nautilus has no archive support."
  fi
  for b in 7z unrar bsdtar; do
    have "$b" && ok "backend: $b" || warn "backend missing: $b"
  done
  if [[ -f $HYPR ]] && has_block "$START" "$HYPR"; then
    ok "hyprland block present"
  else
    warn "hyprland block absent"
  fi
  if [[ -f $NAUTILUS_SCRIPTS/Extract-with-password || -f "$NAUTILUS_SCRIPTS/Extract with password" ]]; then
    ok "Nautilus script present (right-click → Scripts → Extract with password)"
  else
    warn "Nautilus script absent"
  fi
  if [[ -f $FR_PKG_DESKTOP ]] && grep -q '^NoDisplay=true' "$FR_PKG_DESKTOP"; then
    if grep -q '^Exec=' "$FR_PKG_DESKTOP"; then
      ok "file-roller menu entry hidden (NoDisplay override, Exec intact)"
    else
      warn "override present but has no Exec= — Open With would do nothing"
    fi
  else
    warn "file-roller package entry not hidden (menu shows a second archive entry)"
  fi
  if have xdg-mime; then
    for t in application/zip application/x-7z-compressed application/x-iso9660-image; do
      printf '    %-34s -> %s\n' "$t" "$(xdg-mime query default "$t" 2>/dev/null || echo -)"
    done
  fi
}

if [[ $STATUS_ONLY == 1 ]]; then show_status; exit 0; fi

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
if [[ $REMOVE == 1 ]]; then
  msg "Removing extracto glue (packages are left in place — remove them manually if unwanted)…"
  if [[ -f $HYPR ]] && has_block "$START" "$HYPR"; then
    sed -i "\|${START#--}|,/${END#--}/d" "$HYPR"
    hyprctl reload >/dev/null 2>&1 || true
    ok "hyprland block removed"
  fi
  # The script was renamed from "Extract-with-password"; clear both spellings.
  legacy_script="$NAUTILUS_SCRIPTS/Extract-with-password"
  script="$NAUTILUS_SCRIPTS/Extract with password"
  if [[ -f $script || -f $legacy_script ]]; then
    rm -f "$script" "$legacy_script"
    ok "Nautilus script removed"
  fi
  # Un-hide file-roller's package entry so it shows in the apps menu again.
  if [[ -f $FR_PKG_DESKTOP ]] && grep -qE '^(Hidden|NoDisplay)=true' "$FR_PKG_DESKTOP"; then
    rm -f "$FR_PKG_DESKTOP"
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    ok "file-roller package entry un-hidden"
  fi
  msg "extracto glue removed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
msg "== 1/5 Packages (file-roller + 7zip + unrar) =="
# file-roller = GUI + Nautilus C extension. 7zip = 7z/zip-AES/ISO/lha/lrzip.
# unrar = the only backend that reliably applies a RAR password. --needed so
# re-running never reinstalls.
mq_sudo pacman -S --needed --noconfirm file-roller 7zip unrar || {
  warn "some archive packages failed to install — continuing with what is there."
}

if ! have file-roller; then
  err "file-roller is not available; Nautilus archive support cannot be restored."
  exit 1
fi
ok "file-roller: $(command -v file-roller)"

# ---------------------------------------------------------------------------
# 2. Defaults: open these archive types in file-roller (double-click works).
# ---------------------------------------------------------------------------
msg "== 2/5 Default app for archive types =="
if have xdg-mime; then
  for t in "${MIME_TYPES[@]}"; do
    xdg-mime default org.gnome.FileRoller.desktop "$t" 2>/dev/null || true
  done
  now=$(xdg-mime query default application/zip 2>/dev/null || echo -)
  if [[ $now == *FileRoller* || $now == *file-roller* ]]; then
    ok "double-clicking a .zip opens file-roller"
  else
    warn ".zip still defaults to '$now' (expected org.gnome.FileRoller.desktop)"
  fi
else
  warn "xdg-mime not found — cannot set default archive app."
fi

# ---------------------------------------------------------------------------
# 3. Hyprland rule: file-roller is a floating dialog, not a tiled app.
# ---------------------------------------------------------------------------
msg "== 3/5 Hyprland rule (float + center file-roller) =="
if [[ -f $HYPR ]]; then
  sed -i "\|${START#--}|,/${END#--}/d" "$HYPR"
  cat >> "$HYPR" <<'EOF'
-- >>> extracto-setup >>> Archive manager window. file-roller is a GTK4 dialog
-- (and its "Create archive" sheet is a second window): float + center it so an
-- archive is not squeezed into a tiled slot, exempt it from the default window
-- opacity so contents stay legible over other windows, and no blur (the dialog
-- draws its own drop area). This is a per-class rule; nothing else is forced.
o.window({ class = "^(File-roller|file-roller|org.gnome.FileRoller)$" }, { tag = "-default-opacity", float = true, center = true, size = { 900, 620 }, opaque = true, no_blur = true })
-- <<< extracto-setup <<<
EOF
  hyprctl reload >/dev/null 2>&1 || true
  ok "hyprland rule installed/updated ($HYPR)"
else
  warn "hyprland config not found at $HYPR — skipped."
fi

# ---------------------------------------------------------------------------
# 4. Keep the apps menu clean: hide file-roller's own package entry.
#    We add NO desktop entry of our own — the whole point is that Nautilus
#    itself regains the archive actions, not that a new app appears in the
#    menu. The package ships /usr/share/applications/org.gnome.FileRoller.desktop
#    and a user file of the same name SHADOWS it (user dirs win over system
#    dirs), so a package update cannot bring the entry back.
# ---------------------------------------------------------------------------
msg "== 4/5 Hide file-roller's package menu entry (no desktop entry of our own) =="
FR_SRC_DESKTOP="/usr/share/applications/org.gnome.FileRoller.desktop"
mkdir -p "$APPS_DIR"
if [[ -f $FR_SRC_DESKTOP ]]; then
  # It must be a FULL copy plus NoDisplay=true — never a bare "Name + Hidden"
  # stub like the one superfile uses for spf. Because the user file shadows the
  # package file rather than merging with it, a stub would replace the real
  # entry and take its Exec and MimeType away: mimeapps.list still points every
  # archive type at org.gnome.FileRoller.desktop, so Nautilus' right-click
  # "Open With → File Roller" and a double-click on a .zip would resolve to a
  # file with no Exec and silently do nothing. NoDisplay keeps the entry valid
  # while hiding it — the Omarchy menu skips both Hidden and NoDisplay
  # (shell/services/hidden-entries.sh), and GIO only drops Hidden entries from
  # application lists; NoDisplay merely means "not shown in menus".
  awk '
    /^\[Desktop Entry\]$/ { print; print "NoDisplay=true"; next }
    /^NoDisplay=/ { next }
    { print }
  ' "$FR_SRC_DESKTOP" > "$FR_PKG_DESKTOP"
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  if grep -q '^Exec=' "$FR_PKG_DESKTOP" && grep -q '^NoDisplay=true' "$FR_PKG_DESKTOP"; then
    ok "file-roller menu entry hidden — Exec/MimeType kept, so Open With still works"
  else
    warn "override written but looks incomplete (check $FR_PKG_DESKTOP)"
  fi
else
  warn "package desktop file not found at $FR_SRC_DESKTOP — nothing to hide."
fi

# ---------------------------------------------------------------------------
# 5. Nautilus script: password-protected extraction (the RAR fix).
# ---------------------------------------------------------------------------
msg "== 5/5 Nautilus script (Extract with password) =="
mkdir -p "$NAUTILUS_SCRIPTS"
# Spaces, not dashes: Nautilus shows the file name verbatim in the Scripts
# submenu, so "Extract-with-password" reads as a hyphenated slug there.
rm -f "$NAUTILUS_SCRIPTS/Extract-with-password"
cp "$SCRIPT_DIR/extract-with-password" "$NAUTILUS_SCRIPTS/Extract with password"
chmod +x "$NAUTILUS_SCRIPTS/Extract with password"
bash -n "$NAUTILUS_SCRIPTS/Extract with password" || { err "script syntax invalid"; exit 1; }
ok "Nautilus script installed → right-click an archive → Scripts → Extract with password"

# ---------------------------------------------------------------------------
# Done.
# ---------------------------------------------------------------------------
msg "== Done =="
ok "file-roller + 7zip + unrar installed"
ok "Nautilus: right-click an archive → Extract Here (and Create Archive)"
ok "password-protected archives: Scripts → Extract with password (works for RAR)"
echo
msg "Password-protected archives:"
echo "  • right-click the archive → Scripts → Extract with password, enter the password."
echo "  • RAR is handled by unrar, everything else by 7z — both apply the password."
echo "  • file-roller's own Extract Here still covers unencrypted archives."
echo
echo "Done. Run './setup-extracto.sh --status' to verify."
