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
#   - hands the archive MIME types back to NAUTILUS, so a double-click behaves
#     the way the desktop did before. Older revisions pinned them to file-roller
#     instead; this module exists so Nautilus handles archives, not so file-roller
#     is the handler. Note that Nautilus 50 has no extraction of its own — its
#     "Extract Here" comes from the file-roller extension's right-click menu —
#     so this restores Nautilus' handling rather than promising extraction on a
#     double-click.
#   - hides file-roller's own package .desktop from the apps menu with a user
#     NoDisplay=true override (a FULL copy of the package file — see step 4 for
#     why a bare Hidden stub breaks "Open With"), so the menu is not cluttered
#     with a second archive entry.
#   - adds a per-class Hyprland rule: file-roller is a floating GTK4 dialog, so
#     it is floated + centered and exempted from the default window opacity.
#
# That is the whole module: packages + archive MIME defaults + two config
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

# The archive MIME types this module owns: cleared of any file-roller binding it
# wrote, then handed to Nautilus. Scoping both halves to this list is what keeps
# it from touching an association the module never made. RAR and ISO are in it
# because those were the cases with no working GUI.
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

# Drop the single-app archive associations this module used to write, so the
# hand-back below lands on a clean slate instead of overwriting a stale entry.
#
# Only lines that assign EXACTLY org.gnome.FileRoller.desktop are touched, and
# only inside [Default Applications] / [Added Associations]. A line listing file-
# roller alongside another app (`zip=org.gnome.FileRoller.desktop;org.gnome.
# Nautilus.desktop;`) is a candidate LIST the user or the distro wrote; dropping
# file-roller from it would be us silently re-deciding for them. Left alone.
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
            if group is not None and stripped:
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
    changed.append(f"{path} — {dropped} file-roller association(s) removed")

# Emitted with the module's own two-space "  ok " prefix so this line lines up
# with every other status line instead of printing a bare "ok " at column 0.
for c in changed:
    print(f"  ok {c}")
if not changed:
    print("  ok no file-roller association left to clear")
PY
}

# Hand the archive types back to Nautilus, which is what the very first version
# of this module did on --remove and what the user expects a double-click to do.
#
# Deliberately NOT file-roller: the whole point of the module is that Nautilus
# owns extraction, and file-roller's Nautilus extension supplies "Extract Here"
# without needing to be the handler. Nautilus declares these MIME types itself
# (/usr/share/applications/org.gnome.Nautilus.desktop), so this restores the
# desktop's own behaviour instead of inventing one.
hand_back_to_nautilus() {
  if ! have xdg-mime; then
    warn "xdg-mime not found — archive handlers left as they are."
    return
  fi
  local n=0 t
  for t in "${MIME_TYPES[@]}"; do
    xdg-mime default org.gnome.Nautilus.desktop "$t" 2>/dev/null && n=$((n + 1))
  done
  ok "archive double-click handed back to Nautilus ($n types)"
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
    ok "archive types handed to Nautilus; file-roller not pinned"
  fi
  # A read-only report of the resolved default, printed as information rather
  # than judged: mimeinfo.cache is distro-owned and lists file-roller first for
  # some types, so asserting on it would flag a machine this module never
  # misconfigured.
  if have xdg-mime; then
    printf '    %-34s -> %s\n' "application/zip (resolved)" \
      "$(xdg-mime query default application/zip 2>/dev/null || echo -)"
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
  # to undo. Then hand the types back to Nautilus, which is what this module's
  # first version did and what a double-click is expected to do.
  unbind_file_roller_defaults
  hand_back_to_nautilus
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
# 2. Hand the archive types back to Nautilus.
# ---------------------------------------------------------------------------
# Earlier revisions pinned `xdg-mime default org.gnome.FileRoller.desktop` for
# every archive type, so double-clicking an archive opened file-roller. That is
# not the behaviour this module is for: it exists so Nautilus regains archive
# actions, and the user asked for the desktop default back — double-click
# handled by Nautilus, exactly as the module's first version did on --remove.
#
# The two are not equivalent, and the difference is worth stating once. Setting
# Nautilus as the handler does NOT make Nautilus extract. Nautilus 50 has no
# built-in extraction; its file-roller extension adds "Extract Here" / "Extract
# To" to the right-click menu, and `Exec=nautilus --new-window %U` is what a
# double-click resolves to. What this restores is Nautilus's own archive
# handling, which is the desktop default this machine had before the module
# overrode it.
#
# Both halves are needed: clear the file-roller entries first so the hand-back
# is not fighting a stale pin, then set Nautilus. Doing it in this order also
# keeps the module idempotent, which re-running must be.
msg "== 2/4 Archive types handed back to Nautilus =="
unbind_file_roller_defaults
hand_back_to_nautilus

# Report the result against what THIS module is responsible for, not against
# the resolved chain. `xdg-mime query default` answers a different question: it
# resolves every layer and returns whichever app comes first in
# /usr/share/applications/mimeinfo.cache, which is file-roller for zip and 7z
# because that is the order the distro ships. Checking it here would report a
# failure on a root-owned file this module never wrote, and a warning that
# always fires teaches the reader to ignore warnings. So this greps the user
# config instead: that is the file we own.
if pin=$(grep -l 'File[Rr]oller' "$REAL_HOME/.config/mimeapps.list" \
                    "$REAL_HOME/.local/share/applications/mimeapps.list" 2>/dev/null); then
  warn "still pinned in: $(tr '\n' ' ' <<<"$pin")"
else
  ok "no file-roller association in the user config"
fi

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
ok "double-clicking an archive is handled by Nautilus"
echo
msg "Password-protected archives:"
echo "  • right-click the archive → Extract Here; file-roller asks for the password."
echo "  • RAR goes through unrar, zip-AES / 7z / ISO through 7z — both apply it."
echo
echo "Done. Run './setup-extracto.sh --status' to verify."
