#!/usr/bin/env bash
# setup-audio-stack.sh — omarchy local wine/yabridge audio stack: wine-staging +
# yabridge + local VST folders (~/Music/Audio Plugins) + per-editor yabridge
# precautions + the mosquito Audio Plugin Manager (menu entry).
# Bitwig and REAPER have their own installers: scripts/apps/{bitwig,reaper}/.
#
# Usage :
#   ./setup-audio-stack.sh             # interactive, each step asked
#   ./setup-audio-stack.sh -y          # everything with the default choices
#   ./setup-audio-stack.sh --tweaks    # only the VST precautions module (can be re-run freely)
#   ./setup-audio-stack.sh --dry-run   # simulation (no modification)
#
# VST subcommands (Windows plugins via wine, purely local) :
#   ./setup-audio-stack.sh --vst-sync        # yabridgectl sync
#   ./setup-audio-stack.sh --vst-status      # state of the local folders + plugins

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
set -euo pipefail

# Wine's Mono/Gecko installers open a bare white window in the corner of
# the screen when a prefix lacks .NET/HTML support (seen during every
# wine install in setup-ableton.sh and the audio plugin manager). The
# documented ok kill-switch: empty overrides for mscoree (Mono) and
# mshtml (Gecko) — wine never spawns those helper dialogues, and each
# script honors an user-exported override by keeping it.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YES=0 DRY=0 TWEAKS_ONLY=0
VST_MODE=0 VST_SYNC=0 VST_STATUS=0
while (( $# )); do a="$1"; case "$a" in
  -y|--yes) YES=1 ;;
  --dry-run) DRY=1 ;;
  --tweaks) TWEAKS_ONLY=1 ;;
  --vst-sync) VST_MODE=1; VST_SYNC=1 ;;
  --vst-status) VST_MODE=1; VST_STATUS=1 ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 1 ;;
esac; shift; done

G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
msg(){ printf "${B}==>${N} %s\n" "$*"; }
ok(){ printf " ${G}✓${N} %s\n" "$*"; }
warn(){ printf " ${Y}!${N} %s\n" "$*"; }
err(){ printf " ${R}✗${N} %s\n" "$*" >&2; }
hr(){ printf '%.0s─' {1..70}; echo; }

run(){
  if ((DRY)); then printf "     [dry-run] "; printf '%q ' "$@"; echo
  else "$@" >/dev/null 2>&1 || { err "Failed: $*"; return 1; }; fi
}

ask(){
  local q="$1" def="${2:-y}" r
  ((YES)) && { ok "(auto) $q -> yes"; return 0; }
  if ((DRY)); then msg "[dry-run] question ignored: $q"; return 0; fi
  if command -v gum >/dev/null; then
    gum confirm "$q" --default=$([[ $def == y ]] && echo true || echo false) && return 0 || return 1
  fi
  read -rp "$q [$([ $def = y ] && echo Y/n || echo y/N)] " r
  r="${r:-$def}"; [[ $r =~ ^[oOyY] ]]
}

pkg_has(){ pacman -Q "$1" &>/dev/null; }

# VST root resolution order (this machine's actual layout solved here):
#   1. AUDIOSTACK_VST_ROOT (explicit override)
#   2. ~/Music/Audio Plugins — the folder the wine prefixes'
#      "Common Files/VST3|CLAP" symlinks already point at (and Reaper's
#      default vstpath already includes) — Windows installers land there
#      through the prefix link, so every tool (plugin manager scan,
#      yabridgectl registration, native-DAW search paths) must converge
#      on this same root or the bridging chain silently breaks.
#   3. Legacy ~/VST (kept as a fallback only for old machines where
#      plugins really live there).
resolve_vst_root() {
  if [[ -n "${AUDIOSTACK_VST_ROOT:-}" ]]; then
    printf '%s\n' "$AUDIOSTACK_VST_ROOT"
    return
  fi
  if find "$HOME/Music/Audio Plugins" -mindepth 2 \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) 2>/dev/null | grep -q .; then
    printf '%s\n' "$HOME/Music/Audio Plugins"
  elif find "$HOME/VST" -mindepth 2 \( -iname '*.dll' -o -iname '*.vst3' -o -iname '*.clap' \) 2>/dev/null | grep -q .; then
    printf '%s\n' "$HOME/VST"
  elif [[ -d "$HOME/Music/Audio Plugins/vst3" ]]; then
    printf '%s\n' "$HOME/Music/Audio Plugins"
  else
    printf '%s\n' "$HOME/VST"
  fi
}
VST_ROOT="$(resolve_vst_root)"
VST_SRC_VST2="$VST_ROOT/vst"; VST_SRC_VST3="$VST_ROOT/vst3"; VST_SRC_CLAP="$VST_ROOT/clap"

detect_summary(){
  hr; msg "Detected state"
  local p
  for p in wine-staging yabridge yabridgectl realtime-privileges lib32-glibc lib32-libxcb winetricks; do
    pkg_has "$p" && ok "$p $(pacman -Q "$p" | awk '{print $2}')" || warn "$p missing"
  done
  groups | grep -qw realtime && ok "realtime group: member" || warn "realtime group: not a member"
  ok "Local VST folders: $VST_SRC_VST2 / $VST_SRC_VST3 / $VST_SRC_CLAP"
  hr
}

step_packages(){
  msg "Step 1/4 — System packages (wine-staging, yabridge, realtime)"
  if ! grep -A5 '^\[multilib\]' /etc/pacman.conf 2>/dev/null | grep -q '^Server'; then
    warn "[multilib] repo inactive in /etc/pacman.conf — required for lib32-* and yabridge."
    warn "Uncomment [multilib] + its Include line, then: sudo pacman -Syu"
    return 1
  fi
  local missing=() p
  for p in wine-staging yabridge yabridgectl realtime-privileges lib32-glibc lib32-libxcb winetricks; do
    pkg_has "$p" || missing+=("$p")
  done
  if ((${#missing[@]})); then
    if ask "Install the missing packages (${missing[*]}) ?" y; then
      mq_sudo -v || return 1
      run mq_sudo pacman -S --needed --noconfirm "${missing[@]}"
    fi
  else ok "All packages already present"; fi

  if ! getent group realtime | grep -qw "$USER"; then
    if ask "Add $USER to the realtime group (audio priority) ?" y; then
      run mq_sudo gpasswd -a "$USER" realtime
      warn "Logout/relogin required for the group to take effect."
    fi
  else ok "Realtime group already OK"; fi

  local host_out=""
  pkg_has yabridge && host_out="$(timeout 30 /usr/bin/yabridge-host.exe 2>&1 || true)"
  if [[ "$host_out" == *yabridge-host.exe* ]]; then
    ok "wine correctly runs yabridge-host"
  else
    warn "yabridge-host test inconclusive — check the wine-staging version."
  fi
}

step_vstdirs(){
  msg "Step 2/4 — VST folders + yabridgectl registration"
  mkdir -p "$VST_SRC_VST2" "$VST_SRC_VST3" "$VST_SRC_CLAP"
  ok "Source folders: $VST_SRC_VST2 $VST_SRC_VST3 $VST_SRC_CLAP"

  if pkg_has yabridgectl; then
    local d
    for d in "$VST_SRC_VST2" "$VST_SRC_VST3" "$VST_SRC_CLAP"; do
      yabridgectl list 2>/dev/null | grep -qx "$d" || run yabridgectl add "$d"
    done
    # Drop stale registrations: the legacy ~/VST/{VST2,VST3,CLAP} uppercase
    # folders (empty on this machine) must not stay registered — yabridgectl
    # sync would scan empty dirs and produce ZERO chainloaders, which is why
    # bridged Windows VSTs never showed up in native Linux DAWs even though
    # everything else looked wired correctly.
    local stale
    for stale in "$HOME/VST/VST2" "$HOME/VST/VST3" "$HOME/VST/CLAP" \
                 "$HOME/VST/vst" "$HOME/VST/vst3" "$HOME/VST/clap"; do
      if yabridgectl list 2>/dev/null | grep -qx "$stale"; then
        run yabridgectl rm "$stale" || true
        ok "yabridgectl: removed stale registration $stale"
      fi
    done
    ok "Directories registered in yabridgectl (prefix <auto> = ~/.wine, root: $VST_ROOT)"
    warn "'yabridgectl set --path' is broken in the Arch package (clap bug): useless, <auto> is enough."
  fi

  # Expose the three yabridge drop targets as environment variables so every
  # native Linux host that respects VST_PATH / VST3_PATH / CLAP_PATH (Reaper,
  # Ardour, Carla, every LSP-aware DAW) automatically picks them up without
  # having to be configured one app at a time. The most popular Linux DAWs
  # (Bitwig Studio, REAPER) don't actually honour these variables — Reaper
  # reads its own reaper.ini vstpath instead, and Bitwig reads its own
  # settings.xml. Both of those are handled by their own installers
  #   (scripts/apps/{reaper,bitwig}/), but the env vars cover every other
  # consumer that does pay attention to them.
  local ENV_DIR="$HOME/.config/environment.d"
  mkdir -p "$ENV_DIR"
  cat > "$ENV_DIR/mosquito-vst-paths.conf" <<EOF
# Generated by setup-audio-stack.sh — yabridge drop targets exposed as
# the standard native-Linux plugin-search env vars (VST_PATH, VST3_PATH,
# CLAP_PATH, LV2_PATH). Anything that respects them will find the
# chainloaders yabridgectl drops in ~/.vst, ~/.vst3, ~/.clap, plus the
# raw shared folders themselves (Ableton's wine prefix reads the raw
# ones through its Common Files symlinks; hosts honoring the env vars
# can also scan them natively).
VST_PATH=$HOME/.vst:$VST_SRC_VST2
VST3_PATH=$HOME/.vst3:$VST_SRC_VST3
CLAP_PATH=$HOME/.clap:$VST_SRC_CLAP
LV2_PATH=$HOME/.lv2:$VST_ROOT/lv2
EOF
  run systemctl --user import-environment VST_PATH VST3_PATH CLAP_PATH LV2_PATH 2>/dev/null || true
  ok "Native-Linux plugin env vars exposed via $ENV_DIR/mosquito-vst-paths.conf"

  local UNIT_DIR="$HOME/.config/systemd/user"
  if systemctl --user is-enabled yabridge-autosync.path &>/dev/null; then
    ok "Systemd autosync already active"
  else
    if ask "Enable the autosync (auto sync when a plugin appears) ?" y; then
      mkdir -p "$UNIT_DIR"
      cat > "$UNIT_DIR/yabridge-autosync.path" <<EOF
[Unit]
Description=Watch the VST folders for yabridgectl

[Path]
PathModified=$VST_SRC_VST2
PathModified=$VST_SRC_VST3
PathModified=$VST_SRC_CLAP

[Install]
WantedBy=default.target
EOF
      cat > "$UNIT_DIR/yabridge-autosync.service" <<'EOF'
[Unit]
Description=yabridgectl sync after adding plugins

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep 3 && exec yabridgectl sync'
EOF
      run systemctl --user daemon-reload
      run systemctl --user enable --now yabridge-autosync.path
      ok "Autosync enabled (yabridge-autosync.path)"
    fi
  fi

  # Linking the wine prefixes to ~/VST (yabridge + ableton-linux if present) :
  # a single plugin installation -> visible from all the DAWs.
  if [[ -x "$SCRIPT_DIR/link-vst-shared.sh" ]]; then
    bash "$SCRIPT_DIR/link-vst-shared.sh" || warn "Shared VST linking inconclusive."
  fi
}

# ─────────── Step 5: per-editor yabridge precautions ───────────
# Knowledge base: patterns (grep -iE on the file name) -> actions.
# To add an editor: add an entry in each array. Nothing is
# applied to plugins absent from the source folders.
kb_patterns=( 'serum' 'fabfilter' 'arturia' 'kick ?2|the drop|cytomic'
              '^m[a-z]' 'ujam|gorilla|loopcloud' 'kilohearts'
              'spitfire|bbcso|labs' 'izotope' 'd16' 'waves' 'sforzando'
              'tdr|tokyo dawn' 'voxengo' 'chromaphone|applied acoustics'
              'sonible|smart:' 'scaler' 'softube' 'plugin alliance|_pa_' )
kb_labels=(  'Xfer Serum 1.x' 'FabFilter' 'Arturia' 'Kick 2 / Cytomic The Drop'
             'MeldaProduction' 'ujam / Gorilla Engine / Loopcloud' 'KiloHearts'
             'Spitfire Audio' 'iZotope' 'D16 Group' 'Waves' 'sforzando'
             'Tokyo Dawn Records' 'Voxengo' 'Applied Acoustics (Chromaphone...)'
             'Sonible' 'Scaler' 'Softube' 'Plugin Alliance' )
kb_toml=(    '' 'group = "fabfilter"' '' ''
             '' 'disable_pipes = true' ''
             '' '' '' '' '' '' ''
             'hide_daw = true'
             '' '' '' '' )
kb_reg=(     'd2d1' '' 'hidewine' 'hidewine'
             '' '' ''
             '' '' '' '' '' '' ''
             '' '' '' '' '' )
kb_wt=(      'gdiplus' '' '' ''
             '' '' ''
             '' '' '' '' '' '' ''
             '' 'vcrun6sp6 w_workaround_wine_bug-50894'
             '' '' '' )
kb_notes=(
 'Disable the tooltips in Serum. gdiplus + d2d1 override applied if accepted.'
 '"fabfilter" group written to the toml: inter-plugin communication Pro-Q/Pro-C (VST2 only).'
 'HideWineExports fixes the tooltip freeze (if accepted). Possible crash when closing the GUI -> sandbox per editor in Bitwig.'
 'Same as Arturia: HideWineExports fixes the tooltip freeze.'
 'In each Melda plugin: disable the GPU rendering (Settings), otherwise black UI.'
 'The Gorilla Engine engine crashes without disable_pipes=true (written to the toml).'
 'Descriptor leak with esync: run the DAWs with WINEESYNC=0 or switch to fsync.'
 'If a sample loading error occurs: reinstall in a clean wine prefix.'
 'Activation impossible under wine (licenses). Activate elsewhere then copy the files, or use the native Linux version.'
 'Activation impossible under wine.'
 'The VST3 Waves V13+ are unstable under yabridge: stick to V12.'
 'Known graphical refresh problem.'
 'Knobs: set "Continuous Drag" to Linear in the TDR options.'
 'Knobs: enable the radial mode in the Voxengo options.'
 'Under Bitwig: hide_daw=true required (written to the toml), otherwise crash at load.'
 'JUCE8 plugins (smart:EQ 4, smart:reverb 2): possible black GUI (CreateSwapChainForComposition) -> winetricks proposed above. prime:vocal requires ARA2: not supported.'
 'Use the software rendering if the GUI remains black.'
 'Black GUI frequent on standard wine: try wine-cachyos.'
 'Install via "wine msiexec /i xxx.msi". Possible crash when closing the GUI -> sandbox Bitwig.'
)

kb_collect(){
  PLUGS_VST2=() PLUGS_VST3=() PLUGS_CLAP=()
  local f
  while IFS= read -r -d '' f; do PLUGS_VST2+=("$(basename "$f")"); done \
    < <(find "$VST_SRC_VST2" -maxdepth 1 -iname '*.dll' -print0 2>/dev/null)
  while IFS= read -r -d '' f; do PLUGS_VST3+=("$(basename "$f")"); done \
    < <(find "$VST_SRC_VST3" -iname '*.vst3' -print0 2>/dev/null)
  while IFS= read -r -d '' f; do PLUGS_CLAP+=("$(basename "$f")"); done \
    < <(find "$VST_SRC_CLAP" -iname '*.clap' -print0 2>/dev/null)
}

write_toml(){ # $1=target dir  $2..$n=section lines
  local dir="$1"; shift
  mkdir -p "$dir"
  local out="$dir/yabridge.toml"
  [[ -f $out && ! -f $out.bak ]] && cp "$out" "$out.bak"
  { echo "# Generated by setup-audio-stack.sh -- re-run './setup-audio-stack.sh --tweaks' to regenerate."
    ((DND_FIX)) && echo "editor_force_dnd = true"
    for l in "$@"; do echo "$l"; done
  } > "$out"
  ok "$(basename "$(dirname "$dir")")/yabridge.toml : $(grep -c '^\[\[' "$out" || true) section(s)"
}

wine_reg_applied(){ wine reg query "HKCU\\Software\\Wine\\$1" /v "$2" 2>/dev/null | grep -qi "$2"; }

apply_registry_fixes(){
  local seen="" i p name
  for i in "${!kb_patterns[@]}"; do
    [[ -z "${kb_reg[$i]}" ]] && continue
    p="${kb_patterns[$i]}"
    for name in "${PLUGS_VST2[@]}" "${PLUGS_VST3[@]}" "${PLUGS_CLAP[@]}"; do
      kb_match "$p" "$name" || continue
      case " $seen " in *" ${kb_reg[$i]} "*) ;; *) seen+=" ${kb_reg[$i]}" ;; esac
    done
  done
  local -a fixes_seen=()
  read -ra fixes_seen <<<"$seen"
  ((${#fixes_seen[@]})) || return 0
  command -v wine >/dev/null || { warn "wine missing: registry fixes not applied."; return 0; }
  local fx key val data
  for fx in "${fixes_seen[@]}"; do
    case "$fx" in
      d2d1)     key='DllOverrides'; val=d2d1;            data='' ;;
      hidewine) key='Staging';      val=HideWineExports; data=y ;;
    esac
    if wine_reg_applied "$key" "$val"; then ok "Registry already OK: $val"
    elif ask "Apply the registry fix '$val' (prefix ~/.wine) ?" y; then
      run wine reg add "HKCU\\Software\\Wine\\$key" /v "$val" /d "$data" /f \
        && ok "Registry: $val applied"
    fi
  done
}

kb_match(){ # $1=pattern  $2=filename -> 0 if match
  echo "$2" | grep -iqE "$1"
}

step_tweaks(){
  msg "Step 3/4 — Per-editor yabridge precautions"
  kb_collect
  local total=$(( ${#PLUGS_VST2[@]} + ${#PLUGS_VST3[@]} + ${#PLUGS_CLAP[@]} ))
  if ((total == 0)); then
    warn "No plugin detected in the source folders — install your VSTs first"
    warn "(local folder: install them via wine and place them in $VST_ROOT/{vst,vst3,clap} ; then re-run --tweaks)."
    return 0
  fi
  ok "Plugins detected: ${#PLUGS_VST2[@]} VST2, ${#PLUGS_VST3[@]} VST3, ${#PLUGS_CLAP[@]} CLAP"

  DND_FIX=0
  pkg_has reaper && ask "Enable editor_force_dnd (broken drag-and-drop GUI->project in REAPER) ?" n && DND_FIX=1

  local i j name lines stem sec
  local -a L2=() L3=() LC=()
  local -a matched_notes=() matched_wt=()
  for i in "${!kb_patterns[@]}"; do
    local hits=0
    for j in VST2 VST3 CLAP; do
      local -n ARR="PLUGS_$j"
      for name in "${ARR[@]}"; do
        kb_match "${kb_patterns[$i]}" "$name" || continue
        hits=1
        stem="${name%.*}"
        # TOML validity: an array-of-tables header holding a wildcard
        # must quote the KEY — `[["*Serum*"]]`, not `[[*Serum*]]`.
        # A bare '*' is not a bare-key character and any strict TOML
        # parser (Bitwig's own toml++ in its plugin-metadata reader!)
        # asserts/aborts while scanning the regenerated yabridge.toml —
        # that was the direct cause of the PluginHost SIGABRT crashes
        # with `toml::v3::impl parser::parse_key() Assertion failed`.
        # yabridge's own loader tolerated the unquoted form, which is
        # why the mistake hid for months behind "works in yabridge".
        sec='[["*'"${stem}"'*"]]'
        lines="${sec}"
        [[ -n "${kb_toml[$i]}" ]] && lines+=$'\n'"${kb_toml[$i]}"
        case "$j" in
          VST2) L2+=("$lines") ;; VST3) L3+=("$lines") ;; CLAP) LC+=("$lines") ;;
        esac
      done
    done
    if ((hits)); then
      matched_notes+=("${kb_labels[$i]} :: ${kb_notes[$i]}")
      if [[ -n "${kb_wt[$i]}" ]]; then
        case " ${matched_wt[*]:-} " in
          *" ${kb_wt[$i]} "*) ;;
          *) matched_wt+=("${kb_wt[$i]}") ;;
        esac
      fi
    fi
  done

  ((${#L2[@]} || ${#L3[@]} || ${#LC[@]})) && {
    write_toml "$HOME/.vst/yabridge"  "${L2[@]}"
    write_toml "$HOME/.vst3/yabridge" "${L3[@]}"
    write_toml "$HOME/.clap/yabridge" "${LC[@]}"
    if ((DRY)); then printf "     [dry-run] yabridgectl sync\n"
    elif pkg_has yabridgectl && yabridgectl sync >/dev/null 2>&1; then ok "sync executed"; fi
  } || warn "No known precaution applies to the detected plugins."

  apply_registry_fixes

  local wt
  for wt in "${matched_wt[@]:-}"; do
    [[ -z "$wt" ]] && continue
    command -v winetricks >/dev/null || { warn "winetricks missing: $wt not installed."; continue; }
    if ask "Install via winetricks: $wt ?" y; then
      mkdir -p "$HOME/.cache/audio-plugin-manager"
      msg "winetricks --unattended $wt (may take a few minutes)"
      if ((DRY)); then printf "     [dry-run] winetricks --unattended %s\n" "$wt"
      elif winetricks --unattended $wt >> "$HOME/.cache/audio-plugin-manager/winetricks.log" 2>&1; then ok "winetricks: $wt installed"
      else err "winetricks failed ($wt) — see $HOME/.cache/audio-plugin-manager/winetricks.log"; fi
    fi
  done

  if ((${#matched_notes[@]})); then
    hr; msg "Precautions applicable to YOUR plugins (to read):"
    local n
    for n in "${matched_notes[@]}"; do printf " • %s\n" "$n"; done
    hr
  fi
}

step_vst_menu(){
  msg "Step 4/4 — 'mosquito Audio Plugin Manager' (install / uninstall / status / standalone) in the menu"
  local s="$SCRIPT_DIR/setup-audio-plugin-manager.sh"
  [[ -f $s ]] || { warn "setup-audio-plugin-manager.sh missing from the folder: step skipped."; return 0; }
  # Only the CURRENT descriptor counts as "already present": a leftover
  # pre-rename entry (vst-manager.desktop / mosquito-vst-manager.desktop /
  # vst-install.desktop) means the install is out of date — fall through so
  # setup-audio-plugin-manager.sh runs and migrates/cleans the old artifacts.
  if [[ -f "$HOME/.local/share/applications/mosquito-audio-plugin-manager.desktop" ]]; then
    ok "mosquito Audio Plugin Manager already present"
    return 0
  fi
  ask "Add the 'mosquito Audio Plugin Manager' shortcut to the Omarchy menu ?" y \
    && bash "$s"
  # Migrate: drop the superseded single-purpose entry and every pre-rename
  # desktop if they survived (setup-audio-plugin-manager.sh's own migration
  # step handles the rest — binaries, icon, Hyprland block, file-picker pref).
  rm -f "$HOME/.local/share/applications/vst-install.desktop" "$HOME/.local/bin/vst-install"
  rm -f "$HOME/.local/share/applications/vst-manager.desktop" \
        "$HOME/.local/share/applications/mosquito-vst-manager.desktop"
}

recap(){
  hr; msg "Done — reminders"
  echo " • DAW plugin folders: Bitwig/REAPER scan their own config (see scripts/apps/{bitwig,reaper}/setup-*.sh)."
  echo " • New Windows plugin: install it via the Audio Plugin Manager (or wine in ~/.wine, dropping the files"
  echo "   into $VST_ROOT), then './setup-audio-stack.sh --tweaks' to apply its possible precautions."
  echo " • Realtime group: reconnection required if added earlier."
  hr
}

# ═══════════════════════════════════════════════════════════════════════
# Local VST module (Windows plugins via wine, without VM sharing)
#
# The Windows plugins installed via wine live in $VST_ROOT/{vst,vst3,clap}.
# We provide sync + status ; no junction / sharing with the VM.
# ═══════════════════════════════════════════════════════════════════════

vst_sync(){
  msg "yabridge sync"
  if command -v yabridgectl >/dev/null; then
    yabridgectl sync && ok "yabridgectl sync OK" || warn "sync inconclusive"
  else
    warn "yabridgectl missing"
  fi
  ok "Then re-run './setup-audio-stack.sh --tweaks' to apply the per-editor precautions."
}

vst_status(){
  msg "State of the local VST folders"
  echo " • Folders : $VST_SRC_VST2 / $VST_SRC_VST3 / $VST_SRC_CLAP"
  local c v2 v3
  v3=$(find "$VST_SRC_VST3" -type f -iname '*.vst3' 2>/dev/null | wc -l)
  v2=$(find "$VST_SRC_VST2" -type f -iname '*.dll' 2>/dev/null | wc -l)
  c=$(find "$VST_SRC_CLAP" -type f -iname '*.clap' 2>/dev/null | wc -l)
  echo " • Content : VST3=$v3  VST2=$v2  CLAP=$c"
  if command -v yabridgectl >/dev/null; then yabridgectl status; fi
}

main(){
  msg "setup-audio-stack — Omarchy local wine/yabridge audio stack (+ the Audio Plugin Manager)"
  if ((VST_MODE)); then
    ((VST_SYNC)) && vst_sync
    ((VST_STATUS)) && vst_status
    exit 0
  fi
  detect_summary
  if ((TWEAKS_ONLY)); then step_tweaks; else
    step_packages; hr
    step_vstdirs; hr
    step_tweaks;  hr
    step_vst_menu; hr
    recap
  fi
}

main "$@"
