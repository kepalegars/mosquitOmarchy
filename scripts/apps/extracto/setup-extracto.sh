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
#     lha, lrzip) that libarchive alone refuses, unrar backs RAR. With both
#     present, file-roller's own "Extract Here" prompts for the password
#     itself — no helper script of ours is involved.
#   - makes sure file-roller is NOT the default application for archive types.
#     The desktop ships file-roller's Nautilus C extension, so Nautilus offers
#     "Extract Here" / "Create Archive" on its own; binding archive MIME types to
#     file-roller would OVERRIDE Nautilus rather than enable it, because
#     `xdg-mime default` replaces the candidate list with a single app. This step
#     only removes what older revisions of this script wrote.
#   - hides file-roller's own package .desktop from the apps menu with a user
#     NoDisplay=true override (a FULL copy of the package file — see step 4 for
#     why a bare Hidden stub breaks "Open With"), so the menu is not cluttered
#     with a second archive entry.
#   - adds a per-class Hyprland rule: file-roller is a floating GTK4 dialog, so
#     it is floated + centered and exempted from the default window opacity.
#
# That is the whole module: packages + one association cleanup + two config
# edits. It installs NOTHING into ~/.local/share/nautilus/scripts and no desktop
# entry of its own.
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
FR_PKG_DESKTOP="$APPS_DIR/org.gnome.FileRoller.desktop"
START="-- >>> extracto-setup >>>"
END="-- <<< extracto-setup <<<"

# The archive MIME types the old revisions of this script used to bind to
# file-roller. Kept ONLY to undo those bindings: unbind_file_roller_defaults
# removes exactly these types, so it can never take an association this module
# did not write. Nothing here is registered any more. RAR and ISO are in the
# list because opening/extracting them was the case with no working GUI.
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
  -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a (supported: -y --status --remove)" >&2; exit 1 ;;
esac; shift; done

have() { command -v "$1" >/dev/null 2>&1; }
# grep/sed need a guard: the Hyprland markers start with "-", read as an option.
has_block() { grep -qF -- "$1" "$2" 2>/dev/null; }

# Remove the single-app archive associations this module used to write.
#
# Only lines that assign EXACTLY org.gnome.FileRoller.desktop are touched, and
# only inside [Default Applications] / [Added Associations]. A line listing file-
# roller alongside another app (`zip=org.gnome.FileRoller.desktop;org.gnome.
# Nautilus.desktop;`) is a candidate LIST the user or the distro wrote; dropping
# file-roller from it would be us silently re-deciding for them, which is the
# exact behaviour this function exists to undo. Left alone.
#
# Groups left empty by the removal are dropped too: a bare "[Added Associations]"
# with no entries is noise, and some MIME parsers treat an empty group as
# "nothing allowed" rather than "nothing specified".
unbind_file_roller_defaults() {
  python3 - "${MIME_TYPES[@]}" <<'PY'
import pathlib, sys

WANTED = set(sys.argv[1:])
APPS = ("org.gnome.FileRoller.desktop", "org.gnome.file-roller.desktop")
GROUPS = ("[Default Applications]", "[Added Associations]")

# xdg-mime picks one of these depending on its version and XDG_DATA_HOME.
candidates = [
    pathlib.Path.home()/".config/mimeapps.list",
    pathlib.Path.home()/".local/share/applications/mimeapps.list",
]
changed = []
for path in candidates:
    if not path.is_file():
        continue
    lines = path.read_text(encoding="utf-8").splitlines()
    group, dropped = None, 0
    kept, ours, kept_count = [], {}, {}
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            group = stripped
            kept.append(line)
            continue
        is_ours = False
        if group in GROUPS and "=" in stripped:
            mime, apps = stripped.split("=", 1)
            names = [a for a in apps.split(";") if a]
            # Ours only if: an archive type this script registered, AND
            # file-roller standing alone. Either check failing -> hands off.
            is_ours = (
                mime in WANTED
                and bool(names)
                and all(a in APPS for a in names)
            )
        if is_ours:
            dropped += 1
            ours[group] = ours.get(group, 0) + 1
        else:
            kept.append(line)
            if group is not None and stripped and not is_ours:
                kept_count[group] = kept_count.get(group, 0) + 1
    if not dropped:
        continue
    # Drop a group header ONLY if every one of its entries was ours. If we
    # removed some and kept others, the header must stay or the survivors end
    # up outside any section, which is not a valid mimeapps.list.
    dead = {g for g, n in ours.items() if kept_count.get(g, 0) == 0}
    final, i = [], 0
    while i < len(kept):
        if kept[i].strip() in dead:
            i += 1
            while i < len(kept) and not kept[i].strip():
                i += 1
            continue
        final.append(kept[i])
        i += 1
    path.write_text("\n".join(final).rstrip("\n") + "\n", encoding="utf-8")
    changed.append(f"{path} — {dropped} archive association(s) removed")

# Emitted with the module's own two-space "  ok " prefix so this line lines up
# with every other status line instead of printing a bare "ok " at column 0.
for c in changed:
    print(f"  ok {c}")
if not changed:
    print("  ok no file-roller default to remove (already clean)")
PY
}

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
  if [[ -f $FR_PKG_DESKTOP ]] && grep -q '^NoDisplay=true' "$FR_PKG_DESKTOP"; then
    if grep -q '^Exec=' "$FR_PKG_DESKTOP"; then
      ok "file-roller menu entry hidden (NoDisplay override, Exec intact)"
    else
      warn "override present but has no Exec= — Open With would do nothing"
    fi
  else
    warn "file-roller package entry not hidden (menu shows a second archive entry)"
  fi
  # Report OUR config, which is the only thing this module can be responsible
  # for. The resolved default is the distro's ordering in mimeinfo.cache and
  # says nothing about what we wrote.
  if grep -q 'File[Rr]oller' "$REAL_HOME/.config/mimeapps.list" \
                   "$REAL_HOME/.local/share/applications/mimeapps.list" 2>/dev/null; then
    warn "file-roller is pinned as default in the user config — re-run to clear"
  else
    ok "file-roller is not the default archive app (Nautilus handles extraction)"
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
  # Legacy cleanup: extracto used to install a Nautilus script ("Extract with
  # password", previously "Extract-with-password"). It is gone — file-roller
  # prompts for the password itself — but --remove must still clear both
  # spellings out of an older install.
  for legacy_script in "$REAL_HOME/.local/share/nautilus/scripts/Extract with password" \
                       "$REAL_HOME/.local/share/nautilus/scripts/Extract-with-password"; do
    if [[ -f $legacy_script ]]; then
      rm -f "$legacy_script"
      ok "legacy Nautilus script removed ($(basename "$legacy_script"))"
    fi
  done
  # Un-hide file-roller's package entry so it shows in the apps menu again.
  if [[ -f $FR_PKG_DESKTOP ]] && grep -qE '^(Hidden|NoDisplay)=true' "$FR_PKG_DESKTOP"; then
    rm -f "$FR_PKG_DESKTOP"
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    ok "file-roller package entry un-hidden"
  fi
  # Any file-roller default that an older revision pinned must go too — it is
  # our glue, and leaving it would keep exactly the behaviour --remove promises
  # to undo.
  unbind_file_roller_defaults
  msg "extracto glue removed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
msg "== 1/4 Packages (file-roller + 7zip + unrar) =="
# file-roller = GUI + Nautilus C extension. 7zip = 7z/zip-AES/ISO/lha/lrzip.
# unrar = the backend that applies a RAR password. --needed so re-running never
# reinstalls.
#
# Skip pacman entirely when the three are already there. A plain
# `pacman -S --needed` on an up-to-date machine still prints, in RED:
#   warning: file-roller-44.7-1 is up to date -- skipping
#   warning: 7zip-26.03-1 is up to date -- skipping
#   warning: unrar-1:7.2.7-1 is up to date -- skipping
#    there is nothing to do
# which reads as a failure in a log that otherwise ends "completed without
# error" — three red "warning" lines for a step that did exactly what was
# asked. (The TUI judges a run by its exit code, not by these markers, so the
# module really did pass; it just LOOKED broken.)
if have file-roller && have 7z && have unrar; then
  ok "already installed: file-roller + 7zip + unrar (nothing to do)"
else
  mq_sudo pacman -S --needed --noconfirm file-roller 7zip unrar || {
    warn "some archive packages failed to install — continuing with what is there."
  }
fi

if ! have file-roller; then
  err "file-roller is not available; Nautilus archive support cannot be restored."
  exit 1
fi
ok "file-roller: $(command -v file-roller)"

# ---------------------------------------------------------------------------
# 2. NOT a default app. Undo the one we used to set.
# ---------------------------------------------------------------------------
# Earlier revisions ran `xdg-mime default org.gnome.FileRoller.desktop <type>`
# for every archive MIME type, so that double-clicking an archive would open
# file-roller. That was the wrong thing to do, and it is worth being precise
# about why, because the fix is not "stop setting it" but "remove it".
#
# `xdg-mime default` writes `application/zip=org.gnome.FileRoller.desktop` into
# ~/.config/mimeapps.list — a single app, no list. That does not ADD file-roller
# to the candidates, it REPLACES the candidate list with one entry. The system
# default in /usr/share/applications/mimeinfo.cache is a list:
#
#   application/gzip=org.gnome.FileRoller.desktop;org.gnome.Nautilus.desktop;
#
# so Nautilus was a co-candidate and our override deleted it from the running.
# The user's stated preference is that extraction belongs to Nautilus: file-roller
# stays installed (that is the whole point of this module — it is the GUI and the
# Nautilus C extension) but it must not be the application a double-click routes
# to.
#
# So this step is a repair, not a setting. Dropping the calls would leave every
# machine that already ran the old installer pinned to file-roller forever,
# because ~/.config/mimeapps.list outlives the script that wrote it.
msg "== 2/4 Not the default archive app (Nautilus handles extraction) =="
unbind_file_roller_defaults

# What this module is responsible for is the USER config, so that is what gets
# reported. `xdg-mime query default` answers a different question: it resolves
# the whole chain and returns whichever app comes first in
# /usr/share/applications/mimeinfo.cache, which on this distro is file-roller
# for zip and 7z — a root-owned file the distro ships, listing file-roller
# before Nautilus. Checking it here would warn on every single run over
# something this module never wrote, and a warning that always fires teaches
# the reader to ignore warnings.
#
# Extraction in Nautilus does not go through the MIME default anyway: it goes
# through file-roller's libnautilus-extension, which is why installing
# file-roller is enough and no association is needed.
if pin=$(grep -l 'File[Rr]oller' "$REAL_HOME/.config/mimeapps.list" \
                    "$REAL_HOME/.local/share/applications/mimeapps.list" 2>/dev/null); then
  warn "still pinned in: $(tr '\n' ' ' <<<"$pin")"
else
  ok "no file-roller default in the user config (Nautilus owns extraction)"
fi
ok "file-roller stays installed as the archive GUI + Nautilus extension"

# ---------------------------------------------------------------------------
# 3. Hyprland rule: file-roller is a floating dialog, not a tiled app.
# ---------------------------------------------------------------------------
msg "== 3/4 Hyprland rule (float + center file-roller) =="
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
msg "== 4/4 Hide file-roller's package menu entry (no desktop entry of our own) =="
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
# Done.
# ---------------------------------------------------------------------------
msg "== Done =="
ok "file-roller + 7zip + unrar present"
ok "Nautilus: right-click an archive → Extract Here (and Create Archive)"
ok "extraction runs through Nautilus; file-roller is not forced as the handler"
echo
msg "Password-protected archives:"
echo "  • right-click the archive → Extract Here; file-roller asks for the password."
echo "  • RAR goes through unrar, zip-AES / 7z / ISO through 7z — both apply it."
echo
echo "Done. Run './setup-extracto.sh --status' to verify."
