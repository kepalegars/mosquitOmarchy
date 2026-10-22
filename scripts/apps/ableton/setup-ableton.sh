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
#   ./setup-ableton.sh -i           # install flow only, with interactive prompts
#   ./setup-ableton.sh --links      # only (re)links the shared VST folders
#   ./setup-ableton.sh --status     # current state, without modifying anything
#   ./setup-ableton.sh -u|--uninstall  # uninstall editions ONE BY ONE; removing the
#                                       # last one also removes the prefix via the
#                                       # official .run (see step_uninstall)
#   ./setup-ableton.sh -y -u        # automatic: every edition one by one + prefix
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
# power profile; your mosquito.power/ultra-save manager keeps control). One-off
# override: POWER=performance|balanced ./setup-ableton.sh -y
#
# Audio buffer: by default --audio-buffer=512 (the most stable value for
# ASIO/PipeASIO on this machine). One-off override:
# BUFFER=64|128|256|1024 ./setup-ableton.sh -y
#
# One archive per run: if several zips are in the folder (e.g. Suite +
# Intro), the script asks WHICH ONE to install now. Several editions can
# coexist in the prefix, each with its own launcher entry. Uninstall asks
# for one edition at a time; removing the last edition also removes the
# whole Ableton runtime/prefix.
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
POWER_DEFAULT="${POWER:-off}"   # off = do not change the power profile (mosquito.power keeps control)
BUFFER_DEFAULT="${BUFFER:-512}" # 512 frames = stable latency for PipeASIO

YES=0 LINKS_ONLY=0 STATUS_ONLY=0 UNINSTALL_ONLY=0 UPDATE_ONLY=0 INSTALL_ONLY=0
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  -i|--install) INSTALL_ONLY=1 ;;
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

# Like ask, but with explicit action labels. Used for the install/uninstall
# confirmations so the buttons read Install/Cancel and Uninstall/Cancel.
ask_action(){
  local q="$1" yes="${2:-Yes}" no="${3:-No}" def="${4:-n}" r
  ((YES)) && { ok "(auto) $q -> $yes"; return 0; }
  if command -v gum >/dev/null; then
    gum confirm "$q" --affirmative="$yes" --negative="$no" \
      --default=$([[ $def == y ]] && echo true || echo false) && return 0 || return 1
  fi
  printf '%s\n' "$q"
  read -rp "  $yes / $no [default: $([[ $def == y ]] && echo "$yes" || echo "$no")] : " r
  r="${r:-$def}"
  case "${r,,}" in
    y|yes|o|oui|install|uninstall) return 0 ;;
    *) return 1 ;;
  esac
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

# ───────────────── Check the manually-downloaded installer at opening ─────────
# Ableton Live itself is NOT public: the user must download the edition zip
# (Intro/Standard/Suite) from their ableton.com account and drop it here. The
# Linux runtime (install-ableton-latest.run) is fetched automatically. Warn
# clearly, up front, when the zip is missing — and name the expected file.
check_manual_installer(){
  local -a z=()
  local f
  for f in "$SCRIPT_DIR"/Ableton*.zip "$SCRIPT_DIR"/ableton*.zip; do [[ -f $f ]] && z+=("$f"); done
  if ((${#z[@]})); then
    ok "Ableton Live installer present: $(basename "${z[0]}")"
    return 0
  fi
  hr
  warn "Missing manual download — no Ableton Live .zip in $SCRIPT_DIR/"
  warn "  Expected file: Ableton_Live_<edition>_<version>_64.zip (Intro / Standard / Suite)"
  warn "  → download it from your Ableton account and drop the .zip here:"
  warn "    https://www.ableton.com/en/account/"
  warn "    $SCRIPT_DIR/"
  warn "  (the Linux runtime install-ableton-latest.run is downloaded automatically)"
  hr
  return 1
}

# ───────────────────────── Selecting the edition to install ─────────────────────────
# When several zips are present, the user picks exactly one per run; it is
# then passed alone to the native installer. Existing editions stay installed,
# so another edition can be added by running the setup again. Fills the
# global array SEL_ZIPS with that single path.
SEL_ZIPS=()
select_edition(){
  local -a cand=("$@")
  SEL_ZIPS=()
  (( ${#cand[@]} )) || return 1
  if (( ${#cand[@]} == 1 )); then
    SEL_ZIPS=("${cand[0]}")
    return 0
  fi
  if (( YES )); then
    SEL_ZIPS=("${cand[0]}")
    warn "Automatic mode: first archive selected ($(basename "${cand[0]}"))."
    warn "Run without -y to choose another edition/version."
    return 0
  fi
  local i=1 z base ed ver sel
  hr; msg "Several Ableton archives found — which one to install now?"
  for z in "${cand[@]}"; do
    base="${z##*/}"
    ed="$(zip_edition "$z")"
    ver="${base%_64.zip}"; ver="${ver##*_}"   # 12.3.6 / 12.4.5 …
    printf '  %2d) %-8s (version %s)\n' "$i" "$ed" "$ver"
    i=$((i+1))
  done
  echo
  read -rp "  Which one to install? [1-$((i-1)), Enter = 1] : " sel
  [[ -n "$sel" ]] || sel=1
  if [[ ! "$sel" =~ ^[0-9]+$ ]] || (( 10#$sel < 1 || 10#$sel > ${#cand[@]} )); then
    warn "Invalid choice ($sel) — keeping 1."
    sel=1
  fi
  SEL_ZIPS=("${cand[$((10#$sel-1))]}")
}

# ───────────────────────── Detection / state ─────────────────────────
ableton_installed(){
  [[ -f "$HOME/.local/bin/ableton-live" || -d "$HOME/.wine-ableton/drive_c" ]]
}
ableton_version(){
  [[ -x "$HOME/.local/bin/ableton-live" ]] && "$HOME/.local/bin/ableton-live" --version 2>/dev/null | head -1 | tr -d '\r' || echo "unknown"
}

# active_transactions → newest first. A transaction left with an `active`
# marker means an install stopped before it committed or restored its Wine
# runtime/prefix; the ableton-live launcher then refuses to start Live.
active_transactions(){
  local root="$HOME/.local/state/ableton-wine/transactions"
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 2 -maxdepth 2 -type f -name active -printf '%T@\t%h\n' 2>/dev/null \
    | sort -rn | cut -f2-
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
  if (( STATUS_ONLY )); then
    local -a active=()
    mapfile -t active < <(active_transactions)
    if (( ${#active[@]} )); then
      warn "${#active[@]} interrupted install transaction(s) found — Live will refuse to launch."
      warn "Run: $SCRIPT_DIR/setup-ableton.sh -i   (or -y) to restore the previous runtime/prefix."
    fi
  fi
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
# The upstream .run runs winetricks with -f, so vcrun2022 re-runs on every
# existing prefix and vc_redist exits 102 ("already installed / reboot
# required"), which winetricks treats as fatal (step 4). The prefix already has
# a winetricks.log entry for it. Running the same installer from a temporary
# copy with -f removed lets winetricks skip the verbs it has already applied.
# The original .run stays byte-identical; only the copy is edited, and the
# copy's official transaction/rollback still runs.
ableton_winetricks_cache_ready(){
  local log="$HOME/.wine-ableton/winetricks.log" dll
  [[ -f "$log" ]] && grep -qx 'vcrun2022' "$log" || return 1
  for dll in vcruntime140.dll vcruntime140_1.dll msvcp140.dll msvcp140_1.dll; do
    [[ -s "$HOME/.wine-ableton/drive_c/windows/system32/$dll" ]] || return 1
  done
}

install_with_cached_winetricks(){
  local zip="$1" workdir patched rc newest
  [[ -n "$zip" ]] || return 1
  [[ -n "$RUN_INSTALLER" ]] || { err "No install-ableton-latest.run found in $SCRIPT_DIR/"; return 1; }
  command -v python3 >/dev/null 2>&1 || { err "python3 is required for the existing-prefix workaround."; return 1; }
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/ableton-install-workaround.XXXXXX")" || return 1
  patched="$workdir/install-ableton-latest.run"
  if ! cp -- "$RUN_INSTALLER" "$patched" \
     || ! python3 - "$patched" <<'PATCHER'
import sys
path = sys.argv[1]
anchor = b'bash "$kit/scripts/installer.sh" "${original_args[@]}"'
inject = b"""python3 - "$kit/scripts/setup-prefix.sh" <<'PATCHKIT'
import sys
p = sys.argv[1]
old = b'bash "$root/vendor/winetricks" -q -f "${verbs[@]}"'
new = b'bash "$root/vendor/winetricks" -q    "${verbs[@]}"'
data = open(p, 'rb').read()
if data.count(old) != 1:
    raise SystemExit("expected exactly one winetricks invocation")
open(p, 'wb').write(data.replace(old, new, 1))
PATCHKIT
""" + anchor
data = open(path, 'rb').read()
if data.count(anchor) != 1:
    raise SystemExit("expected exactly one installer.sh launch")
# The anchor is in the wrapper header, before __PAYLOAD_BELOW__, so the
# embedded payload (and its SHA-256) is untouched. The extracted kit is
# patched after its own integrity check.
open(path, 'wb').write(data.replace(anchor, inject, 1))
PATCHER
  then
    rm -rf -- "$workdir"
    err "Could not prepare the existing-prefix installer copy."
    warn "The .run layout may have changed; for an existing install run:"
    warn "  sh \"$RUN_INSTALLER\" update"
    return 1
  fi
  msg "Existing prefix: reusing the Winetricks verbs already applied (no -f)."
  msg "This avoids re-running vcrun2022 (step 4) while keeping the .run transaction intact."
  local -a cached_args=(install --live-installer "$zip"
    --power="$POWER_DEFAULT" --audio-buffer="$BUFFER_DEFAULT")
  if ((YES)); then cached_args+=(--yes); fi
  sh "$patched" "${cached_args[@]}"
  rc=$?
  newest="$(ls -1t "$workdir"/ableton-linux-installer-*.log 2>/dev/null | head -1 || true)"
  if [[ -n "$newest" ]]; then
    cp -p -- "$newest" "$SCRIPT_DIR/" 2>/dev/null || true
    msg "Saved installer log: $(basename "$newest")"
  fi
  rm -rf -- "$workdir"
  return "$rc"
}

step_install(){
  local z ed
  local -a installed_list=()

  if ableton_installed; then
    # A module update re-applies the script, not the Live application. Running
    # the install flow here used to pick the first archive present and add a
    # different edition (Suite) on top of the installed one. Refresh the
    # runtime/prefix/integration instead; adding an edition stays an explicit
    # install action.
    if [[ "${MOSQUITOMARCHY_UPDATE:-0}" == 1 ]]; then
      [[ -n "$RUN_INSTALLER" ]] || { err "No install-ableton-latest.run found in $SCRIPT_DIR/"; return 1; }
      msg "Update mode: keeping installed editions; refreshing runtime/prefix/integration."
      sh "$RUN_INSTALLER" update --power="$POWER_DEFAULT" --audio-buffer="$BUFFER_DEFAULT"
      return $?
    fi
    while IFS= read -r ed; do [[ -n "$ed" ]] && installed_list+=("$ed"); done < <(installed_editions | sort -u)
    if (( ${#installed_list[@]} > 0 )); then
      ok "Ableton already installed (${installed_list[*]}, $(ableton_version))"
      if (( ${#LIVE_ZIPS[@]} == 0 )); then
        warn "No Ableton zip in this folder — cannot install another edition/version."
        warn "For a new version of the runtime/launcher:"
        warn "  sh \"$RUN_INSTALLER\" update   (updates the runtime, keeps Live/licenses)"
        return 0
      fi
      select_edition "${LIVE_ZIPS[@]}"
      z="${SEL_ZIPS[0]}"
      ed="$(zip_edition "$z")"
      if printf '%s\n' "${installed_list[@]}" | grep -qx "$ed"; then
        msg "Reinstalling/updating: $ed"
      else
        msg "Installing '$ed' alongside: ${installed_list[*]}"
      fi
      do_install "$z"
      return $?
    fi
    # Runtime/prefix exists but no edition: fall through and install one.
  fi

  [[ -n "$RUN_INSTALLER" ]] || { err "No install-ableton-latest.run found in $SCRIPT_DIR/"; return 1; }
  if (( ${#LIVE_ZIPS[@]} == 0 )); then
    if ((YES)); then
      warn "No Ableton zip found in $SCRIPT_DIR/ — the installer will try to find one itself."
      do_install ""
    elif resolve_missing_zips; then
      select_edition "${LIVE_ZIPS[@]}"
      do_install "${SEL_ZIPS[0]}"
    fi
  else
    select_edition "${LIVE_ZIPS[@]}"
    do_install "${SEL_ZIPS[0]}"
  fi
}

# Uncompressed payload size from the zip central directory. The installer
# expands the edition into the Wine prefix, so the compressed file size on
# disk says nothing about whether the install can fit.
ableton_required_kb(){
  local zip="$1" bytes
  [[ -f "$zip" ]] || return 1
  command -v unzip >/dev/null 2>&1 || return 1
  bytes="$(unzip -Z -t "$zip" 2>/dev/null | awk '
    /bytes uncompressed/ {
      for (i = 2; i <= NF; i++)
        if ($i == "bytes") value = $(i - 1)
    }
    END { if (value != "") print value }
  ')"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
  # Payload + 1.5 GiB for the runtime, staging copy and the installer's
  # transaction workspace. The upstream installer also warns below 10 GiB
  # free, because the Wine runtime, prefix, Live payload and rollback snapshot
  # coexist during the transaction. Keep the stricter of the two.
  local payload_kb=$(( (bytes + 1023) / 1024 ))
  local need_kb=$(( payload_kb + 1536 * 1024 ))
  local upstream_min_kb=$(( 10 * 1024 * 1024 ))
  (( need_kb < upstream_min_kb )) && need_kb=$upstream_min_kb
  echo "$need_kb"
}

fmt_gb(){
  awk -v kb="${1:-0}" 'BEGIN { printf "%.1f GB", kb / 1024 / 1024 }'
}

DISK_FREE_H=""
DISK_REQUIRED_H=""
disk_preflight(){
  local zip="$1" need_kb free_kb
  DISK_FREE_H=""
  DISK_REQUIRED_H=""
  if [[ -z "$zip" || ! -f "$zip" ]]; then
    warn "Disk space: no edition zip selected — required space cannot be estimated."
    return 0
  fi
  if ! need_kb="$(ableton_required_kb "$zip")"; then
    warn "Disk space: cannot read the uncompressed size of $(basename "$zip")."
    return 0
  fi
  free_kb="$(df -Pk -- "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [[ "$free_kb" =~ ^[0-9]+$ ]] || { warn "Disk space: cannot read the free space on $HOME."; return 0; }

  DISK_FREE_H="$(fmt_gb "$free_kb")"
  DISK_REQUIRED_H="$(fmt_gb "$need_kb")"
  msg "Disk space for $(basename "$zip"):"
  msg "  Free space    : $DISK_FREE_H"
  msg "  Required space: ~$DISK_REQUIRED_H (payload + runtime/workspace, 10 GiB minimum)"
  if (( free_kb >= need_kb )); then
    ok "Enough free space for the installation."
    return 0
  fi

  err "Not enough free space on $HOME: $DISK_FREE_H free, ~$DISK_REQUIRED_H required."
  err "Short by: ~$(fmt_gb $((need_kb - free_kb)))."
  if [[ "${ABLETON_ALLOW_LOW_SPACE:-0}" == "1" ]]; then
    warn "ABLETON_ALLOW_LOW_SPACE=1 — continuing despite low disk space."
    return 0
  fi
  err "Aborting before the installer starts. Moving unused Ableton edition archives"
  err "to another disk is the quickest way to free space. Only set"
  err "ABLETON_ALLOW_LOW_SPACE=1 if you accept a likely rollback."
  return 1
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
  # In automatic mode (-y) the upstream prompts (DPI, shortcuts, Link) use
  # their saved/default answers too; without this the TUI runner would block on
  # a prompt it cannot show. Interactive installs keep their prompts.
  if ((YES)); then cmd+=(--yes); fi
  local use_cached=0
  if [[ -n "$zip" ]] && ableton_installed && ableton_winetricks_cache_ready; then
    use_cached=1
  fi
  if ((YES)); then
    disk_preflight "$zip" || return 1
    if ((use_cached)); then
      install_with_cached_winetricks "$zip"
      return $?
    fi
    msg "Command: ${cmd[*]}"
    "${cmd[@]}"
    return $?
  fi
  msg "Launching the official installer with the default values:"
  msg "  --power=$POWER_DEFAULT (power profile not modified; mosquito.power keeps control)"
  msg "  --audio-buffer=$BUFFER_DEFAULT frames (256 and below = more dropouts/glitches)"
  msg "  dpi=auto, rt=auto, shortcuts=take (the project defaults)."
  msg "  The 6 pre-flight questions are NOT asked: on an explicit 'install'"
  msg "  command, the installer applies the defaults/options passed."
  msg "  (To choose each option by hand: run the .run without argument.)"
  echo
  disk_preflight "$zip" || return 1
  echo
  local q="Install $(basename "${zip:-Ableton Live}") now?"
  [[ -n "$DISK_FREE_H" ]] && q+=$'\n\n'"Free space    : $DISK_FREE_H"
  [[ -n "$DISK_REQUIRED_H" ]] && q+=$'\n'"Required space: ~$DISK_REQUIRED_H"
  if ! ask_action "$q" "Install" "Cancel" y; then warn "Installation cancelled."; return 1; fi
  if ((use_cached)); then
    install_with_cached_winetricks "$zip"
    return $?
  fi
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
  msg "Ableton windows: Hyprland rules (tile main window, float installer, opaque)"

  if [[ ! -f "$HYPR_FILE" ]]; then
    warn "hyprland config missing: $HYPR_FILE — rules not applied."
    echo "   Add manually: see scripts/apps/ableton/setup-ableton.sh step_hypr_rules"
    return 0
  fi

  # The rules live in ONE marked block that is rewritten on every run. Appending
  # a line per rule (the previous shape) meant an edited or removed rule could
  # never be updated: the grep guard saw the old text, printed nothing, and the
  # stale rule stayed in hyprland.lua forever.
  local added=0

  # NB: we no longer touch the cursor/touchpad management. We removed the Ableton
  # scroll_touchpad rule (and any cursor= option in input.lua): it broke the
  # two-finger scroll in Nautilus. The rest is left to the Omarchy default.

  # Strip a previously injected block so re-running after an edit actually
  # updates hyprland.lua (idempotent update, not just idempotent insert).
  if grep -qF -- '-- >>> ableton-setup >>>' "$HYPR_FILE"; then
    sed -i '/-- >>> ableton-setup >>>/,/-- <<< ableton-setup <<</d' "$HYPR_FILE"
    added=1
  fi

  # Remove the LEGACY rules, appended bare by the previous version of this
  # step (no marker around them, so nothing could ever remove or update them).
  # They are byte-for-byte the two rules the marked block re-adds, so deleting
  # the unmarked copies leaves exactly one of each. Done AFTER the block strip
  # so a fresh block is never caught by it.
  local -a legacy_rules=(
    'o.window({ class = "^ableton live 12 .*install.*$" }, { float = true })'
    'o.window({ class = "^ableton.*$" }, { tag = "-default-opacity", opaque = true })'
  )
  local legacy
  for legacy in "${legacy_rules[@]}"; do
    if grep -qF -- "$legacy" "$HYPR_FILE"; then
      # Compare-and-swap, so the file is only rewritten when the rule is
      # really there (grep -q then sed -i is a silent no-op on a race).
      if grep -qxF -- "$legacy" "$HYPR_FILE"; then
        grep -vxF -- "$legacy" "$HYPR_FILE" > "$HYPR_FILE.tmp" && mv "$HYPR_FILE.tmp" "$HYPR_FILE"
        ok "legacy unmarked rule removed"
        added=1
      fi
    fi
  done

  cat >> "$HYPR_FILE" <<'EOF'
-- >>> ableton-setup >>> Ableton Live window handling.
--
-- Four rules:
--   1. the Windows installer (wine / XWayland) floats — it is a small
--      wizard with its own sizing and it crashes the tiled layout otherwise;
--   2. every Ableton window is fully opaque, because Omarchy's default
--      translucency makes a dark DAW unreadable;
--   3. everything with Live's class floats: VST/VST3 editors and Live's own
--      dialogs/popups share WM class "ableton live 12 <edition>.exe" with the
--      main window (verified with hyprctl clients), so a class-only
--      float=false tiled every plugin GUI;
--   4. the main window is the exception and tiles, recognised by its title
--      suffix "<project> - Ableton Live 12 <Edition>" (verified at map time:
--      "Untitled - Ableton Live 12 Suite"). No center/size on this class: a
--      Wine plugin editor moved away from the origin gets offset mouse
--      coordinates (yabridge#409). float=false only, no tile=true: the
--      explicit tile rule broke fullscreen. Later rules win, hence the order.
o.window({ class = "^ableton live 12 .*install.*$" }, { float = true })
o.window({ class = "^ableton.*$" }, { tag = "-default-opacity", opaque = true })
o.window({ class = "^ableton live 12 (suite|standard|intro)\\.exe$" }, { float = true, no_blur = true })
o.window({ class = "^ableton live 12 (suite|standard|intro)\\.exe$", title = ".* - Ableton Live 12 (Suite|Standard|Intro)$" }, { float = false })
-- <<< ableton-setup <<<
EOF
  added=1
  ok "Hyprland rules written (main window tiled, installer floating, all opaque)"

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
#
# The removal above only lasts until the next launch: the launcher runs
# repair_live_desktop_entry() even when started from one of our targeted
# entries, and writes the generic entry back. Patch that function once so it
# keeps the menu consistent with the installed editions: no generic entry with
# several editions, and no targeted leftovers with a single one (the case after
# uninstalling one of two: the generic entry then reappeared next to the
# remaining targeted one). The .run may replace the launcher during an
# install/update, so this is re-applied on every run.
patch_launcher_multi_edition(){
  local launcher="$HOME/.local/bin/ableton-live"
  [[ -f "$launcher" ]] || return 0
  command -v python3 >/dev/null 2>&1 || {
    warn "python3 missing — cannot stop the launcher from recreating the duplicate entry."
    return 0
  }
  python3 - "$launcher" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
marker = "mosquitOmarchy: keep targeted edition entries"
cleanup_marker = "Single edition: this function writes the generic entry"
anchor = "repair_live_desktop_entry()\n{\n"
old_guards = (
    (
        "    # mosquitOmarchy: keep targeted edition entries; the generic one\n"
        "    # duplicates the selected edition and cannot choose one by itself.\n"
        "    [ \"${live_count:-0}\" -gt 1 ] && return 0\n"
    ),
    (
        "    # mosquitOmarchy: keep targeted edition entries; the generic one\n"
        "    # duplicates the selected edition and cannot choose one by itself.\n"
        "    local _edition_count=0 _edition_exe\n"
        "    for _edition_exe in \"$WINEPREFIX\"/drive_c/ProgramData/Ableton/*/Program/\"Ableton Live\"*.exe; do\n"
        "        [ -f \"$_edition_exe\" ] && _edition_count=$((_edition_count + 1))\n"
        "    done\n"
        "    [ \"$_edition_count\" -gt 1 ] && return 0\n"
    ),
)
guard = (
    "    # mosquitOmarchy: keep targeted edition entries; the generic one\n"
    "    # duplicates the selected edition and cannot choose one by itself.\n"
    "    local _edition_count=0 _edition_exe\n"
    "    for _edition_exe in \"$WINEPREFIX\"/drive_c/ProgramData/Ableton/*/Program/\"Ableton Live\"*.exe; do\n"
    "        [ -f \"$_edition_exe\" ] && _edition_count=$((_edition_count + 1))\n"
    "    done\n"
    "    [ \"$_edition_count\" -gt 1 ] && return 0\n"
    "    # Single edition: this function writes the generic entry, so remove the\n"
    "    # targeted ones (left behind after uninstalling the other edition).\n"
    "    rm -f -- \"${XDG_DATA_HOME:-$HOME/.local/share}/applications\"/ableton-live-*.desktop\n"
)
if cleanup_marker in text:
    sys.exit(0)
old = next((g for g in old_guards if g in text), None)
if old is not None:
    text = text.replace(old, guard, 1)
elif marker in text:
    sys.exit(2)
elif anchor in text:
    text = text.replace(anchor, anchor + guard, 1)
else:
    sys.exit(2)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY
  case $? in
    0) ok "Launcher patched: menu entry count follows the installed editions." ;;
    *) warn "Could not patch the launcher — duplicate menu entries may reappear after a launch." ;;
  esac
  return 0
}

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
    patch_launcher_multi_edition
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

  # Driven by the mosquitOmarchy TUI: never auto-apply here. The TUI detects the
  # patch script and proposes it (only when present) after the install, exactly
  # like the pre-TUI launcher did.
  if [[ -n ${MOSQUITOMARCHY_TUI:-} ]]; then
    ok "Patch available ($(basename "$helper")) — the TUI proposes it after the install."
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
  # 2b) A launcher still finishing its previous session holds the installer
  #     lifecycle lock (flock on $HOME); recovery and install would fail until
  #     it exits. It is the module's own launcher, so stopping it is safe here.
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    kill "$p" >/dev/null 2>&1 && n=$((n+1))
  done < <(pgrep -f "$HOME/.local/bin/ableton-live" 2>/dev/null || true)
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
      [[ -r "/proc/$p2/environ" ]] || continue
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

# ───────────────────────── Interrupted-install recovery ─────────────────────────
# A killed/aborted native install leaves a transaction with an `active`
# marker and complete backups of the Wine runtime and the prefix. The
# ableton-live launcher refuses to start Live rather than run on that
# half-installed state. Restore the newest transaction (the failed attempt)
# with the installer's own rollback helpers, then retire the older stale
# markers that were superseded by it.
#
# Only the NEWEST transaction is rolled back: its backup was taken after the
# older ones, so applying an older backup afterwards would undo the newer
# state (for example, remove Live Suite restored by the newer backup).
step_recover_transactions(){
  local -a txns=()
  mapfile -t txns < <(active_transactions)
  (( ${#txns[@]} )) || return 0

  msg "Recovery of an interrupted Ableton installation"
  warn "${#txns[@]} active transaction(s) found — Live would refuse to launch."
  local newest="${txns[0]}" txn rc=0

  # The install committed; only cleanup left the marker behind.
  if [[ -f "$newest/core-complete" || -f "$newest/COMMITTED_CLEANUP_FAILURE" ]]; then
    for txn in "${txns[@]}"; do
      rm -f -- "$txn/active" 2>/dev/null || rc=1
    done
    if (( rc )); then warn "A stale transaction marker could not be removed."; return 1; fi
    ok "Last install had committed — stale marker(s) cleared."
    return 0
  fi

  # A previous recovery already restored this transaction's domains.
  if [[ ! -e "$newest/runtime.tsv" && ! -e "$newest/prefix.tsv" ]] \
     && [[ ! -s "$newest/files.tsv" && ! -d "$newest/prefix-host" ]]; then
    for txn in "${txns[@]}"; do
      rm -f -- "$txn/active" 2>/dev/null || rc=1
    done
    if (( rc )); then warn "A stale transaction marker could not be removed."; return 1; fi
    ok "No recovery data left — stale marker(s) cleared."
    return 0
  fi

  if [[ -z "$RUN_INSTALLER" || ! -f "$RUN_INSTALLER" ]]; then
    warn "Cannot recover automatically: the install-ableton .run is missing."
    warn "Keep the transaction files in $newest and report the problem."
    return 1
  fi

  local kit log
  kit="$(mktemp -d "${TMPDIR:-/tmp}/ableton-recovery.XXXXXX")" || {
    warn "Cannot create a temporary directory for recovery."; return 1; }
  log="$(mktemp "${TMPDIR:-/tmp}/ableton-recovery.XXXXXX")" || {
    rm -rf -- "$kit"; warn "Cannot create a recovery log."; return 1; }

  if ! ( cd "$kit" && sh "$RUN_INSTALLER" extract "$kit" ) >"$log" 2>&1; then
    warn "Could not extract the installer kit — nothing was changed."
    warn "Details: $log"
    rm -rf -- "$kit"
    return 1
  fi
  local prefix_helper="$kit/scripts/setup-prefix.sh" runtime_helper="$kit/scripts/install.sh"
  if [[ ! -f "$prefix_helper" || ! -f "$runtime_helper" ]]; then
    warn "The extracted installer kit is incomplete — nothing was changed."
    warn "Details: $log"
    rm -rf -- "$kit"
    return 1
  fi

  # Check both domains before touching either one.
  bash "$prefix_helper" --preflight-rollback "$newest" </dev/null >>"$log" 2>&1 || rc=1
  bash "$runtime_helper" --preflight-rollback "$newest" </dev/null >>"$log" 2>&1 || rc=1
  if (( rc )); then
    warn "Recovery preflight failed — the previous files were left untouched."
    warn "Details: $log"
    rm -rf -- "$kit"
    return 1
  fi

  bash "$prefix_helper" --rollback "$newest" </dev/null >>"$log" 2>&1 || rc=1
  bash "$runtime_helper" --rollback "$newest" </dev/null >>"$log" 2>&1 || rc=1
  if (( rc )); then
    warn "Automatic recovery did not finish. Keep $newest and the log:"
    warn "  $log"
    rm -rf -- "$kit"
    return 1
  fi

  # The newest attempt is restored; older transactions are superseded.
  for txn in "${txns[@]}"; do
    rm -f -- "$txn/active" 2>/dev/null || rc=1
  done
  rm -rf -- "$kit"
  rm -f -- "$log"
  if (( rc )); then
    warn "Files were restored, but a stale transaction marker could not be removed."
    return 1
  fi
  ok "Previous Wine runtime and prefix restored; the partial install was rolled back."
  ok "Relaunch the installation to continue."
  return 0
}

# ───────────────────────── Uninstalling editions ─────────────────────────
# Lists every edition folder in ProgramData/Ableton, including the update
# leftovers ".X_updated" (5 GB) left by an interrupted transaction. The user
# picks ONE edition, confirms, then its folder and menu entry are removed.
# After that the script asks whether to remove another one. Removing the last
# edition also runs the official installer's uninstall with --delete-prefix,
# for a CLEAN runtime/prefix removal instead of an rm -rf of the prefix by hand.

# uninstall_dirs → the edition dirs, main editions first then update leftovers.
uninstall_dirs(){
  local ableton_root="$HOME/.wine-ableton/drive_c/ProgramData/Ableton" d
  for d in "$ableton_root"/Live*/; do [[ -d "$d" ]] && printf '%s\n' "${d%/}"; done
  for d in "$ableton_root"/.*_updated;  do [[ -d "$d" ]] && printf '%s\n' "${d%/}"; done
}

# dir_label DIR → a human label ("Live 12 Suite", ".Live 12 Suite_updated (…)").
dir_label(){
  local base; base="$(basename "$1")"
  if [[ "$base" = .*_updated ]]; then
    printf '%s   (update leftover — %s)' "$base" "$(du -sh "$1" 2>/dev/null | cut -f1 || echo '?')"
  else
    printf '%s' "$base"
  fi
}

# Clean removal of the runtime/prefix through the official .run, whose own
# scopes are: runtime only (--keep-prefix), prefix only (--prefix-only), all
# (--delete-prefix). Offered once no edition is left in the prefix.
step_run_uninstall(){
  [[ -n "$RUN_INSTALLER" && -f "$RUN_INSTALLER" ]] || {
    warn "install-ableton-*.run absent — the runtime/prefix are left in place."
    return 0
  }
  local forced="${1:-}" scope="" pick c
  if [[ -n "$forced" ]]; then
    scope="$forced"
  elif (( YES )); then
    scope=--delete-prefix
  elif command -v gum >/dev/null; then
    pick="$(printf '%s\n' \
      "Everything — remove the runtime and the prefix" \
      "Runtime only — keep the prefix" \
      "Prefix only — keep the runtime" \
      "Nothing — keep both" \
      | gum choose --header "Also remove the Linux runtime / prefix ?")" || true
    case "$pick" in
      Everything*) scope=--delete-prefix ;;
      Runtime*)    scope=--keep-prefix ;;
      Prefix*)     scope=--prefix-only ;;
      *)           scope="" ;;
    esac
  else
    echo "   Also remove the Linux runtime / prefix ?"
    echo "     a) Everything        r) Runtime only"
    echo "     p) Prefix only       n) Nothing"
    read -rp "   Choice [a/r/p/n] : " c
    case "$c" in
      a|A) scope=--delete-prefix ;; r|R) scope=--keep-prefix ;;
      p|P) scope=--prefix-only ;;   *)   scope="" ;;
    esac
  fi
  [[ -n "$scope" ]] || { ok "Runtime and prefix kept."; return 0; }
  msg "Official uninstaller: sh ${RUN_INSTALLER##*/} uninstall $scope"
  if sh "$RUN_INSTALLER" uninstall "$scope"; then
    rm -f "$HOME/.local/bin/ableton-live" "$HOME/.local/share/applications/ableton-live.desktop"
    command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
    ok "Clean removal done ($scope)."
  else
    warn "The official uninstaller returned $? — check its output above."
  fi
}

step_uninstall(){
  local ableton_root="$HOME/.wine-ableton/drive_c/ProgramData/Ableton"
  local -a all_dirs=() labels=() left=()
  local d i sel sel_input pick label removed=0 entry
  hr; msg "Uninstall of Ableton editions — one at a time"
  if [[ ! -d "$ableton_root" ]]; then
    warn "No edition folder in $ableton_root."
    step_run_uninstall
    return 0
  fi

  while :; do
    all_dirs=(); labels=()
    while IFS= read -r d; do [[ -n "$d" ]] && all_dirs+=("$d"); done < <(uninstall_dirs)
    if (( ${#all_dirs[@]} == 0 )); then
      if (( removed == 0 )); then
        warn "No edition found in $ableton_root."
        step_run_uninstall
      else
        hr; msg "Last edition removed — removing the whole Ableton prefix."
        step_run_uninstall --delete-prefix
      fi
      return 0
    fi
    for d in "${all_dirs[@]}"; do labels+=("$(dir_label "$d")"); done

    local has_upd=0
    for d in "${all_dirs[@]}"; do [[ "$(basename "$d")" = .*_updated ]] && has_upd=1; done
    (( has_upd )) && warn "The _updated folders are duplicates of an interrupted update: safe to delete."
    echo

    if (( YES )); then
      sel=1
    elif command -v gum >/dev/null; then
      pick="$(printf '%s\n' "${labels[@]}" \
        | gum choose --height 15 \
          --header "Select ONE edition to uninstall (the last one removes the prefix)")" || true
      [[ -n "$pick" ]] || { ok "Nothing selected — nothing uninstalled."; return 0; }
      sel=0
      for i in "${!labels[@]}"; do
        [[ "${labels[$i]}" == "$pick" ]] && sel=$((i+1))
      done
      (( sel )) || { warn "Selection lost — nothing uninstalled."; return 0; }
    else
      i=1
      for d in "${all_dirs[@]}"; do printf ' %2d) %s\n' "$i" "$(dir_label "$d")"; i=$((i+1)); done
      echo
      if ! read -rp "Which edition to uninstall? [1-${#all_dirs[@]}, Enter = none] : " sel_input; then
        ok "Nothing uninstalled."
        return 0
      fi
      [[ -n "$sel_input" ]] || { ok "Nothing uninstalled."; return 0; }
      if [[ ! "$sel_input" =~ ^[0-9]+$ ]] || (( 10#$sel_input < 1 || 10#$sel_input > ${#all_dirs[@]} )); then
        warn "Invalid choice ($sel_input) — nothing uninstalled."
        return 1
      fi
      sel="$((10#$sel_input))"
    fi

    d="${all_dirs[$((sel-1))]}"
    label="$(basename "$d")"
    local free_kb free_h q
    free_kb="$(du -sk -- "$d" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    free_h=""
    [[ "$free_kb" =~ ^[0-9]+$ ]] && free_h="$(fmt_gb "$free_kb")"
    q="Uninstall $label ?"
    [[ -n "$free_h" ]] && q+=$'\n\n'"Space freed after uninstall: ~$free_h"
    (( ${#all_dirs[@]} == 1 )) && q+=$'\n'"This is the last edition: the whole Ableton prefix will be removed."
    ask_action "$q" "Uninstall" "Cancel" y \
      || { ok "Cancelled — nothing uninstalled."; return 0; }

    msg "Removing $label …"
    pkill -f "ProgramData/Ableton/${label}/" 2>/dev/null || true
    rm -rf -- "$d"
    for entry in "$HOME/.local/share/applications/ableton-live-"*.desktop; do
      if grep -qF "$label/Program/Ableton Live" "$entry" 2>/dev/null; then
        rm -f -- "$entry"
        ok "Menu entry removed: $(basename "$entry")"
      fi
    done
    command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
    ok "Deleted: $label"
    removed=$((removed+1))

    if (( ! YES )); then
      left=()
      while IFS= read -r d; do [[ -n "$d" ]] && left+=("$d"); done < <(uninstall_dirs)
      if (( ${#left[@]} > 0 )); then
        ask "Uninstall another edition? (${#left[@]} left)" n || return 0
      fi
    fi
  done
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
    echo " • Several editions installed — each one has its own launcher menu entry."
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
# Offered at the interactive launch (without flag): install/update,
# uninstall editions one at a time, link the plugins, or quit.
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
  echo "    2) Uninstall editions (one at a time)"
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
# Read-only: does the module's patch script say the patch is applied? Used to
# decide whether the closing "open the install folder" offer makes sense at all.
# ABLE_PATCH_HELD/MOSQUITOMARCHY_TUI keep the patch script from relaunching in
# foot when this runs without a TTY; the timeout turns an unexpected probe hang
# into "not applied" instead of blocking the end of the setup.
ableton_patch_applied(){
  local p="$SCRIPT_DIR/PATCH/patch-ableton.sh" out
  [[ -f "$p" ]] || return 1
  out="$(ABLE_PATCH_HELD=1 MOSQUITOMARCHY_TUI=1 timeout 15 bash "$p" --check 2>/dev/null || true)"
  # "not applied" also contains "applied"; reject the negative form first.
  grep -qiE 'not[[:space:]]+(applied|patched)|not[[:space:]]+in[[:space:]]+place' <<<"$out" && return 1
  grep -qiE 'applied|in place|patched' <<<"$out"
}

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

  if ((UNINSTALL_ONLY)); then
    step_cleanup
    step_recover_transactions || { err "Aborting: recover the interrupted install before uninstalling."; exit 1; }
    step_uninstall
    exit 0
  fi
  if ((STATUS_ONLY)); then exit 0; fi
  if ((LINKS_ONLY)); then step_links; exit 0; fi
  if ((UPDATE_ONLY)); then step_update_check; exit 0; fi

  # Up-front: name the manually-downloaded file if it is missing. In
  # non-interactive runs (a headless -y apply) abort before touching anything;
  # interactively, the install flow still offers rescan / a typed path.
  if ! check_manual_installer; then
    if (( YES )) || [[ ! -t 0 ]]; then
      err "Aborting: place the Ableton Live .zip in $SCRIPT_DIR/ (see above) and relaunch."
      exit 1
    fi
  fi

  # Without flag and interactive (TTY), we propose the Install/Uninstall menu.
  if [[ ! -t 0 ]] && (( ! YES )); then echo "stdin without a TTY: a flag is required (e.g. -y, --uninstall)." >&2; exit 0; fi
  if (( ! YES )) && (( ! INSTALL_ONLY )); then
    step_main_menu
  fi

  step_prereqs; echo
  step_pydeps;  echo
  step_cleanup; echo
  step_recover_transactions || { err "Aborting: the interrupted install could not be recovered safely."; exit 1; }
  echo
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

  # Closing: only when a patch is actually applied does it make sense to offer
  # the patched install folder. Without a patch there is nothing to open, so do
  # not even propose it.
  if [[ -t 0 ]] && ableton_patch_applied; then
    echo
    ok "Press a key to close — the Ableton folder will open in the file explorer."
    read -r -s -n1 2>/dev/null || true
    printf '\r\033[K\n'
    open_last_patched_folder
  fi
}

main "$@"
