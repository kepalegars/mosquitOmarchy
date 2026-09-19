#!/usr/bin/env bash
# setup-ableton.sh — Installs Ableton Live 12 native Linux (project shibco/ableton-linux)
# + linking of the shared VST plugins (~/VST) with the Linux DAWs (yabridge).
#
# ableton-linux runs Live through a dedicated custom wine (prefix ~/.wine-ableton,
# wine-d2d1-nspa): Live remains a Windows program but runs natively on Linux,
# without a VM. The system prerequisites (gstreamer, ntsync, pipewire, glibc) are checked.
#
# After installation, the Windows plugins dropped in the shared VST root
# (vst/vst3/clap — resolved by link-vst-shared.sh) are shared between:
#   - Bitwig / REAPER (via yabridge, prefix ~/.wine)
#   - Ableton Live (via its prefix ~/.wine-ableton)
#
# Usage :
#   ./setup-ableton.sh              # menu: Install / Uninstall / VST links / Status
#   ./setup-ableton.sh -y           # everything automatic (default choices)
#   ./setup-ableton.sh --links      # only (re)links the shared VST folders
#   ./setup-ableton.sh --status     # current state, without modifying anything
#   ./setup-ableton.sh -u|--uninstall  # uninstalls one or several editions
#   ./setup-ableton.sh -y -u        # idem, automatic (uninstall everything)
#   ./setup-ableton.sh --check-update  # checks/downloads the latest update
#                                       # of the native installer from GitHub
#
# At each installation, the script checks on its own whether a newer version of
# the native installer (install-ableton-*.run, project shibco/ableton-linux) exists on
# GitHub and downloads/replaces it in this folder. ALL the customizations
# (wine cleanup, blocking of the Live updates, menu deduplication, …)
# live in THIS script, never in the .run: we can therefore replace/update the
# .run at will without losing our adjustments.
#
# Power management: by default --power=off (the project does NOT touch the
# power profile; your custom.power/ultra-save manager keeps control). One-off
# override: POWER=performance|balanced ./setup-ableton.sh -y
#
# Audio buffer: by default --audio-buffer=512 (the most stable value for
# ASIO/PipeASIO on this machine). One-off override:
# BUFFER=64|128|256|1024 ./setup-ableton.sh -y
#
# Multi-editions: if several zips of different editions are lying in the folder
# (e.g. Suite + Intro), the script proposes a multi-selection and installs
# the chosen editions one after the other ON THE SAME prefix — each one
# is passed alone to the .run (--live-installer, one per call). The versions
# coexist; to choose which one to launch:
#   env ABLETON_LIVE_EXE="$HOME/.wine-ableton/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe" ableton-live
#
# Hyprland windows: the script ensures that the Ableton rules are in place
# in ~/.config/hypr/hyprland.lua — floating installer (fixes the tile crash)
# and 100% opaque windows/popups/menus (no transparency behind).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Launched from a file manager (double-click): no terminal →
# we relaunch in foot so gum/read have a real TTY. --hold keeps the
# window open once the script has finished (otherwise it closes immediately).
if [[ ! -t 0 ]] && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v foot >/dev/null; then
  exec foot --hold --title "install-ableton" -- "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@"
fi

LINKER="$SCRIPT_DIR/../audio-plugin-manager/link-vst-shared.sh"
POWER_DEFAULT="${POWER:-off}"   # off = do not change the power profile (custom.power keeps control)
BUFFER_DEFAULT="${BUFFER:-512}" # 512 frames = stable latency for PipeASIO

YES=0 LINKS_ONLY=0 STATUS_ONLY=0 UNINSTALL_ONLY=0 UPDATE_ONLY=0
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  --links) LINKS_ONLY=1 ;;
  --status) STATUS_ONLY=1 ;;
  --check-update) UPDATE_ONLY=1 ;;
  -u|--uninstall) UNINSTALL_ONLY=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 1 ;;
esac; shift; done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..70}; echo; }

pkg_has(){ pacman -Q "$1" &>/dev/null; }

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  if command -v gum >/dev/null; then
    gum confirm "$q" --default=$([[ $def == y ]] && echo true || echo false) && return 0 || return 1
  fi
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

ver_ge(){ # ver_ge "1.4.2" "1.6.8" → true if $1 ≥ $2 (semantic)
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V -r | head -1)" == "$1" ]]
}

# ───────────────────────── Auto-update of the native installer ─────────────────────────
# The native installer (install-ableton-*.run) comes from
#   https://github.com/shibco/ableton-linux/releases/latest
# Its version read in the .run header is compared to the latest GitHub release;
# if a newer version exists, it is downloaded/replaced in SCRIPT_DIR
# with verification of the official sha256. All our customizations remain in this
# script: a fresh .run causes no loss of adjustment.
run_version(){ # version of the native installer, read in the .run header
  local f="${1:-$RUN_INSTALLER}" v vmax="" pat='20[0-9]{2}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?'
  [[ -f "$f" ]] || return 0
  while IFS= read -r v; do
    [[ "$v" =~ ^$pat$ ]] || continue
    if [[ -z "$vmax" ]] || ver_ge "$v" "$vmax"; then vmax="$v"; fi
  done < <(head -c 1572864 "$f" 2>/dev/null | grep -aoE "$pat" | sort -u)
  printf '%s\n' "$vmax"
}

step_update_check(){
  local out="" lv="" rv url digest tmp got target
  msg "Update of the native installer (github.com/shibco/ableton-linux)"
  lv="$(run_version)"
  if [[ -n "$lv" ]]; then
    ok "Local installer: $lv"
  elif [[ -n "$RUN_INSTALLER" ]]; then
    warn "Local version undetectable — we will postpone the download choice."
  else
    warn "No install-ableton-*.run in $SCRIPT_DIR — we can download one."
  fi
  out="$(curl -fsSL --max-time 25 "https://api.github.com/repos/shibco/ableton-linux/releases/latest" 2>/dev/null)" \
    || { warn "GitHub unreachable — local installer kept."; return 0; }
  rv="$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null)"
  if [[ ! "$rv" =~ ^[0-9]+(\.[0-9]+){2,}$ ]]; then
    warn "Unreadable GitHub response ($rv) — local installer kept."
    return 0
  fi
  if [[ -n "$lv" ]] && ver_ge "$lv" "$rv"; then
    ok "Installer up to date ($lv) — nothing to do."
    return 0
  fi
  url="$(printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((a["browser_download_url"] for a in d["assets"] if a["name"]=="install-ableton-latest.run"),""))' 2>/dev/null)"
  digest="$(printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((a["digest"] for a in d["assets"] if a["name"]=="install-ableton-latest.run"),""))' 2>/dev/null)"
  [[ -n "$url" ]] || { warn "Download link not found on GitHub."; return 0; }
  msg "Version $rv available — downloading the official installer…"
  if (( ! YES )) && ! ask "Download and replace the installer with version $rv ?" y; then
    warn "Download cancelled — the local installer ($lv) is kept."
    return 0
  fi
  tmp="$SCRIPT_DIR/.install-ableton-latest.run.part"
  rm -f -- "$tmp"
  if ! curl -fL --max-time 600 -o "$tmp" "$url" 2>/dev/null; then
    rm -f -- "$tmp"; warn "Download failed — local installer kept."; return 1
  fi
  if [[ -n "$digest" ]]; then
    got="$(sha256sum "$tmp" | awk '{print $1}')"
    if [[ "$got" != "${digest#sha256:}" ]]; then
      rm -f -- "$tmp"
      err "Checksum of the downloaded .run inconsistent — local installer kept."
      return 1
    fi
  fi
  chmod +x -- "$tmp"
  # No installer present in the folder? we create it (initial download).
  target="$RUN_INSTALLER"
  [[ -n "$target" ]] || target="$SCRIPT_DIR/install-ableton-latest.run"
  mv -f -- "$tmp" "$target"
  RUN_INSTALLER="$target"
  ok "Native installer: $rv (${target##*/})"
  return 0
}

RUN_INSTALLER=""
LIVE_ZIPS=()
for f in "$SCRIPT_DIR"/install-ableton-*.run; do [[ -f $f ]] && RUN_INSTALLER=$f; done
for f in "$SCRIPT_DIR"/Ableton*.zip "$SCRIPT_DIR"/ableton*.zip; do [[ -f $f ]] && LIVE_ZIPS+=("$f"); done
LIVE_ZIP="${LIVE_ZIPS[0]:-}"   # backward compat: first found zip

# Ableton editions detected from the zip names: ableton_live_intro_12.4.5_64.zip
zip_edition(){ # zip_edition FILE.zip → intro|suite|standard|lite|beta
  local n
  n="$(basename "$1")"
  n="${n##*ableton_live_}"
  printf '%s' "${n%%_*}" | tr '[:upper:]' '[:lower:]'
}

# Editions really installed in the prefix ~/.wine-ableton
installed_editions(){
  local d
  for d in "$HOME/.wine-ableton"/drive_c/ProgramData/Ableton/Live*/Program/"Ableton Live"*.exe; do
    [[ -f "$d" ]] && printf '%s\n' "${d##*/}" | sed -E 's/^Ableton Live [0-9]+ ([A-Za-z]+)\.exe$/\L\1/'
  done
  return 0
}

# All the Ableton edition zips available in the folder
live_zips(){
  local f
  for f in "$SCRIPT_DIR"/Ableton*.zip "$SCRIPT_DIR"/ableton*.zip; do
    [[ -f $f ]] && printf '%s\n' "$f"
  done | sort -u
}

# "1 3" / "1,3" / "1-3" → list of indices (array referenced by the 2nd argument)
expand_numbers(){
  local input="${1//,/ }" n m
  local -n dst="$2"
  dst=()
  if [[ "$input" =~ ^[0-9]+(-[0-9]+)?([[:space:]]+[0-9]+(-[0-9]+)?)*[[:space:]]*$ ]]; then
    for n in $input; do
      if [[ "$n" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        for ((m=${BASH_REMATCH[1]}; m<=${BASH_REMATCH[2]}; m++)); do dst+=("$m"); done
      else
        dst+=("$n")
      fi
    done
    return 0
  fi
  return 1
}

# ───────────────────────── Selecting the editions to install ─────────────────────────
# When several zips are in the folder, we propose to choose one or
# more; only the selected zips are then passed to the native installer
# (one --live-installer per call — the .run only accepts one).
# Fills the global array SEL_ZIPS.
SEL_ZIPS=()
select_editions(){
  local -a cand=("$@")
  SEL_ZIPS=()
  (( ${#cand[@]} )) || return 1
  if (( YES )) || (( ${#cand[@]} == 1 )); then
    SEL_ZIPS=("${cand[@]}")
    return 0
  fi
  local i=1 z base ed ver sel
  local -a idx
  hr; msg "Several editions found in $SCRIPT_DIR — which ones to install ?"
  for z in "${cand[@]}"; do
    base="${z##*/}"
    ed="$(zip_edition "$z")"
    ver="${base%_64.zip}"; ver="${ver##*_}"   # 12.3.6 / 12.4.5 …
    printf '  %2d) %-8s (version %s)\n' "$i" "$ed" "$ver"
    i=$((i+1))
  done
  echo
  read -rp "  Choice (separated numbers / range, e.g. 1 3) [Enter = all] : " sel
  sel="${sel//,/ }"
  [[ -n "$sel" ]] || sel="$(seq 1 $((i-1)) | tr '\n' ' ')"
  if expand_numbers "$sel" idx; then
    for n in "${idx[@]}"; do
      (( n >= 1 && n <= ${#cand[@]} )) && SEL_ZIPS+=("${cand[$((n-1))]}")
    done
  else
    warn "Invalid input ($sel) — all the editions will be installed."
  fi
  (( ${#SEL_ZIPS[@]} )) || SEL_ZIPS=("${cand[@]}")
}

# ───────────────────────── Detection / state ─────────────────────────
ableton_installed(){
  [[ -f "$HOME/.local/bin/ableton-live" || -d "$HOME/.wine-ableton/drive_c" ]]
}
ableton_version(){
  [[ -x "$HOME/.local/bin/ableton-live" ]] && "$HOME/.local/bin/ableton-live" --version 2>/dev/null | head -1 | tr -d '\r' || echo "unknown"
}

status_check(){
  hr; msg "Ableton Live native Linux state"
  if ableton_installed; then
    ok "Installed: $(ableton_version)"
  else
    warn "Not installed ($RUN_INSTALLER → prefix ~/.wine-ableton)"
  fi
  for c in \
    "NTSync active             : $( [[ -e /dev/ntsync ]] && echo OK || echo inactive?! )" \
    "Kernel                    : $( uname -r )" \
    "glibc                     : $( ldd --version | head -1 | awk '{print $NF}' )" \
    "PipeWire                  : $( pacman -Q pipewire 2>/dev/null | awk '{print $2}' || echo 'missing?!' )" \
    "GStreamer (base/good)     : $( pkg_has gst-plugins-good && echo OK || echo missing )" \
    "Launcher ableton-live      : $( [[ -x "$HOME/.local/bin/ableton-live" ]] && echo present || echo absent )" \
    "Prefix wine               : $( [[ -d "$HOME/.wine-ableton" ]] && echo present || echo absent )"
  do
    printf " %s\n" "$c"
  done
  hr
}

# ───────────────────── Zip missing ? rescan / typed path / cancel ─────────────────────
# When no edition zip is in the folder, proposes (interactive):
#   1 = rescan  (you just copied the zip — the folder is rescanned)
#   2 = type the full path of a zip elsewhere on the disk
#   3 = cancel
# Loops as long as nothing is found, as long as the user does not choose to cancel.
# Fills LIVE_ZIPS. Returns 1 if cancelled (installation must not continue).
resolve_missing_zips(){
  local choice manual=""
  while (( ${#LIVE_ZIPS[@]} == 0 )); do
    hr; msg "No Ableton zip found in $SCRIPT_DIR/"
    echo "  The native installer needs an edition zip (e.g. ableton_live_intro_12.4.5_64.zip)."
    echo
    echo "   1) Rescan          (I just copied the zip into the folder)"
    echo "   2) Type a path     (zip elsewhere on the disk)"
    echo "   3) Cancel          (come back later)"
    echo
    if ! read -rp "  Choice [1-3] : " choice; then warn "Input closed — installation cancelled."; return 1; fi
    case "$choice" in
      1)
        LIVE_ZIPS=()
        for f in "$SCRIPT_DIR"/Ableton*.zip "$SCRIPT_DIR"/ableton*.zip; do [[ -f $f ]] && LIVE_ZIPS+=("$f"); done
        (( ${#LIVE_ZIPS[@]} )) && ok "Zip found: ${LIVE_ZIPS[0]##*/}" || warn "Still no zip — rescan or type a path."
        ;;
      2)
        read -rp "  Full zip path : " manual
        if [[ -f "$manual" && "$manual" == *.zip ]]; then
          LIVE_ZIPS=("$manual")
          ok "Zip retained: $manual"
        else
          warn ".zip file not found: $manual"
        fi
        ;;
      3)
        warn "Stopped — drop an edition zip in $SCRIPT_DIR/ then relaunch (or pass -y to let the installer try alone)."
        return 1
        ;;
      *) warn "Invalid choice ($choice)." ;;
    esac
  done
}

# ───────────────────────── System prerequisites ─────────────────────────
step_prereqs(){
  msg "System prerequisites (the installer must also check them)"
  local ok_req=1

  [[ -e /dev/ntsync ]] && ok "NTSync active (/dev/ntsync)" || { warn "NTSync inactive — Live may miss its audio deadlines."; ok_req=0; }
  pkg_has pipewire || { warn "PipeWire missing — install it (sudo pacman -S pipewire)."; ok_req=0; }
  pkg_has gst-plugins-base && pkg_has gst-plugins-good \
    && ok "GStreamer base/good present" \
    || { warn "gst-plugins-base/good missing (required by the runtime)."; ok_req=0; }

  # No question in auto mode: the gaps are reported and we continue if the minimum exists
  return 0
}

# ───────────────────────── Patcher Python dependency (cryptography) ─────────────────────────
# The patcher (PATCH/activate_ableton.py) needs the pip module 'cryptography'
# to sign the authorization. It is checked at script launch and, if it is
# missing, we propose to install it in the dedicated venv PATCH/.venv — it is
# this python that runs the patch (it owns pip and isolates the module).
step_pydeps(){
  msg "Patcher Python dependency: cryptography module"
  local venv="$SCRIPT_DIR/PATCH/.venv" venv_py="$SCRIPT_DIR/PATCH/.venv/bin/python3"
  local py="python3" missing=1

  [[ -x "$venv_py" ]] || venv_py=""
  for py in "$venv_py" python3; do
    [[ -n "$py" ]] || continue
    if command -v "$py" >/dev/null 2>&1 && "$py" -c "import cryptography" 2>/dev/null; then
      ok "cryptography present for $py"
      missing=0
      break
    fi
  done

  (( missing )) || return 0
  warn "pip module 'cryptography' missing (needed for the Ableton patch)."
  if ((YES)) || ask "Install cryptography in PATCH/.venv now ?" y; then
    if [[ -x "$venv_py" ]]; then
      if "$venv_py" -m pip install --quiet cryptography 2>/dev/null \
         && "$venv_py" -c "import cryptography" 2>/dev/null; then
        ok "cryptography installed in the venv: $venv_py"
        return 0
      fi
      warn "Installation in the venv failed — I overwrite and recreate it."
      rm -rf "$venv"
    fi
    if command -v python3 >/dev/null 2>&1 && python3 -m venv "$venv" 2>/dev/null \
       && "$venv/bin/python3" -m pip install --quiet cryptography 2>/dev/null \
       && "$venv/bin/python3" -c "import cryptography" 2>/dev/null; then
      ok "Venv PATCH/.venv created + cryptography installed."
      return 0
    fi
    warn "Venv creation impossible (python3-venv ?). Try:"
    warn "  sudo pacman -S python-cryptography   # otherwise, patch with python3"
  else
    warn "cryptography not installed — the patch will fail (module missing)."
  fi
}

# ───────────────────────── Installation ─────────────────────────
step_install(){
  local z ed installed

  if ableton_installed; then
    ok "Ableton already installed ($(ableton_version))"

    # Other editions in the folder (e.g. Suite) not yet on the prefix:
    # multiple choice possible, installed in sequence on the same prefix
    installed="$(installed_editions | sort -u)"
    local -a pick=()
    for z in "${LIVE_ZIPS[@]:-}"; do
      [[ -n "$z" ]] || continue
      ed="$(zip_edition "$z")"
      if grep -q "^$ed$" <<<"$installed"; then
        ok "Already installed: $ed"
      else
        msg "Edition detected, not installed: $ed ($z)"
        pick+=("$z")
      fi
    done
    if (( ${#pick[@]} )); then
      select_editions "${pick[@]}"
      for z in "${SEL_ZIPS[@]:-}"; do do_install "$z"; done
    else
      ok "All the editions of the folder are already installed."
    fi

    warn "For a new version of the runtime/launcher:"
    warn "  sh \"$RUN_INSTALLER\" update   (updates the runtime, keeps Live/licenses)"
    return 0
  fi

  [[ -n "$RUN_INSTALLER" ]] || { err "No install-ableton-latest.run found in $SCRIPT_DIR/"; return 1; }
  if (( ${#LIVE_ZIPS[@]} == 0 )); then
    if ((YES)); then
      warn "No Ableton zip found in $SCRIPT_DIR/ — the installer will try to find one itself."
      do_install ""
    elif resolve_missing_zips; then
      select_editions "${LIVE_ZIPS[@]}"
      for z in "${SEL_ZIPS[@]:-}"; do do_install "$z"; done
    fi
  else
    select_editions "${LIVE_ZIPS[@]}"
    for z in "${SEL_ZIPS[@]:-}"; do do_install "$z"; done
  fi
}

do_install(){
  local zip="${1:-$LIVE_ZIP}"
  case "$POWER_DEFAULT" in
    performance|balanced|off) ;;
    *) err "Invalid POWER: $POWER_DEFAULT (expected performance|balanced|off)"; return 1 ;;
  esac
  case "$BUFFER_DEFAULT" in
    64|128|256|512|1024) ;;
    *) err "Invalid BUFFER: $BUFFER_DEFAULT (expected 64|128|256|512|1024)"; return 1 ;;
  esac
  local cmd=("sh" "$RUN_INSTALLER" "install")
  if [[ -n "$zip" ]]; then cmd+=(--live-installer "$zip"); fi
  cmd+=(--power="$POWER_DEFAULT")
  cmd+=(--audio-buffer="$BUFFER_DEFAULT")
  if ((YES)); then
    msg "Command: ${cmd[*]}"
    "${cmd[@]}"
    return $?
  fi
  msg "Launching the official installer with the default values:"
  msg "  --power=$POWER_DEFAULT (power profile not modified; custom.power keeps control)"
  msg "  --audio-buffer=$BUFFER_DEFAULT frames (256 and below = more dropouts/glitches)"
  msg "  dpi=auto, rt=auto, shortcuts=take (the project defaults)."
  msg "  The 6 pre-flight questions are NOT asked: on an explicit 'install'"
  msg "  command, the installer applies the defaults/options passed."
  msg "  (To choose each option by hand: run the .run without argument.)"
  echo
  if ! ask "Launch the installation now ?" y; then warn "Installation cancelled."; return 1; fi
  "${cmd[@]}"
}

# ───────────────────────── Blocking the Live updates (Windows side) ─────────────────────────
# Live reads Options.txt in two places in the prefix:
#   per-user   drive_c/users/<user>/AppData/Roaming/Ableton/Live X/Preferences/Options.txt
#   shared     drive_c/ProgramData/Ableton/CommonConfiguration/Live X/Preferences/Options.txt
# The official line (Ableton docs) '-_DisableAutoUpdates' disables the automatic
# updates of the edition. The dash is mandatory: without it, Live writes
# ' Syntax error in debug option file ' in Log.txt and does not apply the option.
step_block_updates(){
  msg "Blocking the automatic Live updates (Options.txt Windows side)"
  local prefix="$HOME/.wine-ableton" prefs live_dir ver written=0
  [[ -d "$prefix/drive_c" ]] || { warn "Prefix absent: $prefix — nothing to block."; return 0; }

  # write_token <file> : removes any DisableAutoUpdates token (dash or not),
  # then ensures the official '-_DisableAutoUpdates' line is present.
  write_token(){
    local f="$1" tmp
    [[ -f "$f" ]] || { printf '\n-_DisableAutoUpdates\n' > "$f"; return 0; }
    tmp="$(mktemp)"
    grep -v 'DisableAutoUpdates' "$f" > "$tmp" 2>/dev/null || true
    printf '\n-_DisableAutoUpdates\n' >> "$tmp"
    mv "$tmp" "$f"
  }

  for prefs in "$prefix"/drive_c/users/*/AppData/Roaming/Ableton/Live\ 12*/Preferences; do
    [[ -d "$prefs" ]] || continue
    if write_token "$prefs/Options.txt"; then
      ok "Updates blocked (per-user): ${prefs#*Ableton/}"
      written=1
    else
      warn "Unable to write: $prefs/Options.txt"
    fi
  done

  for live_dir in "$prefix"/drive_c/users/*/AppData/Roaming/Ableton/Live\ 12*; do
    [[ -d "$live_dir" ]] || continue
    ver="${live_dir##*/}"
    prefs="$prefix/drive_c/ProgramData/Ableton/CommonConfiguration/$ver/Preferences"
    mkdir -p -- "$prefs" 2>/dev/null || { warn "Unable to create: $prefs"; continue; }
    if write_token "$prefs/Options.txt"; then
      ok "Updates blocked (shared): $ver"
      written=1
    else
      warn "Unable to write: $prefs/Options.txt"
    fi
  done

  (( written )) || ok "No update to block (Live not yet installed in the prefix)."
}

# ───────────────────────── Hyprland windows (float installer + opaque) ─────────────────────────
HYPR_FILE="$HOME/.config/hypr/hyprland.lua"
step_hypr_rules(){
  msg "Ableton windows: Hyprland rules (float installer + opaque)"

  if [[ ! -f "$HYPR_FILE" ]]; then
    warn "hyprland config missing: $HYPR_FILE — rules not applied."
    echo "   Add manually:  $rule"
    return 0
  fi

  local f_rule='o.window({ class = "^ableton live 12 .*install.*$" }, { float = true })'
  local o_rule='o.window({ class = "^ableton.*$" }, { tag = "-default-opacity", opaque = true })'
  local added=0

  # NB: we no longer touch the cursor/touchpad management. We removed the Ableton
  # scroll_touchpad rule (and any cursor= option in input.lua): it broke the
  # two-finger scroll in Nautilus. The rest is left to the Omarchy default.

  if grep -qF -- "$f_rule" "$HYPR_FILE"; then
    ok "Float installer rule already present"
  else
    printf -- 'o.window({ class = "^ableton live 12 .*install.*$" }, { float = true })\n' >> "$HYPR_FILE"
    added=1
    ok "Float installer rule added"
  fi

  if grep -qF -- "$o_rule" "$HYPR_FILE"; then
    ok "Opaque rule already present"
  else
    printf -- 'o.window({ class = "^ableton.*$" }, { tag = "-default-opacity", opaque = true })\n' >> "$HYPR_FILE"
    added=1
    ok "Opaque rule added"
  fi

  if (( added )); then
    if command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1; then
      ok "hyprctl reload OK"
      command -v hyprctl >/dev/null && hyprctl configerrors
    else
      warn "hyprctl unavailable — will reload at next login."
    fi
  fi
}

# ───────────────────────── Shared VST linking ─────────────────────────
step_links(){
  msg "Linking the shared VST plugins (all DAWs)"
  if [[ -x "$LINKER" ]]; then bash "$LINKER"; else
    warn "link-vst-shared.sh not found ($LINKER) — symlinks not created."
  fi
}

# ───────────────────────── Menu entries (one per edition) ─────────────────────────
# The native launcher regenerates its generic entry (ableton-live.desktop) at EACH
# launch: keeping it in addition to our per-edition entries creates duplicates.
# Policy:
#   • single edition → we keep ONLY the launcher entry (generic) ;
#   • several editions → one entry per edition (targeted exe env ABLETON_LIVE_EXE),
#     the generic entry is removed (ambiguous).
step_menu_entries(){
  msg "Menu entries: one per installed edition"
  local apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  local icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
  mkdir -p "$apps_dir"
  local exe name entry base ed icon wmclass f found=0 count=0
  local generic="$apps_dir/ableton-live.desktop"
  while IFS= read -r exe; do
    [[ -f "$exe" ]] || continue
    count=$((count+1))
    base="$(basename "$exe")"
    name="${base%.exe}"
    ed="$(printf '%s' "$name" | awk '{print tolower($NF)}')"  # intro|suite|standard|lite
    icon="live-$ed"
    [[ -f "$icons_dir/$icon.svg" ]] || icon="live-intro"
    wmclass="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    f="$apps_dir/ableton-live-$ed.desktop"
    {
      printf '[Desktop Entry]\n'
      printf 'Name=%s\n' "$name"
      printf 'Comment=Music production and performance\n'
      printf 'Exec=env ABLETON_LIVE_EXE="%s" %s %%f\n' "$exe" "$HOME/.local/bin/ableton-live"
      printf 'Type=Application\n'
      printf 'StartupNotify=true\n'
      printf 'Path=%s\n' "$HOME/.wine-ableton"
      printf 'Icon=%s\n' "$icon"
      printf 'StartupWMClass=%s\n' "$wmclass"
      printf 'MimeType=application/x-ableton-live-set;application/x-ableton-live-clip;application/x-ableton-live-pack;\n'
      printf 'Categories=AudioVideo;Audio;\n'
    } > "$f"
    chmod 644 "$f"
    found=1
  done < <(ls -1 "$HOME/.wine-ableton/drive_c/ProgramData/Ableton/"*/Program/"Ableton Live"*.exe 2>/dev/null | sort -V)

  if (( count == 1 )); then
    # Single edition: generic launcher entry only (it will be regenerated at
    # each launch) ; we delete our per-edition entries → no duplicate.
    rm -f -- "$apps_dir"/ableton-live-*.desktop
    if [[ ! -f "$generic" ]]; then
      # The launcher never ran: create the generic entry ourselves.
      exe=""
      for c in "$HOME/.wine-ableton"/drive_c/ProgramData/Ableton/*/Program/"Ableton Live"*.exe; do
        [[ -f "$c" ]] && { exe="$c"; break; }
      done
      if [[ -n "$exe" ]]; then
        base="$(basename "$exe")"; name="${base%.exe}"
        ed="$(printf '%s' "$name" | awk '{print tolower($NF)}')"
        icon="live-$ed"; [[ -f "$icons_dir/$icon.svg" ]] || icon="live-intro"
        {
          printf '[Desktop Entry]\n'
          printf 'Name=%s\n' "$name"
          printf 'Comment=Music production and performance\n'
          printf 'Exec=%s %%f\n' "$HOME/.local/bin/ableton-live"
          printf 'Type=Application\n'
          printf 'StartupNotify=true\n'
          printf 'Path=%s\n' "$HOME/.wine-ableton"
          printf 'Icon=%s\n' "$icon"
          printf 'Categories=AudioVideo;Audio;\n'
        } > "$generic"
        chmod 644 "$generic"
        found=1
      fi
    fi
    ok "Single edition — generic launcher entry kept ($generic)"
  elif (( count > 1 )); then
    rm -f -- "$generic"
    ok "Generic entry removed (several editions: targeted exe required)"
  fi

  # Wine start-menu duplicates (created when the Windows installer is run with
  # its "create desktop icon / start menu shortcut" options checked). We keep
  # ONLY our own entries: any Ableton shortcut published under wine/Programs is
  # deleted.
  #
  # File associations (wine-extension-*, wine-protocol-*, one per registered
  # file type — als/abl/ablbundle/alc/adv/adg/alp/auz) used to be kept
  # deliberately (NoDisplay=true, assumed hidden from menus) — reported back
  # as real clutter: GNOME Files' "Open With" chooser does NOT respect
  # NoDisplay the way an app grid does, so every one of these still shows up
  # under "Other Applications", all labeled the same "Ableton Live 12 Suite".
  # Worse, they're regenerated by winemenubuilder against whichever WINEPREFIX
  # was live at the time — found ones on this machine still pointing at the
  # old, no-longer-used default `~/.wine` prefix from before this module
  # switched to a dedicated `~/.wine-ableton` one, meaning they're not just
  # duplicate-looking but genuinely stale. Our own per-edition entries above
  # already declare the same MimeTypes against the maintained
  # `~/.local/bin/ableton-live` wrapper, so these add nothing — removed
  # every run, same as the wine/Programs sweep below. The native
  # shibco/Linux entries (io.github.shibco.ableton-linux.*, the URL-scheme
  # handler + .auz association) are a different, non-Wine-generated app and
  # are never touched here.
  while IFS= read -r -d '' f; do
    if rg -qi 'ableton' "$f" 2>/dev/null; then rm -f -- "$f"; ok "Stale file association removed: ${f#$apps_dir/}"; fi
  done < <(find "$apps_dir" -maxdepth 1 -type f \( -name 'wine-extension-*.desktop' -o -name 'wine-protocol-*.desktop' \) -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    if rg -qi 'ableton' "$f" 2>/dev/null; then rm -f -- "$f"; ok "Wine duplicate removed: ${f#$apps_dir/}"; fi
  done < <(find "$apps_dir/wine/Programs" -maxdepth 5 -type f -name '*.desktop' -print0 2>/dev/null)
  local dd="${XDG_DATA_HOME:-$HOME/.local/share}/desktop-directories"
  while IFS= read -r -d '' f; do
    rg -qi 'ableton' "$f" 2>/dev/null && rm -f -- "$f" || true
  done < <(find "$dd" -maxdepth 5 -type f -name '*.directory' -print0 2>/dev/null)
  find "$apps_dir/wine/Programs" -depth -type d -empty -delete 2>/dev/null || true

  command -v update-desktop-database >/dev/null && update-desktop-database "$apps_dir" >/dev/null 2>&1
  return $((found ? 0 : 1))
}

# ───────────────────────── Patch — Patch 1 (MAIN: HWID + authorization) ─────────────────────────
step_patch(){
  #   patch-ableton.sh     : MAIN patch — installs the app ' R2R System v1.5.2.exe '
  #   (present in PATCH/tools/) in the Ableton wine (targeted prefix),
  #   copies vcruntime140_1.dll next to the Ableton.exe of the chosen edition
  #   (menu if several), copies the HWID to the clipboard, then opens the
  #   TARGET_FILE (WM_Ableton.r2rwm) with the installed app (WitchWand).
  #   Actions : --patch (default) / -y / --no-run / --list / --target DIR
  #             --app EXE / --file PATH.
  #   All the old patches (2/3/4/5/6) are archived in PATCH/old/ :
  #   _old_patch-2-exe-dnd.sh, _old_patch-3-auto.sh, _old_patch-4-python-run.sh,
  #   _old_patch-5-python-dsa.sh, _old_patch-6-beta-wine-exe.sh ; and the exe
  #   ableton-patcher-windows-amd64.exe in old/old_TOOLS/. The active main is
  #   in tools/.
  local pdir="$SCRIPT_DIR/PATCH"
  local p1="$pdir/patch-ableton.sh"
  local helper=""

  if [[ -x "$p1" ]]; then
    helper="$p1"
    msg "Patch tool: $(basename "$helper")"
  else
    warn "Patch tool not found — patch step skipped (files available in the latest release)."
    return 0
  fi

  if ((YES)) || ask "Patch detected, patch now ?" y; then
    bash "$helper" ${YES:+-y}
    local rc=$?
    if (( rc )); then
      err "The patch failed (code $rc)."
      warn "Relaunch: bash \"$helper\""
    else
      ok "Patch ${helper##*/patch-} executed."
    fi
  else
    warn "Patcher not launched — to do it manually:"
    warn "  bash \"$helper\""
    warn "  bash \"$helper\" --no-run           (preparation only, without launching)"
  fi
}

# ───────────────────────── Cleanup of the blocking leftovers ─────────────────────────
# Fixing the errors encountered after a session:
#  - an Ableton instance left in memory → the launcher afterwards refuses to relaunch
#    ('won't launch anymore') as long as it occupies the wine prefix.
#  - the obsolete/buggy watcher of the old patch-3-auto.sh → reopened the folder in a loop.
#  - wine processes of the prefix left by a previous session (winedevice.exe
#    and co) → the native installer aborts at its step 3 ' INSTALL THE WINE
#    RUNTIME ' with ' Wine is running ' if it finds one.
# To run BEFORE any install/launch.
step_cleanup(){
  msg "Cleanup of leftovers (Ableton instances, patch watchers, prefix wine)"
  local n=0 p prefix="$HOME/.wine-ableton" wineroot="$HOME/.local/opt/wine-d2d1-nspa-11.13" deadline
  # 1) Running Ableton instances (main exe, indexer, web connector)
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    kill "$p" >/dev/null 2>&1 && n=$((n+1))
  done < <(pgrep -f 'C:\\ProgramData\\Ableton\\Live' 2>/dev/null || true)
  # 2) Folder-open watchers still alive (marker ABLE_PATCH_WATCH, from the old patch-3-auto.sh)
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    kill "$p" >/dev/null 2>&1 && n=$((n+1))
  done < <(pgrep -f 'ABLE_PATCH_WATCH' 2>/dev/null || true)
  # 3) Ableton prefix wine still alive: the native installer refuses to start
  #    as long as a process of this runtime runs (wineserver, winedevice, services.exe,
  #    svchost, rpcss, plugplay, EdgeUpdate…). wineserver -k is not enough: when
  #    the server is already dead, these clients remain orphaned. We therefore match
  #    WINEPREFIX in /proc/*/environ (never another prefix) and close them all.
  if [[ -x "$wineroot/bin/wineserver" ]]; then
    WINEPREFIX="$prefix" "$wineroot/bin/wineserver" -k >/dev/null 2>&1 || true
  fi
  local -a wine_pids=()
  while IFS= read -r -d '' proc; do
    p="${proc#/proc/}"; p="${p%/environ}"
    wine_pids+=("$p")
  done < <(grep -rzlFx --null "WINEPREFIX=$prefix" /proc/[0-9]*/environ 2>/dev/null)
  if (( ${#wine_pids[@]} )); then
    kill "${wine_pids[@]}" >/dev/null 2>&1 || true
    n=$((n + ${#wine_pids[@]}))
    deadline=$((SECONDS + 20))
    while (( SECONDS < deadline )); do
      local alive=0 p2
      for p2 in "${wine_pids[@]}"; do
        if kill -0 "$p2" 2>/dev/null; then alive=1; break; fi
      done
      (( alive )) || break
      sleep 0.5
    done
    # Stubborn leftovers: KILL, always bounded to the Ableton prefix
    for p2 in "${wine_pids[@]}"; do
      if tr '\0' '\n' < "/proc/$p2/environ" 2>/dev/null | grep -qx "WINEPREFIX=$prefix" \
         && kill -0 "$p2" 2>/dev/null; then
        kill -9 "$p2" 2>/dev/null || true
      fi
    done
  fi

  if (( n )); then
    sleep 1
    # Force if an instance did not stop amiably (Ableton prefix only)
    pkill -9 -f 'C:\\ProgramData\\Ableton\\Live' 2>/dev/null || true
    warn "$n residual process(es) stopped — prefix wine freed."
  else
    ok "No residual Ableton/patch/wine process."
  fi
}

# ───────────────────────── Uninstalling editions ─────────────────────────
# Lists every edition folder in ProgramData/Ableton, including the update
# leftovers ".X_updated" (5 GB) left by an interrupted transaction.
# Proposes a multi-selection ("1 3" / "1,3" / "1-3") and deletes the chosen
# folders + their menu entries. The other editions remain installed.
step_uninstall(){
  local ableton_root="$HOME/.wine-ableton/drive_c/ProgramData/Ableton"
  local all_dirs=()
  local d label i=1 choice sel_input n sel n2 line
  hr; msg "Uninstall of Ableton editions (several at once ?)"
  if [[ ! -d "$ableton_root" ]]; then
    warn "No edition folder in $ableton_root — nothing to uninstall."
    return 0
  fi

  # Main edition folders ("Live 12 Suite", "Live 12 Intro", ...) then
  # update leftovers (".Live 12 Suite_updated", ...) — listed in this order.
  for d in "$ableton_root"/Live*/; do
    [[ -d "$d" ]] && all_dirs+=("${d%/}")
  done
  for d in "$ableton_root"/.*_updated; do
    [[ -d "$d" ]] && all_dirs+=("${d%/}")
  done

  [[ "${#all_dirs[@]}" -gt 0 ]] || {
    warn "No edition found in $ableton_root."
    return 0
  }

  for d in "${all_dirs[@]}"; do
    label="$(basename "$d")"
    if [[ "$label" = .*_updated ]]; then
      printf ' %2d) %s   (update leftover — %s)\n' "$i" "$label" "$(du -sh "$d" 2>/dev/null | cut -f1 || echo '?')"
    else
      printf ' %2d) %s\n' "$i" "$label"
    fi
    i=$((i+1))
  done
  echo
  local -a update_dir_list=()
  for d in "${all_dirs[@]}"; do [[ "$(basename "$d")" = .*_updated ]] && update_dir_list+=("$d"); done
  [[ "${#update_dir_list[@]}" -gt 0 ]] && \
    warn "The _updated folders are duplicates of an interrupted update: safe to delete."

  if (( YES )); then
    sel_input="$(seq 1 $((i-1)) | tr '\n' ' ')"
  else
    read -rp "Uninstall which ones ? [numbers separated by spaces/commas or range] (Enter=none) " sel_input
  fi
  [[ -n "$sel_input" ]] || { ok "Nothing uninstalled."; return 0; }

  # "1,3" -> "1 3" ; "1-3" -> "1 2 3"
  sel_input="${sel_input//,/ }"
  local -a sel_list=()
  if [[ "$sel_input" =~ ^[0-9-]+([[:space:]][0-9-]+)*$ ]]; then
    for n in $sel_input; do
      if [[ "$n" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        for ((n2=${BASH_REMATCH[1]}; n2<=${BASH_REMATCH[2]}; n2++)); do sel_list+=("$n2"); done
      else
        sel_list+=("$n")
      fi
    done
  else
    err "Invalid input — numbers separated by spaces (e.g. 1 3) or range (e.g. 2-4)."
    return 1
  fi

  local removed=0 total=${#all_dirs[@]}
  for sel in "${sel_list[@]}"; do
    (( sel >= 1 && sel <= total )) || { warn "Number $sel out of range — ignored."; continue; }
    d="${all_dirs[$((sel-1))]}"
    [[ -d "$d" ]] || continue
    line="$(basename "$d")"
    msg "Removing $line …"
    pkill -f "ProgramData/Ableton/${line}/" 2>/dev/null || true   # closes the edition if it is running
    rm -rf -- "$d"
    # Remove the corresponding menu entry
    local entry
    for entry in "$HOME/.local/share/applications/ableton-live-"*.desktop; do
      if grep -qF "$line/Program/Ableton Live" "$entry" 2>/dev/null; then
        rm -f -- "$entry"
        ok "Menu entry removed: $(basename "$entry")"
      fi
    done
    ok "Deleted: $line"
    removed=$((removed+1))
  done
  if (( removed )); then
    command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1
    ok "$removed edition(s) uninstalled."
  else
    ok "Nothing deleted."
  fi
}

# ───────────────────────── Summary ─────────────────────────
recap(){
  hr; msg "Ableton Live native Linux — ready"
  ok "Launch: ableton-live   (or via the application launcher)"
  echo
  local editions
  editions="$(installed_editions | sort -u | tr '\n' ' ' | sed 's/ $//')"
  if [[ -n "$editions" ]]; then
    echo " • Installed editions: ${editions}"
  fi
  if [[ "$(installed_editions | sort -u | wc -l)" -gt 1 ]]; then
    echo " • Several editions on the same prefix: specify which one to launch:"
    echo "     env ABLETON_LIVE_EXE=\"\$HOME/.wine-ableton/drive_c/ProgramData/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe\" ableton-live"
  fi
  echo
  echo " • First audio setup: Settings > Audio > Driver ASIO > Device PipeASIO."
  echo " • Menu entry gone? Repair manually:"
  echo "     bash \"$SCRIPT_DIR/PATCH/fixes/fix-menu.sh\""
  echo " • Windows plugins in the Ableton environment:"
  echo "     <shared root>/vst3  -> C:\\Program Files\\Common Files\\VST3     (shared, auto-scanned)"
  echo "     <shared root>/vst   -> C:\\Program Files\\Steinberg\\VSTPlugins  (shared ; in Live:"
  echo "                    Settings > Plug-Ins > VST Plug-In Custom Folder > this folder, then On)"
  echo " • Bitwig/REAPER see the same plugins via yabridge (already linked)."
  echo " • Plugin activation (iLok...) : to do IN the Ableton prefix:"
  echo "     env WINEPREFIX=\"$HOME/.wine-ableton\" \\"
  echo "       \"$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine\" path/InstallerOrLocaleManager.exe"
  echo " • Update the runtime: sh \"$RUN_INSTALLER\" update"
  echo " • Official help: https://github.com/shibco/ableton-linux (README + TROUBLESHOOTING)"
  hr
}

# ───────────────────────── Choice menu ─────────────────────────
# Offered at the interactive launch (without flag) : install/update,
# uninstall one or several editions, link the plugins, or quit.
step_main_menu(){
  local choice installed=0
  ableton_installed && installed=1
  echo
  echo "   What to do ?"
  if (( installed )); then
    echo "    1) Reinstall / update (already installed)"
  else
    echo "    1) Install Ableton Live"
  fi
  echo "    2) Uninstall editions (one or several)"
  echo "    3) Link the shared VST plugins (all DAWs)"
  echo "    4) Status"
  echo "    5) Quit"
  echo
  read -rp "   Choice [1-5] : " choice
  case "$choice" in
    1) return 0 ;;              # normal installation flow
    2) step_cleanup; step_uninstall; exit 0 ;;
    3) step_links; echo; ok "VST links updated."; exit 0 ;;
    4) exit 0 ;;                # the status has already been shown at the start
    5|q|Q) echo "Bye."; exit 0 ;;
    *) warn "Invalid choice — we continue the installation." ; return 0 ;;
  esac
}

# ───────────────────────── Opening the install folder at the end ─────────────────────────
# Repeats the logic (sourced function) of PATCH/fixes/open-patched-folder.sh: open the
# install folder of the last patched Ableton in the file explorer.
open_last_patched_folder(){
  local f="$SCRIPT_DIR/PATCH/fixes/open-patched-folder.sh"
  if [[ -f "$f" ]]; then
    # subshell: the source defines ableton_open_folder without polluting the script
    ( source "$f"; ableton_open_folder ) || true
  else
    warn "PATCH/fixes/open-patched-folder.sh not found ($f) — open the edition manually."
  fi
}

# ───────────────────────── Main ─────────────────────────
main(){
  msg "install-ableton — Ableton Live native Linux + multi-DAW VST sharing"
  status_check

  if ((UNINSTALL_ONLY)); then step_cleanup; step_uninstall; exit 0; fi
  if ((STATUS_ONLY)); then exit 0; fi
  if ((LINKS_ONLY)); then step_links; exit 0; fi
  if ((UPDATE_ONLY)); then step_update_check; exit 0; fi

  # Without flag and interactive (TTY), we propose the Install/Uninstall menu.
  if [[ ! -t 0 ]] && (( ! YES )); then echo "stdin without a TTY: a flag is required (e.g. -y, --uninstall)." >&2; exit 0; fi
  if (( ! YES )); then
    step_main_menu
  fi

  step_prereqs; echo
  step_pydeps;  echo
  step_cleanup; echo
  step_update_check; echo
  step_install;  echo
  step_block_updates; echo
  step_hypr_rules; echo
  step_links;    echo
  step_menu_entries; echo
  step_patch;     echo
  recap

  if ableton_installed; then
    ok "Installation finished — launch 'ableton-live' for your first session."
  else
    warn "Ableton was not installed (cancelled or installer failure). You can always relaunch."
  fi

  # Closing: press a key → opens the install folder of the last patched Ableton.
  if [[ -t 0 ]]; then
    echo
    ok "Press a key to close — the Ableton folder will open in the file explorer."
    read -r -s -n1 2>/dev/null || true
    printf '\r\033[K\n'
    open_last_patched_folder
  fi
}

main "$@"
