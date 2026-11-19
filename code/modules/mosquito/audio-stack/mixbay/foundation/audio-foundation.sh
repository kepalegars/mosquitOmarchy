#!/usr/bin/env bash
# =============================================================================
# mixbay-audio-foundation — default PipeWire/udev/rate foundation for Mixbay
# =============================================================================
# One conservative pack applied to every interface Mixbay supports, starting
# with the EVO 8. It does NOT replace the mixer: it makes the audio graph
# predictable underneath it.
#
#   • udev: seat access to /dev/evo4 + /dev/evo8 (TAG+="uaccess", so no
#     dialout group / re-login), plus the EVO 8 capture helper.
#   • WirePlumber: no idle suspend + no upmix for Audient / RME / ESI /
#     PreSonus USB nodes. Passive loopbacks otherwise go idle and resync.
#   • EVO 8: split the raw 6-channel USB node into stereo nodes
#     (main, output 3+4, loopback out, mic 1+2, mic 3+4, loopback capture).
#     The split is a watchdog service: the nodes exist only while the card is
#     connected, so an unplugged EVO 8 never shows up as a selectable output.
#     EVO 4 is left to ALSA UCM >= 1.2.16, which already exposes the right
#     stereo output / split captures.
#   • Defaults: each card names its own default sink/source (EVO 8 main out +
#     mic 1+2, UCX II line 5 + Fireface, ...), through a small user service.
#   • Applied only after a card has been connected once: a downloaded profile
#     has no node to match before that.
#   • Rate: 48 kHz / 1024 frames with 44.1–192 kHz allowed, written only when
#     the mosquitOmarchy pipewire-settings module is not already managing the
#     clock (90-mosquitomarchy-pipewire.conf). Health checks always report the
#     graph rate, the device rate and a mismatch.
#
# Usage:
#   mixbay-audio-foundation --status [--json]
#   mixbay-audio-foundation --needs evo8
#   mixbay-audio-foundation --apply [--restart] [--force-evo4-split]
#   mixbay-audio-foundation --setup --device ID
#   mixbay-audio-foundation --split on|off --device evo8 [--restart]
#   mixbay-audio-foundation --remove [--restart]
# =============================================================================
set -euo pipefail

MIXBAY_ROOT="${MIXBAY_ROOT:-@MIXBAY_ROOT@}"
if [[ ! -d $MIXBAY_ROOT ]]; then
  MIXBAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
ELEVATE="$(cd "$MIXBAY_ROOT/../../../.." 2>/dev/null && pwd)/lib/elevate.bash"
if [[ -f $ELEVATE ]]; then
  # shellcheck source=/dev/null
  source "$ELEVATE"
else
  mq_sudo() { sudo "$@"; }
fi

HOME_DIR="${HOME}"
CONF="${XDG_CONFIG_HOME:-$HOME_DIR/.config}"
PW_DIR="$CONF/pipewire/pipewire.conf.d"
WP_DIR="$CONF/wireplumber/wireplumber.conf.d"
SYS_USER="$HOME_DIR/.config/systemd/user"
BIN_DIR="$HOME_DIR/.local/bin"
STATE="$CONF/mosquitomixbay/foundation.json"
CONNLOG="$CONF/mosquitomixbay/connected-interfaces.json"

# Local profile cards, the same store the Go binary uses. Every installed card
# (the embedded snapshots included: Mixbay seeds them on first read) lives
# here; a card counts as installed when its upstream/card.json exists.
profile_card_dir(){ printf '%s/mosquitomixbay/cards/%s' "$CONF" "$1"; }
profile_installed(){ [[ -f "$(profile_card_dir "$1")/upstream/card.json" ]]; }
# The LONGEST installed display contained in the card description: the RME
# names nest, so "Fireface UFX" must not win over "Fireface UFX III".
profile_id_for_name(){
  local n=$1 f
  for f in "$CONF"/mosquitomixbay/cards/*/upstream/card.json; do
    [[ -f $f ]] || continue
    jq -r --arg n "$n" '
      .spec | (.display // "") as $d
      | select($d != "" and ($n | ascii_downcase | contains($d | ascii_downcase)))
      | "\($d | length)\t\(.id)"' "$f" 2>/dev/null
  done | sort -rn | head -1 | cut -f2
}

# Profile-owned tooling (oscmix, evo-raw) is downloaded by the profile that
# needs it, outside this checkout. These helpers fetch it on demand.
DATA_DIR="${XDG_DATA_HOME:-$HOME_DIR/.local/share}"
integration_dir(){ printf '%s/mosquitomixbay/integrations/%s' "$DATA_DIR" "$1"; }
ensure_integration(){
  local name="$1" dir actions
  dir="$(integration_dir "$name")"
  if [[ ! -f "$dir/.manifest.json" ]]; then
    actions="$(command -v mosquito-mixbay-actions 2>/dev/null || true)"
    [[ -n $actions ]] || actions="$BIN_DIR/mosquito-mixbay-actions"
    [[ -x $actions ]] \
      || { warn "mosquito-mixbay-actions not found — cannot fetch $name"; return 1; }
    dir="$("$actions" profiles-integration "$name" 2>/dev/null)" \
      || { warn "could not fetch the $name integration"; return 1; }
  fi
  [[ -d $dir ]] || { warn "missing integration folder $dir"; return 1; }
  printf '%s\n' "$dir"
}

# card_setup <id>: the named integration a card needs. Native cards keep the
# mapping that predates the schema; a downloaded card declares it in
# spec.setup. Empty means the card needs no extra step.
card_setup(){
  local id="$1" f
  case $id in
    fireface-ucx2) echo oscmix; return ;;
    ssl12) echo douze; return ;;
  esac
  f="$(profile_card_dir "$id")/upstream/card.json"
  [[ -f $f ]] && jq -r '.spec.setup // ""' "$f" 2>/dev/null
}

# run_card_setup <name>: the closed set of integrations a card may name. A
# card is data, so it can only select one of these; it can never supply a
# command. The card's own setup never applies the audio foundation floor.
run_card_setup(){
  case "$1" in
    oscmix)
      local d; d="$(ensure_integration oscmix)" || return 1
      bash "$d/setup-oscmix.sh" -y ;;
    evo-raw)
      local d; d="$(ensure_integration evo-raw)" || return 1
      bash "$d/install-evo-raw.sh" ;;
    douze)
      local s="$MIXBAY_ROOT/../../../Apps/douze/setup-douze.sh"
      [[ -f $s ]] || { warn "douze module not found ($s)"; return 1; }
      bash "$s" -y --update --no-restart ;;
    move)
      # The Move profile is the compat helper (44.1 kHz offer, confirmation,
      # go-back) plus the card page the library already installed.
      local c="$MIXBAY_ROOT/compat/interface-onboarding.sh"
      [[ -f $c ]] || { warn "Move profile helper not found ($c)"; return 1; }
      bash "$c" --apply move ;;
    *)
      warn "unknown card setup: $1" ; return 1 ;;
  esac
}

# remove_card_setup <name>: the matching uninstaller for a card integration.
# Used when a profile is uninstalled so douze/oscmix do not outlive their card.
remove_card_setup(){
  case "$1" in
    oscmix)
      local s; s="$(integration_dir oscmix)/setup-oscmix.sh"
      [[ -f $s ]] || { info "oscmix integration is not downloaded — nothing to remove"; return 0; }
      bash "$s" --uninstall ;;
    evo-raw) : ;; # the kmod stays: unloading it mid-session would cut the card
    douze)
      local s="$MIXBAY_ROOT/../../../Apps/douze/setup-douze.sh"
      [[ -f $s ]] || { warn "douze module not found ($s)"; return 1; }
      bash "$s" --remove ;;
    *) : ;;
  esac
}

BASE_CONF="$PW_DIR/50-mixbay-audio.conf"
EVO_CONF="$PW_DIR/50-mixbay-evo.conf"
EVO4_CONF="$PW_DIR/50-mixbay-evo4.conf"
WP_CONF="$WP_DIR/50-mixbay-interfaces.conf"
UDEV_RULE="/etc/udev/rules.d/70-mixbay-evo.rules"
CAPTURE_RULE="/etc/udev/rules.d/99-evo8-capture.rules"
CAPTURE_HELPER="/usr/local/lib/mosquitomixbay/evo8-capture-enable.py"
# Omarchy's bar/audio panel (AudioNodes.platformHides) reads this file to leave
# Mixbay's internal split nodes out of every output/input list.
PLATFORM_AUDIO="/usr/share/omarchy-platform/audio.json"
# The panel file may pre-exist (written by the platform or an older Mixbay).
# Keep one copy before the foundation replaces it, so --remove can put it back.
PLATFORM_AUDIO_BAK="/usr/local/lib/mosquitomixbay/audio.json.orig"
DEFAULT_SCRIPT="$BIN_DIR/mixbay-audio-defaults"
DEFAULT_UNIT="$SYS_USER/mixbay-audio-defaults.service"
EVO_SPLIT_UNIT="$SYS_USER/mixbay-evo8-split.service"
PW_SETTINGS_CONF="$PW_DIR/90-mosquitomarchy-pipewire.conf"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf ' \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf ' \033[1;33m!\033[0m %s\n' "$*" >&2; }

# Keep the first version of a file the foundation is about to replace. The
# backup is created once, so a later idempotent apply cannot overwrite it with
# the foundation's own previous output.
backup_file(){
  local f="$1"
  [[ -f $f && ! -f "$f.bak.mixbay-foundation" ]] \
    && cp -a "$f" "$f.bak.mixbay-foundation" 2>/dev/null || true
}

# Same idea for the root-owned platform panel file: the copy lives in Mixbay's
# own directory, so nothing new appears next to the platform's file.
backup_platform_audio(){
  [[ -f $PLATFORM_AUDIO ]] || return 0
  mq_sudo test -f "$PLATFORM_AUDIO_BAK" && return 0
  mq_sudo install -D -m 0644 "$PLATFORM_AUDIO" "$PLATFORM_AUDIO_BAK" 2>/dev/null \
    || warn "could not back up $PLATFORM_AUDIO"
}

# ── per-card state / default card ──────────────────────────────────────────
# foundation.json is the single source of truth for "which cards did the user
# set up" and "which one is the default/priority card". Setting a card up does
# NOT make it the default: only an explicit --set-default (Settings or a
# "Use it" action) may take the lead away from the current default.
state_init(){
  mkdir -p "$(dirname "$STATE")"
  if [[ ! -f $STATE ]]; then
    printf '{"default":"","devices":{}}\n' > "$STATE"
    return 0
  fi
  # Migrate the old one-field {"applied":...} file from the first foundation
  # version: it has no .devices, and every jq query below would fail. Keep the
  # unreadable file instead of deleting the user's state outright.
  if ! jq -e 'type == "object" and has("devices") and (.devices | type == "object")' "$STATE" >/dev/null 2>&1; then
    mv "$STATE" "$STATE.corrupt" 2>/dev/null || rm -f "$STATE"
    printf '{"default":"","devices":{}}\n' > "$STATE"
  fi
}
state_installed(){
  state_init
  jq -e --arg id "$1" '.devices[$id].installed == true' "$STATE" >/dev/null 2>&1
}
# Replace a JSON state file in one step: jq writes a sibling temp file, then
# the rename swaps it in. A crash never leaves a half-written state file.
state_write(){
  local tmp; tmp="$(mktemp "$STATE.XXXXXX")" || return 1
  if jq "$@" "$STATE" > "$tmp"; then
    mv "$tmp" "$STATE"
  else
    rm -f "$tmp"
    return 1
  fi
}
state_set_installed(){
  state_init
  local id="$1" on="$2"
  state_write --arg id "$id" --argjson on "$on" \
    '.devices[$id] = ((.devices[$id] // {}) + {installed: $on, at: (now|todate)})'
}
state_default(){ state_init; jq -r '.default // ""' "$STATE"; }
state_set_default(){
  state_init
  state_write --arg id "$1" '.default = $id'
}
# split is "on"/"off"/"" (never chosen). "off" is a user choice, not a gap the
# onboarding prompt may keep asking about.
state_split(){
  state_init
  jq -r --arg id "$1" '.devices[$id].split // ""' "$STATE" 2>/dev/null || true
}
state_set_split(){
  state_init
  state_write --arg id "$1" --arg v "$2" \
    '.devices[$id] = ((.devices[$id] // {}) + {split: $v})'
}

FORCE_EVO4=0 RESTART=0 MODE=status JSON=0 DEV="" SPLIT=""
while (($#)); do
  case "$1" in
    --status) MODE=status; shift ;;
    --needs) MODE=needs; shift ;;
    --apply) MODE=apply; shift ;;
    --setup) MODE=setup; shift ;;
    --remove) MODE=remove; shift ;;
    --split) MODE=split; SPLIT="${2:-}"; shift 2; ;;
    --track) MODE=track; shift ;;
    --reset-history) MODE=reset-history; shift ;;
    --evo-split-run) MODE=evo-split-run; shift ;;
    --json) JSON=1; shift ;;
    --restart) RESTART=1; shift ;;
    --force-evo4-split) FORCE_EVO4=1; shift ;;
    --device) DEV="${2:-}"; shift 2 ;;
    --set-default) MODE=set-default; DEV="${2:-}"; shift 2 ;;
    evo4|evo8|ssl12|fireface-ucx2|ugm192) DEV="$1"; shift ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) warn "Unknown option: $1"; exit 2 ;;
  esac
done

# ── connected-interface history ────────────────────────────────────────────
# The log is independent of the native registry: any USB audio card that was
# ever seen is kept here, so the default picker can target a card even after it
# is unplugged. Cards never connected never appear.
slug(){
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')"
  printf '%s\n' "${s:-card}"
}
native_id_for_name(){
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case $s in
    *evo8*|*"evo 8"*) echo evo8 ;;
    *evo4*|*"evo 4"*) echo evo4 ;;
    *"ssl 12"*|*ssl12*|*"solid state logic"*) echo ssl12 ;;
    # Only the UCX II ships embedded. The other RME cards are repo profiles,
    # so profile_id_for_name (or the TUI's name match) resolves them.
    *"fireface ucx ii"*) echo fireface-ucx2 ;;
    *ugm192*|*"ugm 192"*) echo ugm192 ;;
  esac
}
version_for_id(){
  # Prefer the installed profile's own version: the RME cards move together,
  # and a hardcoded copy here is what made the foundation list lag behind.
  local v
  v="$(jq -r '.spec.version // empty' "$(profile_card_dir "$1")/upstream/card.json" 2>/dev/null || true)"
  [[ -n $v ]] && { printf '%s\n' "$v"; return; }
  case "$1" in
    evo8|evo4) echo v1.0.0 ;;
    ssl12) echo v0.1.0 ;;
    fireface-ucx2) echo v1.0.0 ;;
    ugm192) echo v1.0.0 ;;
    *) echo beta ;;
  esac
}
display_name_for_id(){
  case "$1" in
    evo8) echo "Audient EVO 8" ;;
    evo4) echo "Audient EVO 4" ;;
    ssl12) echo "Solid State Logic SSL 12" ;;
    fireface-ucx2) echo "RME Fireface UCX II" ;;
    ugm192) echo "ESI UGM192" ;;
    *) echo "" ;;
  esac
}
connlog_write(){
  local tmp; tmp="$(mktemp "$CONNLOG.XXXXXX")" || return 1
  if jq "$@" "$CONNLOG" > "$tmp"; then
    mv "$tmp" "$CONNLOG"
  else
    rm -f "$tmp"
    return 1
  fi
}
seed_log_once(){
  [[ -f $CONNLOG ]] && return 0
  mkdir -p "$(dirname "$CONNLOG")"
  printf '[]\n' > "$CONNLOG"
  local id name match version
  while IFS= read -r id; do
    case $id in
      evo8) name="Audient EVO 8"; match="EVO8" ;;
      evo4) name="Audient EVO 4"; match="EVO4" ;;
      ssl12) name="Solid State Logic SSL 12"; match="SSL 12" ;;
      fireface-ucx2) name="RME Fireface UCX II"; match="Fireface" ;;
      ugm192) name="ESI UGM192"; match="UGM192" ;;
      *) continue ;;
    esac
    version="$(version_for_id "$id")"
    connlog_write --arg id "$id" --arg name "$name" --arg match "$match" --arg version "$version" \
      '. + [{id:$id,name:$name,match:$match,version:$version,native:true,last_seen:(now|todate)}]'
  done < <(jq -r '.devices | to_entries[] | select(.value.installed == true) | .key' "$STATE" 2>/dev/null || true)
}

track_connections(){
  command -v pactl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  seed_log_once
  mkdir -p "$(dirname "$CONNLOG")"
  [[ -f $CONNLOG ]] || printf '[]\n' > "$CONNLOG"
  local name desc match id native version existing
  while IFS=$'\t' read -r name desc match; do
    [[ -n $name || -n $desc ]] || continue
    [[ -n $desc ]] || desc=$name
    [[ -n $match ]] || match=$desc
    id="$(native_id_for_name "$name $desc $match")"
    if [[ -n $id ]]; then
      native=true
      version="$(version_for_id "$id")"
      name="$(display_name_for_id "$id")"
      [[ -n $name ]] || name=$desc
    else
      native=false
      version=beta
      existing="$(profile_id_for_name "$desc" || true)"
      id="${existing:-beta-$(slug "$desc")}"
    fi
    connlog_write --arg id "$id" --arg name "$name" --arg match "$match" \
      --arg version "$version" --argjson native "$native" \
      'map(select(.id != $id)) + [{id:$id,name:$name,match:$match,version:$version,native:$native,last_seen:(now|todate)}]'
  done < <(pactl -f json list cards 2>/dev/null | jq -r '
    .[] | select(.name|startswith("alsa_card.usb-"))
    | [.properties["alsa.card_name"] // "",
       .properties["device.description"] // .properties["alsa.card_name"] // .name,
       .properties["alsa.card_name"] // .properties["device.description"] // .name]
    | @tsv' 2>/dev/null)
}
log_has_id(){
  [[ -f $CONNLOG ]] && jq -e --arg id "$1" '.[]|select(.id==$id)' "$CONNLOG" >/dev/null 2>&1
}

# ── discovery ───────────────────────────────────────────────────────────────
pw_dump(){ pw-metadata -n settings 0 2>/dev/null || true; }
pw_get(){ sed -n "s/.*key:'$1' value:'\([^']*\)'.*/\1/p" <<< "$PW" | head -1; }

# discover_node <dev> <output|input> -> "node channels", widest matching node.
# The node name carries the model (EVO8/EVO4) and may be pro-output-0 or
# analog-surround-51 depending on kernel/UCM; never hardcode one machine.
evo_present(){
  local dev="$1" f pid want
  want="0007"; [[ $dev == evo4 ]] && want="0006"
  for f in /sys/bus/usb/devices/*/idVendor; do
    [[ -r $f ]] || continue
    [[ "$(cat "$f" 2>/dev/null)" == "2708" ]] || continue
    [[ "$(cat "${f%idVendor}idProduct" 2>/dev/null)" == "$want" ]] && return 0
  done
  return 1
}

discover_node(){
  local dev="$1" dir="$2" prefix model list node ch
  if [[ $dir == output ]]; then
    prefix="alsa_output.usb-Audient_"; model="EVO${dev#evo}"
    list="$(pw-link -i 2>/dev/null || true)"
  else
    prefix="alsa_input.usb-Audient_"; model="EVO${dev#evo}"
    list="$(pw-link -o 2>/dev/null || true)"
  fi
  node="$(sed 's/:.*//' <<< "$list" | grep -F "$prefix" | grep -F "$model" \
    | sort | uniq -c | sort -rn | head -1 | awk '{print $2}' || true)"
  if [[ -z $node ]]; then
    printf '%s %s\n' '' 0
    return
  fi
  ch="$(sed 's/:.*//' <<< "$list" | grep -Fxc "$node" || true)"
  printf '%s %s\n' "$node" "${ch:-0}"
}

# set_pro_audio <dev>: the EVO exposes its six USB channels only on PipeWire's
# "pro-audio" profile. PipeWire never picks it alone (priority 1), so without
# this the split is skipped on every fresh connection and onboarding keeps
# asking for a 6-channel node. Switch, then wait for the wide node to appear.
set_pro_audio(){
  local dev="$1" model card cur i node ch
  model="EVO${dev#evo}"
  card="$(pactl list cards short 2>/dev/null | awk -v m="$model" 'tolower($2) ~ tolower(m) {print $2; exit}')"
  [[ -n $card ]] || return 1
  cur="$(pactl list cards 2>/dev/null | awk -v c="$card" '
    $1 == "Name:" && $2 == c { found = 1 }
    found && $1 == "Active" && $2 == "Profile:" { print $3; exit }')"
  [[ $cur == pro-audio ]] && return 0
  pactl set-card-profile "$card" pro-audio 2>/dev/null || return 1
  for i in $(seq 1 20); do
    read -r node ch < <(discover_node "$dev" output)
    [[ -n $node && $ch -ge 6 ]] && return 0
    sleep 0.25
  done
  return 1
}

card_rate(){
  # Real ALSA stream rate, when a stream is open. "closed" -> empty.
  local model="$1" num f rate
  num="$(awk -v m="$model" 'tolower($0) ~ tolower(m) {print $1; exit}' /proc/asound/cards 2>/dev/null || true)"
  [[ -n $num ]] || return 0
  for f in "/proc/asound/card${num}"/pcm*p/sub*/hw_params; do
    [[ -r $f ]] || continue
    rate="$(sed -n 's/^rate: *\([0-9][0-9]*\).*/\1/p' "$f" | head -1)"
    [[ -n $rate ]] && { printf '%s\n' "$rate"; return; }
  done
}

# ── status ──────────────────────────────────────────────────────────────────
douze_online(){
  command -v curl >/dev/null 2>&1 || return 1
  curl -s --max-time 1 http://127.0.0.1:1212/state 2>/dev/null \
    | jq -e '._device == true' >/dev/null 2>&1
}

alsa_card_present(){
  awk -v m="$1" 'tolower($0) ~ tolower(m) {found=1} END{exit !found}' \
    /proc/asound/cards 2>/dev/null
}

native_online(){
  case "$1" in
    evo8|evo4) evo_present "$1" ;;
    ssl12) douze_online ;;
    fireface-ucx2) alsa_card_present 'Fireface|UCX II|UCXII' ;;
    ugm192) alsa_card_present 'UGM192|UGM 192' ;;
  esac
}

native_rate(){
  case "$1" in
    evo8) card_rate 'EVO ?8' ;;
    evo4) card_rate 'EVO ?4' ;;
    ssl12) curl -s --max-time 1 http://127.0.0.1:1212/state 2>/dev/null \
             | jq -r '._clock[0] // empty' 2>/dev/null ;;
    fireface-ucx2) card_rate 'Fireface|UCX II|UCXII' ;;
    ugm192) card_rate 'UGM192|UGM 192' ;;
  esac
}

# oscmix is the RME cards' control surface: per-user engine + GTK mixer, built
# from the huddx01 fork. The Qt UI is an optional AppImage. Nothing runs as a
# service and the foundation itself writes nothing to the interface.
oscmix_installed(){
  [[ -x $BIN_DIR/oscmix && -x $BIN_DIR/alsaseqio && -x $BIN_DIR/oscmix-gtk \
     && -f "$HOME_DIR/.local/lib/oscmix/gtk/gschemas.compiled" ]]
}

native_installed(){
  state_installed "$1" && return 0
  case "$1" in
    evo8) [[ -f $EVO_SPLIT_UNIT ]] ;;
    ssl12) systemctl --user is-active --quiet douze 2>/dev/null ;;
    fireface-ucx2) oscmix_installed ;;
    *) return 1 ;;
  esac
}

# split_supported <id>: interfaces whose split file Mixbay owns and can toggle.
split_supported(){
  case "$1" in evo8|evo4) return 0 ;; *) return 1 ;; esac
}

# split_state <id> -> on|off|"". The split nodes exist while the card is
# connected: the toggle only decides how many of them the Omarchy audio panel
# lists (one stereo entry when off, every pair when on). Empty means "no split
# concept" (ALSA level 1).
split_state(){
  split_supported "$1" || { echo ""; return; }
  [[ "$(state_split "$1")" == on ]] && echo on || echo off
}

status_json(){
  local rate quantum allowed id name version native installed online drate match beta
  local mismatch=0 wp=0 udev=0 defaults=0 base=0 split=0
  PW="$(pw_dump)"
  rate="$(pw_get clock.rate)"
  quantum="$(pw_get clock.quantum)"
  allowed="$(pw_get clock.allowed-rates)"
  [[ -f $EVO_SPLIT_UNIT ]] && split=1
  [[ -f $WP_CONF ]] && wp=1
  [[ -f $UDEV_RULE ]] && udev=1
  [[ -f $DEFAULT_UNIT ]] && defaults=1
  [[ -f $BASE_CONF ]] && base=1
  track_connections
  local cards='[]' conns='[]'
  while IFS=$'\t' read -r id name version native match; do
    [[ -n $id ]] || continue
    # Native ids track the installed profile too; the log can predate a bump.
    if [[ $native == true ]]; then version="$(version_for_id "$id")"; fi
    beta=false; [[ $native == false ]] && beta=true
    installed=false; native_installed "$id" && installed=true
    if [[ $beta == true ]]; then
      profile_installed "$id" && installed=true
    fi
    online=false
    if [[ $native == true ]]; then native_online "$id" && online=true; else
      alsa_card_present "$match" && online=true
    fi
    drate=""
    if [[ $native == true ]]; then
      drate="$(native_rate "$id" || true)"
    else
      drate="$(card_rate "$match" || true)"
    fi
    [[ -n $rate && -n $drate && $rate != "$drate" ]] && mismatch=1
    local row sstate
    sstate="$(split_state "$id")"
    row="$(jq -c -n --arg id "$id" --arg name "$name" --arg version "$version" \
      --argjson installed "$installed" --argjson online "$online" \
      --argjson beta "$beta" --arg rate "${drate:-}" --arg split "$sstate" \
      '{id:$id,name:$name,version:$version,installed:$installed,online:$online,beta:$beta,rate:(if $rate=="" then null else ($rate|tonumber) end),split:$split}')"
    conns="$(jq -c --argjson d "$conns" --argjson r "$row" '. + [$r]' <<< "$conns")"
    # CARDS only carries native or explicitly added beta interfaces; the
    # DEFAULT picker uses the full connection log below.
    if [[ $beta == false ]] || profile_installed "$id"; then
      cards="$(jq -c --argjson d "$cards" --argjson r "$row" '. + [$r]' <<< "$cards")"
    fi
  done < <(jq -r '.[] | [.id,.name,.version,(.native|tostring),.match] | @tsv' "$CONNLOG" 2>/dev/null || true)
  local default; default="$(state_default)"
  jq -n \
    --argjson rate "${rate:-null}" --argjson quantum "${quantum:-null}" \
    --arg allowed "$allowed" --argjson devices "$cards" --argjson connections "$conns" \
    --argjson mismatch "$mismatch" --argjson split "$split" \
    --argjson wp "$wp" --argjson udev "$udev" --argjson defaults "$defaults" \
    --argjson base "$base" --argjson pwsettings "$([[ -f $PW_SETTINGS_CONF ]] && echo 1 || echo 0)" \
    --arg default "$default" \
    '{ok:($wp==1 and $udev==1),default:$default,
      foundation:{base_clock:($base==1), evo_split:($split==1), wireplumber:($wp==1), udev:($udev==1), defaults:($defaults==1), pipewire_settings_manages_clock:($pwsettings==1)},
      graph:{rate:$rate,quantum:$quantum,allowed_rates:$allowed},devices:$devices,connections:$connections,mismatch:($mismatch==1)}'
}

status_human(){
  local dev name version installed online drate
  PW="$(pw_dump)"
  local rate quantum allowed
  rate="$(pw_get clock.rate)"; quantum="$(pw_get clock.quantum)"; allowed="$(pw_get clock.allowed-rates)"
  info "Mixbay audio foundation"
  printf '  graph      : %s Hz · quantum %s · allowed %s\n' "${rate:-?}" "${quantum:-?}" "${allowed:-?}"
  if [[ -f $PW_SETTINGS_CONF ]]; then
    echo "  clock      : managed by pipewire-settings (90-mosquitomarchy-pipewire.conf)"
  elif [[ -f $BASE_CONF ]]; then
    echo "  clock      : written by the foundation (50-mixbay-audio.conf)"
  else
    echo "  clock      : not managed by Mixbay (PipeWire defaults)"
  fi
  local default; default="$(state_default)"
  printf '  default    : %s\n' "${default:-none}"
  track_connections
  local native match
  while IFS=$'\t' read -r dev name version native match; do
    [[ -n $dev ]] || continue
    if [[ $native == true ]]; then version="$(version_for_id "$dev")"; fi
    installed="no"; native_installed "$dev" && installed="yes"
    if [[ $native == false ]] && profile_installed "$dev"; then
      installed="yes"
    fi
    online="offline"
    if [[ $native == true ]]; then native_online "$dev" && online="online"; else
      alsa_card_present "$match" && online="online"
    fi
    if [[ $native == true ]]; then
      drate="$(native_rate "$dev" || true)"
    else
      drate="$(card_rate "$match" || true)"
    fi
    printf '  %-28s %-7s %-8s %s\n' "$name - $version" "$installed" "$online" "${drate:+${drate} Hz}"
    if [[ -n $rate && -n $drate && $rate != "$drate" ]]; then
      printf '                 \033[1;33m⚠ mismatch: graph %s Hz vs device %s Hz\033[0m\n' "$rate" "$drate"
    fi
  done < <(jq -r '.[] | [.id,.name,.version,(.native|tostring),.match] | @tsv' "$CONNLOG" 2>/dev/null || true)
  local miss=() f
  for f in "$WP_CONF"; do [[ -e $f ]] || miss+=("$f"); done
  if ((${#miss[@]})); then
    printf '  missing    :\n'
    printf '    - %s\n' "${miss[@]}"
  else
    printf '  state      : shared floor complete\n'
  fi
}

# ── apply ───────────────────────────────────────────────────────────────────
write_base_clock(){
  [[ -f $PW_SETTINGS_CONF ]] && { ok "clock left to pipewire-settings"; return 0; }
  # Never fight a user config that already pins the graph clock.
  if grep -rl 'default.clock.rate' "$PW_DIR"/*.conf 2>/dev/null \
     | grep -vFx "$BASE_CONF" | grep -q .; then
    ok "another PipeWire config already sets default.clock.rate — left alone"
    return 0
  fi
  mkdir -p "$PW_DIR"
  backup_file "$BASE_CONF"
  cat > "$BASE_CONF" <<'EOF'
# Mixbay audio foundation — conservative graph defaults.
# 48 kHz is the default; the allowed list lets a 44.1/96/192 kHz stream switch
# when every node agrees. A user who pins values in pipewire-settings wins:
# this file is not written when 90-mosquitomarchy-pipewire.conf exists.
context.properties = {
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 44100 48000 88200 96000 176400 192000 ]
    default.clock.quantum = 1024
    default.clock.min-quantum = 64
    default.clock.max-quantum = 2048
}
EOF
  ok "graph defaults written ($BASE_CONF)"
}

write_wp_rules(){
  mkdir -p "$WP_DIR"
  backup_file "$WP_CONF"
  cat > "$WP_CONF" <<'EOF'
# Mixbay audio foundation — keep supported USB interfaces alive and stereo.
#
# Why: passive loopbacks (EVO 8 split, SSL 12 split) stop being "active" as
# soon as nothing plays. WirePlumber then suspends the ALSA output after 5 s;
# on the next sound the playback stream restarts out of phase with the capture
# stream and PipeWire "resyncs" forever (crackles, chopped voice). The same
# class of bug hits any multichannel interface whose extra channels are only
# used occasionally.
#
# channelmix.upmix=false keeps a stereo app on FL/FR instead of spraying it
# across the raw 6-channel sink; the extra channels stay available for routing.
# api.alsa.soft-mixer is deliberately NOT set: Mixbay owns the hardware volume.
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_(output|input)\\.usb-Audient.*" }
      { node.name = "~alsa_(output|input)\\.usb-RME.*" }
      { node.name = "~alsa_(output|input)\\.usb-ESI.*" }
      { node.name = "~alsa_(output|input)\\.usb-PreSonus.*" }
      { node.name = "~alsa_(output|input)\\.usb-Solid_State_Logic.*" }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
        node.pause-on-idle = false
        channelmix.upmix = false
      }
    }
  }
]
EOF
  ok "WirePlumber rules written ($WP_CONF)"
}

# Hide Mixbay's internal nodes from the Omarchy bar and audio panel. The split
# exists while the card is connected; the per-interface toggle only decides how
# many entries the panel lists:
#   off (default) -> evo8_main_output / evo8_mic_1_2 only, one EVO 8 per side;
#   on            -> every stereo pair (main, 3+4, loopback, mics).
# Internal .out/.in streams and monitors stay hidden either way, and the raw
# Pro Audio node is hidden while the split pair exists.
install_platform_hints(){
  local tmp; tmp="$(mktemp)"
  jq -n --arg s8 "$(split_state evo8)" --arg s4 "$(split_state evo4)" '
    ([ "evo8_(main_output|mic_1_2)\\.(out|in|monitor)",
       "evo4_(main_output|mic_1_2)\\.(out|in|monitor)",
       "evo8_(output_3_4|loopback_output|mic_3_4|loopback_capture)\\.(out|in|monitor)",
       "evo4_(output_3_4|loopback_output|mic_3_4|loopback_capture)\\.(out|in|monitor)" ]
     + (if $s8 == "on" then [] else
          ["evo8_(output_3_4|loopback_output|mic_3_4|loopback_capture)"] end)
     + (if $s4 == "on" then [] else
          ["evo4_(output_3_4|loopback_output|mic_3_4|loopback_capture)"] end)
    ) as $hidden |
    {hidden: $hidden,
     replaced: [
       { node: "alsa_(output|input)\\.usb-Audient_EVO8-.*\\.pro-.*", by: "evo8_(main_output|mic_1_2)" },
       { node: "alsa_(output|input)\\.usb-Audient_EVO4-.*\\.pro-.*", by: "evo4_(main_output|mic_1_2)" }
     ]}
  ' > "$tmp"
  backup_platform_audio
  mq_sudo install -D -m 0644 "$tmp" "$PLATFORM_AUDIO" \
    && ok "audio panel hints installed ($(split_state evo8) split)" \
    || warn "could not install $PLATFORM_AUDIO"
  rm -f "$tmp"
}

# init_defaults <dev>: first setup only. Apply the interface's built-in default
# preset and make the system endpoints usable; a later apply never overwrites
# the levels the user set. Cards without a preset (ALSA level 1) only get the
# default sink/source and are left unmuted.
init_defaults(){
  local dev="$1" actions="$BIN_DIR/mosquito-mixbay-actions"
  command -v "$actions" >/dev/null 2>&1 || actions="$(command -v mosquito-mixbay-actions 2>/dev/null || true)"
  [[ -n $actions ]] && "$actions" reset-defaults --device "$dev" >/dev/null 2>&1 || true
  [[ "$(state_default)" == "$dev" ]] || return 0
  [[ -x $DEFAULT_SCRIPT ]] && "$DEFAULT_SCRIPT" >/dev/null 2>&1 || true
  wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null || true
  wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0 2>/dev/null || true
}

install_udev(){
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# Mixbay — seat access to the evo_raw control nodes without the dialout group.
# The kmod's own rule grants GROUP="dialout"; this adds the logged-in seat user
# via uaccess, so no re-login is needed. 70-* is before 73-seat-late.rules.
KERNEL=="evo4", SUBSYSTEM=="misc", TAG+="uaccess"
KERNEL=="evo8", SUBSYSTEM=="misc", TAG+="uaccess"
EOF
  mq_sudo install -D -m 0644 "$tmp" "$UDEV_RULE" \
    && mq_sudo udevadm control --reload-rules \
    && mq_sudo udevadm trigger --action=change --subsystem-match=misc 2>/dev/null \
    && ok "udev seat rule installed ($UDEV_RULE)" \
    || warn "could not install $UDEV_RULE (needs root)"
  rm -f "$tmp"

  # EVO 8 capture helper: EU51 may stay disabled after power-on, leaving the
  # six capture channels silent even when gains/mutes/48V are correct. The
  # files belong to the evo-raw integration, so it is fetched on demand.
  local kmod
  kmod="$(ensure_integration evo-raw 2>/dev/null || true)"
  if [[ -n $kmod && -f "$kmod/evo8-capture-enable.py" && -f "$kmod/99-evo8-capture.rules" ]]; then
    mq_sudo install -D -m 0755 "$kmod/evo8-capture-enable.py" "$CAPTURE_HELPER" \
      && mq_sudo install -D -m 0644 "$kmod/99-evo8-capture.rules" "$CAPTURE_RULE" \
      && mq_sudo udevadm control --reload-rules \
      && ok "EVO 8 capture helper installed" \
      || warn "could not install the EVO 8 capture helper"
  fi
}

# install_evo_split: the old static 50-mixbay-evo.conf created the six
# loopback nodes at every PipeWire start, even with the card unplugged — the
# phantom "EVO 8" sink Omarchy then offered as an output. The split is now a
# watchdog service: it creates the same nodes with pw-loopback only while the
# EVO 8 is present and tears them down when it disappears.
install_evo_split(){
  local legacy=0 runner
  if [[ -f $EVO_CONF ]]; then rm -f "$EVO_CONF"; legacy=1; fi
  mkdir -p "$SYS_USER"
  runner="$BIN_DIR/mixbay-audio-foundation"
  [[ -x $runner ]] || runner="$(readlink -f "${BASH_SOURCE[0]}")"
  backup_file "$EVO_SPLIT_UNIT"
  cat > "$EVO_SPLIT_UNIT" <<EOF
[Unit]
Description=Mixbay EVO 8 split (only while the interface is connected)
After=pipewire.service wireplumber.service
[Service]
Type=simple
ExecStart=$runner --evo-split-run
Restart=always
RestartSec=2
[Install]
WantedBy=graphical-session.target
EOF
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable mixbay-evo8-split.service 2>/dev/null || true
  if (( legacy )); then
    warn "removed the old static EVO 8 split — restart PipeWire (--apply --restart) to drop its nodes"
  else
    systemctl --user restart mixbay-evo8-split.service 2>/dev/null || true
  fi
  ok "EVO 8 split watchdog installed ($EVO_SPLIT_UNIT)"
}

# evo_split_run: systemd user service body. Polls for the card, keeps the six
# stereo loopbacks alive while it is there, removes them when it is gone.
evo_split_run(){
  command -v pw-loopback >/dev/null 2>&1 \
    || { warn "pw-loopback not found — EVO 8 split disabled"; exit 0; }
  local p node="" in_node="" ch="" in_ch="" last_node="" last_in="" i
  local -a pids=("" "" "" "" "" "")
  local -a names=(main_output output_3_4 loopback_output mic_1_2 mic_3_4 loopback_capture)
  local -a nicks=("EVO 8" "EVO 8 3+4" "EVO 8 Loopback" "EVO 8" "EVO 8 Mic 3+4" "EVO 8 Loopback In")
  local -a positions=("FL FR" "FC LFE" "RL RR")

  stop_children(){
    for p in "${pids[@]}"; do
      [[ -n $p ]] && kill "$p" 2>/dev/null || true
    done
    pids=("" "" "" "" "" "")
  }
  trap 'stop_children; exit 0' TERM INT

  # start_one <index> <sink|source> <name> <nick> <capture-pos> <playback-pos> <target>
  start_one(){
    local idx="$1" kind="$2" name="$3" nick="$4" cpos="$5" ppos="$6" target="$7" carr parr
    if [[ -n ${pids[$idx]} ]] && kill -0 "${pids[$idx]}" 2>/dev/null; then return 0; fi
    carr="[\"${cpos// /\", \"}\"]"
    parr="[\"${ppos// /\", \"}\"]"
    if [[ $kind == sink ]]; then
      pw-loopback \
        --capture-props "{\"media.class\":\"Audio/Sink\",\"node.name\":\"evo8_$name\",\"node.nick\":\"$nick\",\"node.description\":\"EVO8 $name\",\"audio.position\":$carr}" \
        --playback-props "{\"node.name\":\"evo8_$name.out\",\"audio.position\":$parr,\"target.object\":\"$target\",\"node.dont-reconnect\":true,\"stream.dont-remix\":true}" \
        >/dev/null 2>&1 &
    else
      pw-loopback \
        --capture-props "{\"node.name\":\"evo8_$name.in\",\"audio.position\":$parr,\"target.object\":\"$target\",\"node.dont-reconnect\":true,\"stream.dont-remix\":true,\"node.passive\":true}" \
        --playback-props "{\"media.class\":\"Audio/Source\",\"node.name\":\"evo8_$name\",\"node.nick\":\"$nick\",\"node.description\":\"EVO8 $name\",\"audio.position\":$carr}" \
        >/dev/null 2>&1 &
    fi
    pids[$idx]=$!
  }

  info "EVO 8 split watchdog running"
  while :; do
    if evo_present evo8; then
      read -r node ch < <(discover_node evo8 output)
      if [[ -z $node || ${ch:-0} -lt 6 ]]; then
        set_pro_audio evo8 >/dev/null 2>&1 || true
        read -r node ch < <(discover_node evo8 output)
      fi
      read -r in_node in_ch < <(discover_node evo8 input)
      if [[ -n $node && -n $in_node && ${ch:-0} -ge 6 && ${in_ch:-0} -ge 6 ]]; then
        # A profile/name change means the old targets are gone: rebuild once.
        if [[ $node != "$last_node" || $in_node != "$last_in" ]]; then
          stop_children
          last_node="$node"; last_in="$in_node"
        fi
        for i in 0 1 2; do
          start_one "$i" sink "${names[$i]}" "${nicks[$i]}" "FL FR" "${positions[$i]}" "$node"
        done
        for i in 0 1 2; do
          start_one "$((i+3))" source "${names[$((i+3))]}" "${nicks[$((i+3))]}" \
            "${positions[$i]}" "FL FR" "$in_node"
        done
      fi
    else
      stop_children
      last_node=""; last_in=""
    fi
    sleep 2
  done
}

install_defaults(){
  mkdir -p "$BIN_DIR" "$SYS_USER"
  backup_file "$DEFAULT_SCRIPT"
  cat > "$DEFAULT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# mixbay-audio-defaults — set the user's default/priority card as the default
# sink/source. The card is read from foundation.json (first card set up wins;
# Settings can change it). Runs at login and after a foundation apply.
set -u
STATE="${XDG_CONFIG_HOME:-$HOME/.config}/mosquitomixbay/foundation.json"
CONNLOG="${XDG_CONFIG_HOME:-$HOME/.config}/mosquitomixbay/connected-interfaces.json"
command -v jq >/dev/null 2>&1 || exit 0
[[ -f $STATE ]] || exit 0
card="$(jq -r '.default // ""' "$STATE" 2>/dev/null)"
# No default chosen yet: leave PipeWire's own choice alone. Applying the
# first installed card here is what made a plugged-in Move take the lead.
[[ -n $card ]] || exit 0
sink_match="" src_match=""
case "$card" in
  evo8)
    sink_match="evo8_main_output"; src_match="evo8_mic_1_2" ;;
  evo4)      sink_match="EVO4";             src_match="EVO4" ;;
  ssl12)     sink_match="ssl12.pb12";       src_match="Solid_State_Logic_SSL_12" ;;
  # The UCM profile splits the CC-mode card into one sink per output pair.
  # "Fireface" alone matches the AES3 sink first, which is silent unless
  # something is plugged into AES; the analogue line outs are the speakers.
  fireface-ucx2) sink_match="HiFi__Line5__sink"; src_match="Fireface" ;;
  ugm192)    sink_match="UGM192";           src_match="UGM192" ;;
  *)
    # A downloaded card may declare its own nodes ("foundation": {sink,
    # source}); otherwise fall back to its connection-log match.
    card_file="${XDG_CONFIG_HOME:-$HOME/.config}/mosquitomixbay/cards/$card/upstream/card.json"
    if [[ -f $card_file ]]; then
      sink_match="$(jq -r '.spec.foundation.sink // ""' "$card_file" 2>/dev/null)"
      src_match="$(jq -r '.spec.foundation.source // ""' "$card_file" 2>/dev/null)"
    fi
    # Any card that was connected once (native, beta or unsupported) is in
    # the connection log with the ALSA match string.
    if [[ -f $CONNLOG ]]; then
      match="$(jq -r --arg id "$card" '.[]|select(.id==$id)|.match' "$CONNLOG" 2>/dev/null | head -1)"
      [[ -n $sink_match ]] || sink_match="$match"
      [[ -n $src_match ]] || src_match="$match"
    fi
    ;;
esac
[[ -n $sink_match ]] || exit 0
id_of(){ wpctl status 2>/dev/null | grep -m1 -E "[0-9]+\. .*$1.*(\[vol:|\[Audio/(Sink|Source)\])" | grep -oE '[0-9]+\.' | head -1 | tr -d .; }
sink=""; src=""
for _ in $(seq 1 20); do
  sink="$(id_of "$sink_match")"
  [[ -n ${sink:-} ]] && break
  sleep 0.5
done
[[ -n ${sink:-} ]] && wpctl set-default "$sink" >/dev/null 2>&1 \
  && printf 'default sink: %s (id=%s)\n' "$sink_match" "$sink"
src="$(id_of "$src_match")"
[[ -n ${src:-} ]] && wpctl set-default "$src" >/dev/null 2>&1 \
  && printf 'default source: %s (id=%s)\n' "$src_match" "$src"
exit 0
EOF
  chmod +x "$DEFAULT_SCRIPT"

  backup_file "$DEFAULT_UNIT"
  cat > "$DEFAULT_UNIT" <<EOF
[Unit]
Description=Mixbay audio defaults (default/priority card)
After=pipewire.service wireplumber.service
[Service]
Type=oneshot
ExecStart=$DEFAULT_SCRIPT
RemainAfterExit=yes
[Install]
WantedBy=graphical-session.target
EOF
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable mixbay-audio-defaults.service 2>/dev/null || true
  ok "default sink/source service installed"
}

restart_audio(){
  info "Restarting PipeWire + WirePlumber"
  systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null \
    && ok "audio graph restarted" || warn "audio graph restart failed"
  # The split sink only exists once the watchdog has re-created it, so give it
  # a moment before pointing the default sink at evo8_main_output.
  systemctl --user restart mixbay-evo8-split.service 2>/dev/null || true
  if evo_present evo8; then
    local i
    for i in $(seq 1 20); do
      pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx evo8_main_output && break
      sleep 0.5
    done
  fi
  "$DEFAULT_SCRIPT" 2>/dev/null || true
}

apply(){
  info "Applying the Mixbay audio foundation${DEV:+ for $DEV}"
  # The foundation is only ever applied to a card that has been plugged in
  # once: a downloaded card has no node to match until then.
  track_connections
  if [[ -n $DEV ]] && ! log_has_id "$DEV" && ! state_installed "$DEV"; then
    warn "$DEV has never been connected — plug it in once, then apply the foundation."
    return 1
  fi
  write_base_clock
  write_wp_rules
  # The EVO udev seat rule and audio-panel hints are EVO-specific: a
  # UCX II or downloaded card stays on the shared floor plus its own setup.
  if [[ -z $DEV || $DEV == evo8 || $DEV == evo4 ]]; then
    install_udev
    install_platform_hints
  fi
  local -a targets=()
  if [[ -n $DEV ]]; then
    targets=("$DEV")
  else
    evo_present evo8 && targets+=(evo8)
    evo_present evo4 && targets+=(evo4)
  fi
  # Migrate the old static split even with the card unplugged: its loopback
  # nodes are the phantom EVO 8 output this foundation must remove.
  if [[ -f $EVO_CONF && ! " ${targets[*]:-} " =~ " evo8 " ]]; then
    targets+=(evo8)
  fi
  local node ch dev first
  local -a firsts=()
  for dev in "${targets[@]}"; do
    first=0
    state_installed "$dev" || first=1
    case $dev in
      evo8)
        install_evo_split
        [[ -n "$(state_split evo8)" ]] || state_set_split evo8 off
        state_set_installed evo8 true
        ;;
      evo4)
        if (( FORCE_EVO4 )); then
          read -r node ch < <(discover_node evo4 output)
          # EVO 4 has 4 USB channels; the generic split uses the same layout
          # with only one output pair + loopback. UCM already does this on
          # modern ALSA, so it is opt-in.
          if [[ -n $node && $ch -ge 4 ]]; then
            write_evo4_split "$node" "$ch"
            [[ -n "$(state_split evo4)" ]] || state_set_split evo4 off
          else
            warn "EVO 4 split skipped: need a 4-channel USB node (got ${ch:-0})."
          fi
        fi
        state_set_installed evo4 true
        ;;
      ssl12|fireface-ucx2)
        # douze for the SSL 12, oscmix for the RME cards. The named
        # integration is the whole card-specific step; the shared floor
        # above is system config only.
        if run_card_setup "$(card_setup "$dev")"; then
          state_set_installed "$dev" true
        else
          warn "$dev setup failed — not marked as set up"
        fi
        ;;
      ugm192)
        # Native ALSA level 1: the shared floor is the setup.
        state_set_installed ugm192 true
        ;;
      *)
        if profile_installed "$dev"; then
          # A downloaded card may name its own integration (spec.setup);
          # without one the shared floor is all it needs.
          local kind; kind="$(card_setup "$dev")"
          if [[ -n $kind ]] && ! run_card_setup "$kind"; then
            warn "$dev setup failed — not marked as set up"
            continue
          fi
          state_set_installed "$dev" true
        else
          warn "Unknown device: $dev"
        fi
        ;;
    esac
    (( first )) && firsts+=("$dev") || true
  done
  install_defaults
  state_init
  # oscmix owns the RME cards; the foundation must not write ALSA volume/mute
  # to them on first setup (system-level config only). Other cards keep the
  # one-time preset application.
  for dev in "${firsts[@]}"; do
    [[ $(card_setup "$dev") == oscmix ]] || init_defaults "$dev"
  done
  ok "foundation applied"
  (( RESTART )) && restart_audio || true
}

write_evo4_split(){
  local node="$1" ch="$2" in_node in_ch
  read -r in_node in_ch < <(discover_node evo4 input)
  [[ $ch -ge 4 && -n $in_node ]] || return 0
  mkdir -p "$PW_DIR"
  backup_file "$EVO4_CONF"
  # One stereo main output (PC 1/2), one loopback output (LP 3/4), one mic
  # source (IN 1/2), one loopback capture (LP 3/4).
  cat > "$EVO4_CONF" <<EOF
# Mixbay audio foundation — EVO 4 opt-in split (--force-evo4-split).
# Modern ALSA UCM (>= 1.2.16) already exposes this graph; only use this file
# when the UCM is absent or the raw 4-channel node is all you have.
context.modules = [
  { name = libpipewire-module-loopback
    args = {
      node.description = "EVO4 Main Output"
      capture.props = { media.class = Audio/Sink node.name = "evo4_main_output" audio.position = [ FL FR ] }
      playback.props = { node.name = "evo4_main_output.out" audio.position = [ FL FR ] target.object = "$node" node.dont-reconnect = true stream.dont-remix = true }
    }
  }
  { name = libpipewire-module-loopback
    args = {
      node.description = "EVO4 Loopback Output"
      capture.props = { media.class = Audio/Sink node.name = "evo4_loopback_output" audio.position = [ FL FR ] }
      playback.props = { node.name = "evo4_loopback_output.out" audio.position = [ RL RR ] target.object = "$node" node.dont-reconnect = true stream.dont-remix = true }
    }
  }
  { name = libpipewire-module-loopback
    args = {
      node.description = "EVO4 Mic 1+2"
      capture.props = { node.name = "evo4_mic_1_2.in" audio.position = [ FL FR ] target.object = "$in_node" node.dont-reconnect = true stream.dont-remix = true node.passive = true }
      playback.props = { media.class = Audio/Source node.name = "evo4_mic_1_2" audio.position = [ FL FR ] }
    }
  }
  { name = libpipewire-module-loopback
    args = {
      node.description = "EVO4 Loopback Capture"
      capture.props = { node.name = "evo4_loopback_capture.in" audio.position = [ RL RR ] target.object = "$in_node" node.dont-reconnect = true stream.dont-remix = true node.passive = true }
      playback.props = { media.class = Audio/Source node.name = "evo4_loopback_capture" audio.position = [ FL FR ] }
    }
  }
]
EOF
  ok "EVO 4 split written ($EVO4_CONF)"
}

# toggle_split: --split on|off for one interface. This is a PANEL choice only:
# the split nodes exist while the card is connected, on lists every pair, off
# lists just the main stereo pair. No PipeWire restart, so volumes and routing
# never drop.
toggle_split(){
  local dev="$DEV" on="$SPLIT"
  [[ -n $dev ]] || { warn "--split needs --device"; return 2; }
  split_supported "$dev" || { warn "$dev has no Mixbay split to toggle"; return 1; }
  if [[ $dev == evo8 ]]; then
    [[ -f $EVO_SPLIT_UNIT ]] || { warn "EVO 8 split is not installed — run --apply first"; return 1; }
  else
    [[ -f $EVO4_CONF ]] || { warn "EVO 4 split is not installed — run --apply --force-evo4-split first"; return 1; }
  fi
  case $on in
    on|off) state_set_split "$dev" "$on" ;;
    *) warn "--split expects on|off"; return 2 ;;
  esac
  install_platform_hints
  ok "$dev split $on (audio panel only)"
  return 0
}

# setup_card: the card's own integration only, without the shared floor.
# Used right after a download and by the device screen's "Set up / repair".
# The audio foundation waits for a first connection, so this does not mark
# the card as installed.
setup_card(){
  local dev="$DEV" kind
  [[ -n $dev ]] || { warn "--setup needs --device"; return 2; }
  kind="$(card_setup "$dev")"
  [[ -n $kind ]] || { ok "$dev needs no card-specific setup"; return 0; }
  info "Setting up $dev ($kind)"
  run_card_setup "$kind" && ok "$dev setup finished"
}

# setup_users <setup> <exclude-id>: installed cards that still declare that
# integration, excluding the card being removed. It keeps a shared tool alive
# (oscmix for RME cards) while another compatible card is installed.
setup_users(){
  local setup="$1" skip="$2" f id
  for f in "$CONF"/mosquitomixbay/cards/*/upstream/card.json; do
    [[ -f $f ]] || continue
    id="${f#"$CONF"/mosquitomixbay/cards/}"
    id="${id%%/*}"
    [[ $id == "$skip" ]] && continue
    [[ "$(jq -r '.spec.setup // ""' "$f" 2>/dev/null)" == "$setup" ]] && printf '%s ' "$id"
  done
}

# remove_setup_if_unused <integration> <card-id>: uninstall the integration
# only when no other installed card needs it.
remove_setup_if_unused(){
  local kind="$1" dev="$2" left
  left="$(setup_users "$kind" "$dev")"
  if [[ -n $left ]]; then
    info "$kind kept: still used by ${left% }"
    return 0
  fi
  remove_card_setup "$kind" || warn "$kind removal reported a problem"
}

remove_device(){
  local dev="$1"
  info "Removing the Mixbay foundation for $dev"
  case $dev in
    evo8)
      rm -f "$EVO_CONF"
      systemctl --user disable --now mixbay-evo8-split.service 2>/dev/null || true
      rm -f "$EVO_SPLIT_UNIT"
      systemctl --user daemon-reload 2>/dev/null || true
      ;;
    evo4)
      if grep -q 'EVO4' "$EVO4_CONF" 2>/dev/null; then rm -f "$EVO4_CONF"; fi
      ;;
    ssl12)
      remove_setup_if_unused douze "$dev"
      ;;
    fireface-ucx2)
      remove_setup_if_unused oscmix "$dev"
      ;;
    ugm192) : ;;
    *)
      if profile_installed "$dev"; then
        [[ $dev =~ ^[a-z0-9][a-z0-9-]*$ ]] || { warn "Invalid device id: $dev"; return 1; }
        local kind; kind="$(card_setup "$dev")"
        if [[ -n $kind ]]; then
          remove_setup_if_unused "$kind" "$dev"
        fi
        rm -rf "$(profile_card_dir "$dev")"
      else
        warn "Unknown device: $dev"
        return 1
      fi
      ;;
  esac
  state_set_installed "$dev" false
  if [[ "$(state_default)" == "$dev" ]]; then
    # No silent promotion: the user chooses the next default. Leaving the
    # removed id behind would be worse, so the slot is cleared.
    state_set_default ""
  fi
  # Keep the shared floor while another card still uses it; drop the EVO
  # seat rule only when neither EVO remains.
  if [[ $dev == evo8 || $dev == evo4 ]]; then
    if ! state_installed evo8 && ! state_installed evo4; then
      mq_sudo rm -f "$UDEV_RULE" 2>/dev/null && mq_sudo udevadm control --reload-rules 2>/dev/null || true
    fi
    # The panel hints name the EVO nodes: recompute them, or a removed card
    # stays hidden/replaced in the Omarchy audio panel.
    [[ -f $PLATFORM_AUDIO ]] && install_platform_hints >/dev/null 2>&1 || true
  fi
  install_defaults
  ok "$dev removed from the Mixbay foundation (shared WirePlumber floor kept)"
}

remove_all(){
  info "Removing the Mixbay audio foundation"
  rm -f "$BASE_CONF" "$EVO_CONF" "$EVO4_CONF" "$WP_CONF" "$DEFAULT_SCRIPT" "$DEFAULT_UNIT" "$EVO_SPLIT_UNIT"
  systemctl --user disable --now mixbay-audio-defaults.service mixbay-evo8-split.service 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  if [[ -f $UDEV_RULE ]]; then
    mq_sudo rm -f "$UDEV_RULE" && mq_sudo udevadm control --reload-rules \
      && ok "udev seat rule removed" || warn "could not remove $UDEV_RULE"
  fi
  if [[ -f $PLATFORM_AUDIO ]]; then
    if mq_sudo test -f "$PLATFORM_AUDIO_BAK"; then
      mq_sudo install -D -m 0644 "$PLATFORM_AUDIO_BAK" "$PLATFORM_AUDIO" \
        && ok "audio panel hints restored (previous file)" \
        || warn "could not restore $PLATFORM_AUDIO"
      mq_sudo rm -f "$PLATFORM_AUDIO_BAK" || true
    else
      mq_sudo rm -f "$PLATFORM_AUDIO" && ok "audio panel hints removed" \
        || warn "could not remove $PLATFORM_AUDIO"
    fi
  fi
  if [[ -f $CAPTURE_RULE || -f $CAPTURE_HELPER ]]; then
    mq_sudo rm -f "$CAPTURE_RULE" "$CAPTURE_HELPER" \
      && mq_sudo udevadm control --reload-rules \
      && ok "EVO 8 capture helper removed" \
      || warn "could not remove the EVO 8 capture helper (needs sudo)"
  fi
  state_init
  printf '{"default":"","devices":{}}\n' > "$STATE"
  ok "foundation files removed (pipewire-settings config untouched)"
  (( RESTART )) && restart_audio || true
}

needs(){
  local dev="${DEV:-evo8}" miss=0 kind
  kind="$(card_setup "$dev")"
  # EVO-specific system files: not part of an RME card's setup.
  if [[ $kind != oscmix && ! -f $UDEV_RULE ]]; then
    echo "udev seat rule for /dev/evo4 + /dev/evo8"; miss=1
  fi
  if [[ ! -f $WP_CONF ]]; then echo "WirePlumber anti-suspend/no-upmix rule"; miss=1; fi
  if [[ $kind != oscmix && ! -f $PLATFORM_AUDIO ]]; then
    echo "audio panel hints (one entry per interface)"; miss=1
  fi
  if [[ $dev == evo8 ]]; then
    local node ch; read -r node ch < <(discover_node evo8 output)
    if evo_present evo8 && [[ ( -z $node || $ch -lt 6 ) ]]; then
      echo "EVO 8 6-channel Pro Audio node (select the multichannel profile / check the USB connection)"
      miss=1
    fi
    if [[ ! -f $EVO_SPLIT_UNIT ]]; then echo "EVO 8 split watchdog (nodes only while the card is connected)"; miss=1; fi
    if [[ ! -f $DEFAULT_UNIT ]]; then echo "EVO 8 default sink/source service"; miss=1; fi
  fi
  if [[ $dev == ssl12 ]]; then
    systemctl --user is-active --quiet douze 2>/dev/null || { echo "douze daemon (SSL 12 backend)"; miss=1; }
    [[ -d "$CONF/omarchy/plugins/fenrirrhogar.omarchy360" ]] || { echo "Omarchy360 plugin (full SSL 12 surface)"; miss=1; }
    [[ -f "$PW_DIR/99-ssl12-sinks.conf" ]] || { echo "SSL 12 PipeWire playback-pair split (only when the card is connected)"; miss=1; }
  fi
  if [[ $kind == oscmix ]]; then
    oscmix_installed || { echo "oscmix (engine + GTK mixer, RME control surface)"; miss=1; }
    if command -v aconnect >/dev/null 2>&1; then
      aconnect -l 2>/dev/null | grep -qi 'Fireface' \
        || { echo "$dev in Class Compliant mode (ALSA sequencer client missing; check: aconnect -l)"; miss=1; }
    elif command -v amidi >/dev/null 2>&1; then
      amidi -l 2>/dev/null | grep -qi 'Fireface' \
        || { echo "$dev in Class Compliant mode (raw MIDI port missing; check: amidi -l)"; miss=1; }
    fi
  fi
  return $(( miss != 0 ))
}

case $MODE in
  status) if (( JSON )); then status_json; else status_human; fi ;;
  needs) needs ;;
  apply) apply ;;
  setup) setup_card ;;
  split) toggle_split ;;
  remove)
    if [[ -n $DEV ]]; then remove_device "$DEV"; else remove_all; fi
    ;;
  set-default)
    if [[ -z $DEV ]]; then warn "--set-default needs a device id"; exit 2; fi
    if ! state_installed "$DEV" && ! log_has_id "$DEV"; then
      warn "$DEV was never connected/installed — nothing to make default"
      exit 1
    fi
    state_set_default "$DEV"
    install_defaults
    "$DEFAULT_SCRIPT" 2>/dev/null || true
    ok "default audio interface: $DEV"
    ;;
  track) track_connections ;;
  evo-split-run) evo_split_run ;;
  reset-history)
    printf '[]\n' > "$CONNLOG"
    ok "connected-interface history cleared (installed configs are kept)"
    ;;
esac
