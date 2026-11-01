#!/usr/bin/env bash
# lib-move-manager-features.sh — extended capabilities layered on top of the
# core lib, sourced by the actions backend so the Go TUI can drive them:
#   · Convert a preset        — Ableton Live .adg → Move drum-rack preset
#     (a Move-readable .adg + an .ablpresetbundle with the kit's samples;
#     powers the port of the L2Move Python converter).
#   · Convert a Bitwig preset — Bitwig Drum Machine .bwpreset → Move preset
#     (a Move-readable .adg + a self-contained .ablpresetbundle; built on the
#     module-local bwpreset-converter/convert_bw_kit.py + template_blocks.pkl).
#   · Schwung                 — the Move device's community module system:
#     status / install / update / uninstall, plus its webapp manager
#     (dedicated Chromium profile, exactly like the Move Manager webapp).
#   · Bitwig Move integration — vendored move-bitwig: controller scripts for
#     Bitwig Studio + the on-device module (schwung route), build/install/
#     uninstall + the "add controller" tip.
#
# MUST be sourced AFTER lib-move-manager-core.sh with prefs loaded and the
# project dir resolved (the actions backend already does that). Gate on the
# Move connection the same way every on-device action does: the functions
# here read $connected / detect_move and report a clear JSON status instead
# of hanging when the device isn't reachable.

# ────────────────────────────────── presets ──────────────────────────────────
# The working folder the manager's presets land in. Named exactly "Presets"
# under the configured working directory ($MOVE_DIR), matching the converter's
# own default output root (<working-dir>/Presets).
PRESETS_DIR="$MOVE_DIR/Presets"

find_wine_drive_c() {
  # $1 = any path inside a Wine prefix (e.g. a learned Ableton exe). Echoes
  # the prefix's drive_c, or nothing. "drive_c" is the boundary the Wine
  # layout never varies: wine-system → "…/.wine-ableton/drive_c/…", distrobox
  # containers → "…/gamingbox/…/.wine/drive_c/…". Stopping at drive_c keeps
  # this cross-prefix; anything a sibling module learns is reusable here.
  local p="$1" rest
  [[ -n $p ]] || return 1
  rest="${p%%/drive_c/*}"
  if [[ $rest != "$p" && -d "$rest/drive_c" ]]; then
    printf '%s\n' "$rest/drive_c"
    return 0
  fi
  return 1
}

adg_preset_search_root() {
  # Passed to the converter as --search-root. When the .adg references
  # samples by Windows path (C:/Users/… — how Ableton under Wine saves them),
  # the converter remaps those onto <drive_c>/Users/… . The drive_c comes from
  # the Ableton version chosen in Settings (LEARNED_ABLETON_EXE); without it
  # the converter still falls back to its own relative/basename search.
  if [[ -n ${LEARNED_ABLETON_EXE:-} ]]; then
    find_wine_drive_c "$LEARNED_ABLETON_EXE" && return 0
  fi
  # Same wine prefix the core itself uses for Ableton discovery.
  if [[ -d "$HOME/.wine-ableton/drive_c" ]]; then
    printf '%s\n' "$HOME/.wine-ableton/drive_c"
    return 0
  fi
  printf '%s\n' ""
}

adg_presets_default_dir() {
  # Where the TUI's "Convert a preset" file picker starts: the Ableton preset
  # folders of the version chosen in Settings (Win User Library is where
  # Ableton saves a "Save as preset…"). First existing candidate wins.
  local root drive
  root="$(adg_preset_search_root)" || root=""
  if [[ -n $root ]]; then
    local d
    # Wine on Linux writes the user dir as lowercase "users"; some
    # case-insensitive mounts show "Users". Match either.
    for d in \
      "$root"/[Uu]sers/*/Documents/Ableton/User\ Library/Presets/Instruments/Drum\ Rack \
      "$root"/[Uu]sers/*/Documents/Ableton/User\ Library/Presets/Instruments \
      "$root"/[Uu]sers/*/Documents/Ableton/User\ Library/Presets \
      "$root"/[Uu]sers/*/Documents/Ableton/User\ Library; do
      if [[ -d $d ]]; then
        printf '%s\n' "$d"
        return 0
      fi
    done
  fi
  for d in \
    "$HOME/Documents/Ableton/User Library/Presets/Instruments/Drum Rack" \
    "$HOME/Documents/Ableton/User Library/Presets/Instruments" \
    "$HOME/Documents/Ableton/User Library/Presets" \
    "$HOME/Documents/Ableton/User Library"; do
    if [[ -d $d ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  printf '%s\n' "$HOME"
}

convert_adg_presets() {
  # $@ = one or more .adg preset files → produces, in $PRESETS_DIR, a
  # Move-readable .adg per kit + (samples permitting) an .ablpresetbundle.
  # Exit 0 even when a bundle is skipped (the .adg output is kept — that's a
  # partial success by design); rc=1 only for real failures.
  local bin root out
  bin="${CONVERT_ADG_BIN:-}"
  if [[ -z $bin || ! -f $bin ]] && [[ -f "$(dirname "${BASH_SOURCE[0]}")/convert-adg-to-move" ]]; then
    # Development layout: the converter sits next to this file in the repo.
    bin="$(dirname "${BASH_SOURCE[0]}")/convert-adg-to-move"
  fi
  [[ -n $bin && -f $bin ]] || bin="$BIN_DIR/convert-adg-to-move"
  root="$(adg_preset_search_root)"
  out="${PRESETS_DIR}"
  mkdir -p "$out"
  local -a args=()
  [[ -n $root ]] && args+=(--search-root "$root")
  "$bin" "${args[@]}" -o "$out" "$@"
}

pick_adg_file() {
  # One-off .adg selection (mirror of pick_file_manually, for presets: start
  # in the Ableton preset folder of the Settings-chosen version). Echoes the
  # chosen path, or nothing when cancelled.
  local title="$1" dir chosen=""
  dir="$(adg_presets_default_dir)"
  if [[ $(current_file_picker) == superfile ]] && command -v spf >/dev/null 2>&1; then
    chosen=$(pick_file_via_superfile "$title") || chosen=""
    [[ -n $chosen && -f $chosen ]] || return 1
    printf '%s\n' "$chosen"
    return 0
  fi
  if command -v zenity >/dev/null 2>&1; then
    chosen=$(zenity --file-selection --title="$title" \
      --filename="$dir/" \
      --file-filter="Ableton Live presets | *.adg" 2>/dev/null || true)
  fi
  if [[ -z $chosen ]]; then
    chosen=$(ui_input "$title — full path to the .adg file") || chosen=""
  fi
  [[ -n $chosen && -f $chosen ]] || return 1
  printf '%s\n' "$chosen"
}

# ───────────────────────── Bitwig .bwpreset → Move preset ─────────────────────
# The Bitwig Drum Machine converter ships INSIDE this module, at
# bwpreset-converter/{convert_bw_kit.py,template_blocks.pkl}. It is resolved
# module-local first (repo/dev checkout) and then from the deployed copy under
# $BIN_DIR — the same lookup order convert-adg-to-move uses above.

convert_bwpreset_bin() {
  local module_dir bin
  module_dir="$(dirname "${BASH_SOURCE[0]}")"
  bin="${CONVERT_BWPRESET_BIN:-}"
  if [[ -z $bin || ! -f $bin ]] && [[ -f "$module_dir/bwpreset-converter/convert_bw_kit.py" ]]; then
    bin="$module_dir/bwpreset-converter/convert_bw_kit.py"
  fi
  [[ -n $bin && -f $bin ]] || bin="$BIN_DIR/bwpreset-converter/convert_bw_kit.py"
  printf '%s\n' "$bin"
}

convert_bwpresets() {
  # $@ = one or more Bitwig .bwpreset files → under $PRESETS_DIR (the manager's
  # <working-dir>/Presets): bwpreset/ (source copy), adg/ (.adg + samples/),
  # ablbundle/ (.ablpresetbundle, samples embedded). The working dir comes from
  # the manager settings ($MOVE_DIR), never hardcoded.
  local bin template
  bin="$(convert_bwpreset_bin)"
  if [[ -z $bin || ! -f $bin ]]; then
    err "Bitwig preset converter not found (looked next to the module and in $BIN_DIR/bwpreset-converter)."
    return 1
  fi
  template="$(dirname "$bin")/template_blocks.pkl"
  mkdir -p "$PRESETS_DIR"
  local -a args=(--working-dir "$MOVE_DIR" -o "$PRESETS_DIR")
  [[ -f $template ]] && args+=(--template "$template")
  python3 "$bin" "${args[@]}" "$@"
}

pick_bwpreset_file() {
  # One-off Bitwig .bwpreset selection (mirror of pick_adg_file). The picker
  # starts in the SAME folder as the .adg picker: the drum-rack presets folder
  # of the Ableton version chosen in Settings (a Bitwig Drum Machine preset's
  # .adg counterpart would live there). The conversion OUTPUT still lands in
  # $PRESETS_DIR under the manager working dir.
  local title="$1" dir chosen=""
  dir="$(adg_presets_default_dir)"
  if [[ $(current_file_picker) == superfile ]] && command -v spf >/dev/null 2>&1; then
    chosen=$(pick_file_via_superfile "$title") || chosen=""
    [[ -n $chosen && -f $chosen ]] || return 1
    printf '%s\n' "$chosen"
    return 0
  fi
  if command -v zenity >/dev/null 2>&1; then
    chosen=$(zenity --file-selection --title="$title" \
      --filename="$dir/" \
      --file-filter="Bitwig presets | *.bwpreset" 2>/dev/null || true)
  fi
  if [[ -z $chosen ]]; then
    chosen=$(ui_input "$title — full path to the .bwpreset file") || chosen=""
  fi
  [[ -n $chosen && -f $chosen ]] || return 1
  printf '%s\n' "$chosen"
}

# ────────────────────────────────── Schwung ──────────────────────────────────
SCHWUNG_MANAGER_ID="schwung-manager"
SCHWUNG_MANAGER_NAME="Schwung Manager"
SCHWUNG_WEBAPP_LAUNCHER="$BIN_DIR/schwung-manager-webapp"
SCHWUNG_BASE_URL="https://raw.githubusercontent.com/charlesvestal/schwung/main"

schwung_url() {
  printf 'http://%s:7700\n' "$(move_host)"
}

schwung_http_code() {
  curl -s --max-time 4 -o /dev/null -w '%{http_code}' "$(schwung_url)/" 2>/dev/null || true
}

schwung_status_json() {
  # Reachability of move.local:7700 is the practical "installed?" probe —
  # schwung's manager webapp is what answers there; Move connection is the
  # larger gate checked via detect_move first by the TUI.
  local reachable=false installed=false version=""
  if detect_move; then
    reachable=true
    # Schwung's manager answers with a redirect (303) to its UI, not a 200 —
    # accept any 2xx/3xx so an installed schwung is not reported "not
    # installed" (the user's report: schwung installed yet offered again).
    local code; code="$(schwung_http_code)"
    if [[ $code =~ ^[23] ]]; then
      installed=true
      local page
      page=$(curl -sL --max-time 4 "$(schwung_url)/" 2>/dev/null || true)
      version=$(printf '%s' "$page" | grep -oiE 'schwung[^0-9]{0,12}v?[0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    fi
  fi
  jq -nc --argjson reachable "$reachable" --argjson installed "$installed" \
    --arg version "$version" \
    '{reachable:$reachable, installed:$installed, version:$version}'
}

schwung_latest_version() {
  curl -fsSL --max-time 6 "${SCHWUNG_BASE_URL}/release.json" 2>/dev/null \
    | jq -r '.version // empty' 2>/dev/null \
    || true
}

schwung_run_installer() {
  # Official installer/updater (install.sh doubles as the upgrade path) —
  # interactive (module selection, SSH setup/retries), so it runs in a
  # visible terminal and blocks. Uninstall uses uninstall.sh the same way.
  local title="$1" target_script="$2"
  local script
  if [[ $target_script == http* ]]; then
    # Keep the URL and the temp file DISTINCT: the previous code reused the
    # same variable for both, so it downloaded from the temp path and always
    # failed ("could not download schwung script").
    script="$(mktemp)"
    if ! curl -fsSL --max-time 30 "$target_script" -o "$script" 2>/dev/null; then
      rm -f "$script"
      err "could not download Schwung script ($target_script)"
      return 1
    fi
  else
    script="$target_script"
  fi
  local cmd
  cmd="bash $(printf '%q' "$script")"
  if command -v foot >/dev/null 2>&1; then
    foot --app-id=org.omarchy.schwung-install -e bash -c "$cmd"
  elif command -v xterm >/dev/null 2>&1; then
    xterm -e bash -c "$cmd"
  else
    err "no terminal emulator found (foot/xterm) to run the Schwung installer in."
    [[ $target_script == http* ]] && rm -f "$script"
    return 1
  fi
  [[ $target_script == http* ]] && rm -f "$script"
  return 0
}

ensure_schwung_webapp() {
  # Mirrors ensure_webapp() for the schwung manager — same dedicated-profile
  # scheme, so open/close detection matches the profile exactly like the Move
  # Manager webapp's does.
  local desktop home_dir url exec_line
  desktop="$HOME/.local/share/applications/${SCHWUNG_MANAGER_ID}.desktop"
  home_dir="${XDG_CACHE_HOME:-$HOME/.cache}/${SCHWUNG_MANAGER_ID}"
  url="$(schwung_url)"
  if [[ -x $SCHWUNG_WEBAPP_LAUNCHER ]]; then
    exec_line="Exec=$SCHWUNG_WEBAPP_LAUNCHER"
  else
    exec_line="Exec=omarchy-launch-webapp \"$url\""
  fi
  if [[ -f $desktop ]]; then
    local current
    current=$(grep -oP 'Exec=.*?"\K[^"]+' "$desktop" 2>/dev/null || true)
    if [[ -n $current && $current != "$SCHWUNG_WEBAPP_LAUNCHER" ]]; then
      sed -i "s|^Exec=.*|$exec_line|" "$desktop"
    fi
    return 0
  fi
  mkdir -p "$HOME/.local/share/applications"
  cat > "$desktop" <<DESKTOP
[Desktop Entry]
Version=1.0
Name=$SCHWUNG_MANAGER_NAME
Comment=$SCHWUNG_MANAGER_NAME
$exec_line
Terminal=false
Type=Application
Icon=audio-x-generic
StartupNotify=true
Categories=AudioVideo;Audio;
DESKTOP
  chmod +x "$desktop"
}

open_schwung_manager() {
  ensure_schwung_webapp
  info "opening Schwung Manager → $(schwung_url)"
  if [[ -x $SCHWUNG_WEBAPP_LAUNCHER ]]; then
    "$SCHWUNG_WEBAPP_LAUNCHER" >/dev/null 2>&1 &
  elif command -v omarchy-launch-webapp >/dev/null 2>&1; then
    omarchy-launch-webapp "$(schwung_url)" >/dev/null 2>&1 &
  else
    xdg-open "$(schwung_url)" >/dev/null 2>&1 &
  fi
}

schwung_manager_running() {
  local profile="${XDG_CACHE_HOME:-$HOME/.cache}/${SCHWUNG_MANAGER_ID}"
  pgrep -f -- "--user-data-dir=$profile" >/dev/null 2>&1
}

close_schwung_manager_now() {
  local profile="${XDG_CACHE_HOME:-$HOME/.cache}/${SCHWUNG_MANAGER_ID}"
  pkill -f -- "--user-data-dir=$profile" >/dev/null 2>&1 || true
}

# ────────────────────────── Bitwig Move integration ──────────────────────────
MOVE_BITWIG_DIR="$HOME/.local/share/mosquito-move-manager/move-bitwig"
# Bitwig's REAL user Controller Scripts dir on Linux is ~/Bitwig Studio (the
# BitwigStudio.log watcher confirms it) — NOT ~/Documents/Bitwig Studio as on
# Windows/macOS. Prefer whichever exists, defaulting to the native Linux one.
BITWIG_CONTROLLERS_ROOT="$HOME/Bitwig Studio/Controller Scripts"
# Bitwig lists controllers as "<vendor> → <controller>", so the scripts must
# live under an Ableton/Move/ subfolder of the user Controller Scripts dir —
# copying them flat at the root made Bitwig show no vendor at all.
BITWIG_CONTROLLERS_DIR="$BITWIG_CONTROLLERS_ROOT/Ableton/Move"
BITWIG_CONTROLLERS_VENDOR_DIR="$BITWIG_CONTROLLERS_ROOT/Ableton"
MOVE_BITWIG_SSH_HOST="ableton@move.local"
MOVE_BITWIG_REMOTE_DIR="/data/UserData/schwung/modules/overtake/move-bitwig"

bitwig_move_controllers_dir() {
  printf '%s\n' "$BITWIG_CONTROLLERS_DIR"
}

bitwig_move_status_json() {
  # bitwig(installed) · controllers(deployed in the Bitwig user scripts dir)
  # · onDevice(module present on the Move, via ssh — only when schwung +
  # reachable Move, otherwise "unknown").
  local bitwig=false controllers=false ondevice="unknown" bitwig_bin=""
  bitwig_bin="$(command -v "${BITWIG_BIN:-bitwig-studio}" 2>/dev/null || true)"
  [[ -n $bitwig_bin ]] && bitwig=true
  if [[ -f "$(bitwig_move_controllers_dir)/Move.control.js" ]]; then
    controllers=true
  fi
  # Same 2xx/3xx acceptance as schwung_status_json: the manager answers 303,
  # not 200. If ssh then fails nothing is claimed — onDevice stays "unknown"
  # (never a false "not installed"), so the menu keeps offering both install
  # and uninstall.
  if detect_move && [[ $(schwung_http_code) =~ ^[23] ]]; then
    local out
    if out=$(timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=5 \
      "$MOVE_BITWIG_SSH_HOST" \
      "test -d $(printf '%q' "$MOVE_BITWIG_REMOTE_DIR") && echo yes" 2>/dev/null); then
      [[ $out == yes ]] && ondevice="yes" || ondevice="no"
    else
      ondevice="unknown"
    fi
  fi
  jq -nc --argjson bitwig "$bitwig" --argjson controllers "$controllers" \
    --arg ondevice "$ondevice" --arg bitwig_bin "$bitwig_bin" \
    '{bitwig:$bitwig, bitwig_bin:$bitwig_bin, controllers:$controllers, onDevice:$ondevice}'
}

bitwig_move_install() {
  # 1) controller scripts → the Bitwig user Controller Scripts/Ableton/Move/
  #    vendor subfolder (so Bitwig lists "Ableton → Move") ; 2) build + push
  #    the Move module via the vendored move-bitwig scripts (interactive ssh
  #    — visible terminal). Bitwig must be restarted (or Controllers
  #    rescanned) afterwards for the vendor to appear.
  local cdir mbdir
  cdir="$(bitwig_move_controllers_dir)"
  mbdir="$MOVE_BITWIG_DIR"
  if [[ ! -d $mbdir ]]; then
    err "move-bitwig sources not deployed ($mbdir) — re-run the setup script."
    return 1
  fi
  mkdir -p "$cdir"
  cp -f "$mbdir"/Controller\ Scripts/* "$cdir"/ 2>/dev/null || {
    err "could not copy controller scripts into $cdir"; return 1; }
  ok "controller scripts deployed to $cdir (restart Bitwig so the Ableton vendor appears)"
  local cmd
  cmd="cd $(printf '%q' "$mbdir") && bash scripts/build.sh && bash scripts/install.sh"
  if command -v foot >/dev/null 2>&1; then
    foot --app-id=org.omarchy.move-bitwig-install -e bash -c "$cmd"
  elif command -v xterm >/dev/null 2>&1; then
    xterm -e bash -c "$cmd"
  else
    err "no terminal emulator found (foot/xterm) to run move-bitwig install.sh in."
    return 1
  fi
  return 0
}

bitwig_move_uninstall() {
  # Remove only OUR vendor subfolder (Controller Scripts/Ableton/Move) and,
  # if it is left empty, the Ableton vendor folder. Nothing else in the
  # Controller Scripts tree is ever touched. The on-device module is a
  # separate uninstall (bitwig_move_uninstall_module).
  local cdir
  cdir="$(bitwig_move_controllers_dir)"
  if [[ -d $cdir ]]; then
    rm -rf "$cdir" 2>/dev/null || true
  fi
  # Drop the Ableton vendor folder only if it is now empty (rmdir refuses a
  # non-empty dir) — any other vendor/controller there is left untouched.
  rmdir "$BITWIG_CONTROLLERS_VENDOR_DIR" 2>/dev/null || true
  ok "controller scripts removed from $cdir"
}

bitwig_move_uninstall_module() {
  # Remove the on-device Move Bitwig module. Prefer the vendored uninstall
  # script when it exists; otherwise ssh the removal directly. Runs in a
  # visible terminal like the install so the user sees ssh's output/errors
  # (detection needs ssh to the Move; install and uninstall are offered
  # regardless so a broken ssh never makes the module look absent).
  local mbdir target
  mbdir="$MOVE_BITWIG_DIR"
  if [[ -x $mbdir/scripts/uninstall.sh ]]; then
    target="cd $(printf '%q' "$mbdir") && bash scripts/uninstall.sh"
  else
    target="ssh $(printf '%q' "$MOVE_BITWIG_SSH_HOST") 'rm -rf $(printf '%q' "$MOVE_BITWIG_REMOTE_DIR")'"
  fi
  info "removing the Move module from the device (needs ssh to the Move)…"
  if command -v foot >/dev/null 2>&1; then
    foot --app-id=org.omarchy.move-bitwig-uninstall -e bash -c "$target"
  elif command -v xterm >/dev/null 2>&1; then
    xterm -e bash -c "$target"
  else
    err "no terminal emulator found (foot/xterm) to run the module uninstall in."
    return 1
  fi
  return 0
}

open_bitwig_now() {
  # Launches Bitwig Studio without a project (the conversion flow opens it
  # with an .als via core's open_in_bitwig; the controller-install tip only
  # needs the app itself up).
  local bin
  bin="$(command -v "${BITWIG_BIN:-bitwig-studio}" 2>/dev/null || true)"
  if [[ -z $bin ]]; then
    err "Bitwig Studio not found."
    return 1
  fi
  info "launching Bitwig Studio"
  # Detached (own session/process group): the manager exiting must not take
  # Bitwig down with it.
  setsid "$bin" </dev/null >/dev/null 2>&1 3>&- &
  disown 2>/dev/null || true
  ok "Bitwig Studio opened ($!)"
}