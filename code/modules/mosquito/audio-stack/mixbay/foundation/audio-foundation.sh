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
#     EVO 4 is left to ALSA UCM >= 1.2.16, which already exposes the right
#     stereo output / split captures.
#   • Defaults: EVO 8 main out + mic 1+2 become the default sink/source at
#     login, through a small user service.
#   • Rate: 48 kHz / 1024 frames with 44.1–192 kHz allowed, written only when
#     the mosquitOmarchy pipewire-settings module is not already managing the
#     clock (90-mosquitomarchy-pipewire.conf). Health checks always report the
#     graph rate, the device rate and a mismatch.
#
# Usage:
#   mixbay-audio-foundation --status [--json]
#   mixbay-audio-foundation --needs evo8
#   mixbay-audio-foundation --apply [--restart] [--force-evo4-split]
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
DEFAULT_SCRIPT="$BIN_DIR/mixbay-audio-defaults"
DEFAULT_UNIT="$SYS_USER/mixbay-audio-defaults.service"
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

# ── per-card state / default card ──────────────────────────────────────────
# foundation.json is the single source of truth for "which cards did the user
# set up" and "which one is the default/priority card". The first card set up
# becomes the default; Settings can change it later.
state_init(){
  mkdir -p "$(dirname "$STATE")"
  if [[ ! -f $STATE ]]; then
    printf '{"default":"","devices":{}}\n' > "$STATE"
    return 0
  fi
  # Migrate the old one-field {"applied":...} file from the first foundation
  # version: it has no .devices, and every jq query below would fail.
  if ! jq -e 'type == "object" and has("devices") and (.devices | type == "object")' "$STATE" >/dev/null 2>&1; then
    printf '{"default":"","devices":{}}\n' > "$STATE"
  fi
}
state_installed(){
  state_init
  jq -e --arg id "$1" '.devices[$id].installed == true' "$STATE" >/dev/null 2>&1
}
state_set_installed(){
  state_init
  local id="$1" on="$2"
  jq --arg id "$id" --argjson on "$on" \
    '.devices[$id] = ((.devices[$id] // {}) + {installed: $on, at: (now|todate)})' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
state_default(){ state_init; jq -r '.default // ""' "$STATE"; }
state_set_default(){
  state_init
  jq --arg id "$1" '.default = $id' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
# split is "on"/"off"/"" (never chosen). "off" is a user choice, not a gap the
# onboarding prompt may keep asking about.
state_split(){
  state_init
  jq -r --arg id "$1" '.devices[$id].split // ""' "$STATE" 2>/dev/null || true
}
state_set_split(){
  state_init
  jq --arg id "$1" --arg v "$2" \
    '.devices[$id] = ((.devices[$id] // {}) + {split: $v})' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
state_set_default_if_empty(){
  [[ -n "$(state_default)" ]] && return 0
  state_set_default "$1"
}
state_first_installed(){
  state_init
  jq -r '(.default // "") as $d | if $d != "" then $d else (.devices | to_entries | map(select(.value.installed == true)) | .[0].key // "") end' "$STATE"
}

FORCE_EVO4=0 RESTART=0 MODE=status JSON=0 DEV="" SPLIT=""
while (($#)); do
  case "$1" in
    --status) MODE=status; shift ;;
    --needs) MODE=needs; shift ;;
    --apply) MODE=apply; shift ;;
    --remove) MODE=remove; shift ;;
    --split) MODE=split; SPLIT="${2:-}"; shift 2; ;;
    --track) MODE=track; shift ;;
    --reset-history) MODE=reset-history; shift ;;
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
    *fireface*|*ucx*) echo fireface-ucx2 ;;
    *ugm192*|*"ugm 192"*) echo ugm192 ;;
  esac
}
version_for_id(){
  case "$1" in
    evo8|evo4) echo v1.0.0 ;;
    ssl12) echo v0.1.0 ;;
    fireface-ucx2|ugm192) echo v0.0.1 ;;
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
    jq --arg id "$id" --arg name "$name" --arg match "$match" --arg version "$version" \
      '. + [{id:$id,name:$name,match:$match,version:$version,native:true,last_seen:(now|todate)}]' \
      "$CONNLOG" > "$CONNLOG.tmp" && mv "$CONNLOG.tmp" "$CONNLOG"
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
      existing="$(jq -r --arg n "$desc" '.[]|select(.name==$n)|.id' \
        "$CONF/mosquitomixbay/beta-devices.json" 2>/dev/null | head -1 || true)"
      id="${existing:-beta-$(slug "$desc")}"
    fi
    jq --arg id "$id" --arg name "$name" --arg match "$match" \
      --arg version "$version" --argjson native "$native" \
      'map(select(.id != $id)) + [{id:$id,name:$name,match:$match,version:$version,native:$native,last_seen:(now|todate)}]' \
      "$CONNLOG" > "$CONNLOG.tmp" && mv "$CONNLOG.tmp" "$CONNLOG"
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

native_installed(){
  state_installed "$1" && return 0
  case "$1" in
    evo8) [[ -f $EVO_CONF ]] ;;
    ssl12) systemctl --user is-active --quiet douze 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# split_supported <id>: interfaces whose split file Mixbay owns and can toggle.
split_supported(){
  case "$1" in evo8|evo4) return 0 ;; *) return 1 ;; esac
}

# split_state <id> -> on|off|"". Empty means "no split concept" (ALSA level 1).
split_state(){
  case "$1" in
    evo8)
      if [[ "$(state_split evo8)" == off ]]; then echo off
      elif [[ -f $EVO_CONF ]]; then echo on
      else echo off; fi ;;
    evo4)
      if [[ "$(state_split evo4)" == off ]]; then echo off
      elif [[ -f $EVO4_CONF ]]; then echo on
      else echo off; fi ;;
    *) echo "" ;;
  esac
}

status_json(){
  local rate quantum allowed id name version native installed online drate match beta
  local mismatch=0 wp=0 udev=0 defaults=0 base=0 split=0
  PW="$(pw_dump)"
  rate="$(pw_get clock.rate)"
  quantum="$(pw_get clock.quantum)"
  allowed="$(pw_get clock.allowed-rates)"
  [[ -f $EVO_CONF ]] && split=1
  [[ -f $WP_CONF ]] && wp=1
  [[ -f $UDEV_RULE ]] && udev=1
  [[ -f $DEFAULT_UNIT ]] && defaults=1
  [[ -f $BASE_CONF ]] && base=1
  track_connections
  local cards='[]' conns='[]'
  while IFS=$'\t' read -r id name version native match; do
    [[ -n $id ]] || continue
    beta=false; [[ $native == false ]] && beta=true
    installed=false; native_installed "$id" && installed=true
    if [[ $beta == true ]]; then
      jq -e --arg id "$id" '.[]|select(.id==$id)' \
        "$CONF/mosquitomixbay/beta-devices.json" >/dev/null 2>&1 && installed=true
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
    if [[ $beta == false ]] || jq -e --arg id "$id" '.[]|select(.id==$id)' \
        "$CONF/mosquitomixbay/beta-devices.json" >/dev/null 2>&1; then
      cards="$(jq -c --argjson d "$cards" --argjson r "$row" '. + [$r]' <<< "$cards")"
    fi
  done < <(jq -r '.[] | [.id,.name,.version,(.native|tostring),.match] | @tsv' "$CONNLOG" 2>/dev/null || true)
  local default; default="$(state_default)"; [[ -z $default ]] && default="$(state_first_installed)"
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
  local default; default="$(state_default)"; [[ -z $default ]] && default="$(state_first_installed)"
  printf '  default    : %s\n' "${default:-none}"
  track_connections
  local native match
  while IFS=$'\t' read -r dev name version native match; do
    [[ -n $dev ]] || continue
    installed="no"; native_installed "$dev" && installed="yes"
    if [[ $native == false ]] && jq -e --arg id "$dev" '.[]|select(.id==$id)' \
        "$CONF/mosquitomixbay/beta-devices.json" >/dev/null 2>&1; then
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

# Hide Mixbay's internal nodes from the Omarchy bar and audio panel. Every
# split node exists for Mixbay's routing, but the user sees ONE entry per
# interface: evo8_main_output / evo8_mic_1_2. The raw Pro Audio node is hidden
# only while its split exists, so an interface without a split stays visible.
install_platform_hints(){
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
{
  "hidden": [
    "evo8_(output_3_4|loopback_output|mic_3_4|loopback_capture)(\\.(out|in|monitor))?",
    "evo8_(main_output|mic_1_2)\\.(out|in|monitor)",
    "evo4_(loopback_output|loopback_capture)(\\.(out|in|monitor))?",
    "evo4_(main_output|mic_1_2)\\.(out|in|monitor)"
  ],
  "replaced": [
    { "node": "alsa_(output|input)\\.usb-Audient_EVO8-.*\\.pro-.*", "by": "evo8_(main_output|mic_1_2)" },
    { "node": "alsa_(output|input)\\.usb-Audient_EVO4-.*\\.pro-.*", "by": "evo4_(main_output|mic_1_2)" }
  ]
}
EOF
  mq_sudo install -D -m 0644 "$tmp" "$PLATFORM_AUDIO" \
    && ok "audio panel hints installed (one entry per Mixbay interface)" \
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
  # six capture channels silent even when gains/mutes/48V are correct.
  if [[ -f "$MIXBAY_ROOT/kmod/evo8-capture-enable.py" && -f "$MIXBAY_ROOT/kmod/99-evo8-capture.rules" ]]; then
    mq_sudo install -D -m 0755 "$MIXBAY_ROOT/kmod/evo8-capture-enable.py" "$CAPTURE_HELPER" \
      && mq_sudo install -D -m 0644 "$MIXBAY_ROOT/kmod/99-evo8-capture.rules" "$CAPTURE_RULE" \
      && mq_sudo udevadm control --reload-rules \
      && ok "EVO 8 capture helper installed" \
      || warn "could not install the EVO 8 capture helper"
  fi
}

write_evo_split(){
  local dev="$1" node="$2" ch="$3"
  local in_node in_ch
  if [[ -f "$PW_DIR/evo8-stereo.conf" ]]; then
    warn "upstream evo8-stereo.conf is present — not writing a second split (duplicate nodes)."
    return 0
  fi
  read -r in_node in_ch < <(discover_node "$dev" input)
  if [[ -z $node || -z $in_node || $ch -lt 6 ]]; then
    warn "$dev split skipped: need a 6-channel USB node (got ${ch:-0} playback / ${in_ch:-0} capture)."
    warn "Connect the EVO, select the multichannel/Pro Audio profile, then re-run."
    return 0
  fi
  mkdir -p "$PW_DIR"
  backup_file "$EVO_CONF"
  cat > "$EVO_CONF" <<EOF
# Mixbay audio foundation — EVO 8 stereo split.
# Generated from the live PipeWire graph: target names carry the card serial.
# Playback CH1/2 = main, CH3/4 = output 3+4, CH5/6 = loopback out.
# Capture  CH1/2 = mic 1+2, CH3/4 = mic 3+4, CH5/6 = loopback capture.
context.modules = [
EOF
  local -a names=(main_output output_3_4 loopback_output)
  local -a positions=("FL FR" "FC LFE" "RL RR")
  local i
  for i in 0 1 2; do
    cat >> "$EVO_CONF" <<EOF
  { name = libpipewire-module-loopback
    args = {
      node.description = "EVO8 ${names[$i]}"
      capture.props = {
        media.class = Audio/Sink
        node.name = "evo8_${names[$i]}"
        node.nick = "EVO 8"
        audio.position = [ FL FR ]
      }
      playback.props = {
        node.name = "evo8_${names[$i]}.out"
        audio.position = [ ${positions[$i]} ]
        target.object = "$node"
        node.dont-reconnect = true
        stream.dont-remix = true
      }
    }
  }
EOF
  done
  local -a srcs=(mic_1_2 mic_3_4 loopback_capture)
  local -a srcpos=("FL FR" "FC LFE" "RL RR")
  for i in 0 1 2; do
    cat >> "$EVO_CONF" <<EOF
  { name = libpipewire-module-loopback
    args = {
      node.description = "EVO8 ${srcs[$i]}"
      capture.props = {
        node.name = "evo8_${srcs[$i]}.in"
        audio.position = [ ${srcpos[$i]} ]
        target.object = "$in_node"
        node.dont-reconnect = true
        stream.dont-remix = true
        node.passive = true
      }
      playback.props = {
        media.class = Audio/Source
        node.name = "evo8_${srcs[$i]}"
        node.nick = "EVO 8"
        audio.position = [ FL FR ]
      }
    }
  }
EOF
  done
  echo ']' >> "$EVO_CONF"
  ok "EVO 8 split written ($EVO_CONF)"
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
if [[ -z $card ]]; then
  card="$(jq -r '.devices | to_entries | map(select(.value.installed == true)) | .[0].key // ""' "$STATE" 2>/dev/null)"
fi
[[ -n $card ]] || exit 0
sink_match="" src_match=""
case "$card" in
  evo8)
    sink_match="evo8_main_output"; src_match="evo8_mic_1_2"
    # Split off: those loopback nodes do not exist; the raw Pro Audio node is
    # the single visible entry, so it must also be the default.
    if ! wpctl status 2>/dev/null | grep -q "evo8_main_output"; then
      sink_match="EVO8 Pro"; src_match="EVO8 Pro"
    fi
    ;;
  evo4)      sink_match="EVO4";             src_match="EVO4" ;;
  ssl12)     sink_match="ssl12.pb12";       src_match="Solid_State_Logic_SSL_12" ;;
  fireface-ucx2) sink_match="Fireface";     src_match="Fireface" ;;
  ugm192)    sink_match="UGM192";           src_match="UGM192" ;;
  *)
    # Any card that was connected once (native, beta or unsupported) is in
    # the connection log with the ALSA match string.
    if [[ -f $CONNLOG ]]; then
      match="$(jq -r --arg id "$card" '.[]|select(.id==$id)|.match' "$CONNLOG" 2>/dev/null | head -1)"
      sink_match="$match"; src_match="$match"
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
  "$DEFAULT_SCRIPT" 2>/dev/null || true
}

apply(){
  info "Applying the Mixbay audio foundation${DEV:+ for $DEV}"
  write_base_clock
  write_wp_rules
  install_udev
  install_platform_hints
  local -a targets=()
  if [[ -n $DEV ]]; then
    targets=("$DEV")
  else
    evo_present evo8 && targets+=(evo8)
    evo_present evo4 && targets+=(evo4)
  fi
  local node ch dev first
  local -a firsts=()
  for dev in "${targets[@]}"; do
    first=0
    state_installed "$dev" || first=1
    case $dev in
      evo8)
        if [[ "$(state_split evo8)" == off ]]; then
          rm -f "$EVO_CONF"
        else
          read -r node ch < <(discover_node evo8 output)
          if evo_present evo8 && { [[ -z $node ]] || (( ch < 6 )); }; then
            info "Selecting the EVO 8 Pro Audio profile (6 USB channels)"
            set_pro_audio evo8 && read -r node ch < <(discover_node evo8 output) \
              || warn "could not select the EVO 8 Pro Audio profile"
          fi
          write_evo_split evo8 "$node" "$ch"
          [[ -f $EVO_CONF ]] && state_set_split evo8 on
        fi
        state_set_installed evo8 true
        state_set_default_if_empty evo8
        ;;
      evo4)
        if (( FORCE_EVO4 )); then
          read -r node ch < <(discover_node evo4 output)
          # EVO 4 has 4 USB channels; the generic split uses the same layout
          # with only one output pair + loopback. UCM already does this on
          # modern ALSA, so it is opt-in.
          if [[ -n $node && $ch -ge 4 ]]; then
            write_evo4_split "$node" "$ch"
            [[ -f $EVO4_CONF ]] && state_set_split evo4 on
          else
            warn "EVO 4 split skipped: need a 4-channel USB node (got ${ch:-0})."
          fi
        fi
        state_set_installed evo4 true
        state_set_default_if_empty evo4
        ;;
      ssl12)
        local douze="$MIXBAY_ROOT/../../../Apps/douze/setup-douze.sh"
        if [[ -f $douze ]]; then
          if bash "$douze" -y --update --no-restart; then
            state_set_installed ssl12 true
            state_set_default_if_empty ssl12
          else
            warn "douze setup failed — SSL 12 not marked as set up"
          fi
        else
          warn "douze module not found ($douze) — install it from Setup → Apps → douze"
        fi
        ;;
      fireface-ucx2|ugm192)
        # Native ALSA level 1: the shared floor is the setup.
        state_set_installed "$dev" true
        state_set_default_if_empty "$dev"
        ;;
      *)
        if jq -e --arg id "$dev" '.[]|select(.id==$id)' \
            "$CONF/mosquitomixbay/beta-devices.json" >/dev/null 2>&1; then
          state_set_installed "$dev" true
          state_set_default_if_empty "$dev"
        else
          warn "Unknown device: $dev"
        fi
        ;;
    esac
    (( first )) && firsts+=("$dev") || true
  done
  install_defaults
  state_init
  for dev in "${firsts[@]}"; do init_defaults "$dev"; done
  ok "foundation applied"
  if (( RESTART )); then
    restart_audio
    # The restart re-enumerates the card before WirePlumber has saved the
    # profile, so it falls back to surround 2.1 and the split targets vanish.
    # Select pro-audio again now that the graph is up; it persists from here.
    if evo_present evo8 && state_installed evo8; then
      # restart_audio already ran the defaults script, but the split sink only
      # exists once pro-audio is back: run it again after the profile switch.
      set_pro_audio evo8 && "$DEFAULT_SCRIPT" 2>/dev/null \
        || warn "EVO 8 Pro Audio profile not restored after restart"
    fi
  fi
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

# toggle_split: --split on|off for one interface. Visibility follows the file:
# with a split the raw Pro Audio node is hidden and the stereo main/mic nodes
# are the single entry; without it the raw node is the one entry. Only EVO
# splits are Mixbay-owned (SSL 12 belongs to douze).
toggle_split(){
  local dev="$DEV" on="$SPLIT" node ch
  [[ -n $dev ]] || { warn "--split needs --device"; return 2; }
  split_supported "$dev" || { warn "$dev has no Mixbay split to toggle"; return 1; }
  case $on in
    on)
      native_online "$dev" || { warn "$dev is offline — connect it, then turn the split on"; return 1; }
      if [[ $dev == evo8 ]]; then
        read -r node ch < <(discover_node evo8 output)
        if [[ -z $node || $ch -lt 6 ]]; then
          set_pro_audio evo8 || true
          read -r node ch < <(discover_node evo8 output)
        fi
        write_evo_split evo8 "$node" "$ch"
        [[ -f $EVO_CONF ]] || return 1
        state_set_split evo8 on
      else
        read -r node ch < <(discover_node evo4 output)
        write_evo4_split "$node" "$ch"
        [[ -f $EVO4_CONF ]] || return 1
        state_set_split evo4 on
      fi
      ok "$dev split on"
      ;;
    off)
      if [[ $dev == evo8 ]]; then rm -f "$EVO_CONF"; else rm -f "$EVO4_CONF"; fi
      state_set_split "$dev" off
      ok "$dev split off"
      ;;
    *) warn "--split expects on|off"; return 2 ;;
  esac
  if (( RESTART )); then
    restart_audio
    if [[ $dev == evo8 && $on == on ]] && evo_present evo8; then
      # Same restart race as apply: re-select pro-audio once the graph is up.
      set_pro_audio evo8 && "$DEFAULT_SCRIPT" 2>/dev/null || true
    fi
  fi
  return 0
}

remove_device(){
  local dev="$1"
  info "Removing the Mixbay foundation for $dev"
  case $dev in
    evo8)
      if grep -q 'EVO8' "$EVO_CONF" 2>/dev/null; then rm -f "$EVO_CONF"; fi
      ;;
    evo4)
      if grep -q 'EVO4' "$EVO4_CONF" 2>/dev/null; then rm -f "$EVO4_CONF"; fi
      ;;
    ssl12)
      local douze="$MIXBAY_ROOT/../../../Apps/douze/setup-douze.sh"
      if [[ -f $douze ]]; then
        bash "$douze" --remove || warn "douze removal reported a problem"
      else
        warn "douze module not found — remove it from Setup → Apps → douze"
      fi
      ;;
    fireface-ucx2|ugm192) : ;;
    *)
      if jq -e --arg id "$dev" '.[]|select(.id==$id)' \
          "$CONF/mosquitomixbay/beta-devices.json" >/dev/null 2>&1; then
        jq --arg id "$dev" 'map(select(.id != $id))' \
          "$CONF/mosquitomixbay/beta-devices.json" > "$CONF/mosquitomixbay/beta-devices.json.tmp" \
          && mv "$CONF/mosquitomixbay/beta-devices.json.tmp" "$CONF/mosquitomixbay/beta-devices.json"
      else
        warn "Unknown device: $dev"
        return 1
      fi
      ;;
  esac
  state_set_installed "$dev" false
  if [[ "$(state_default)" == "$dev" ]]; then
    local next
    next="$(jq -r '.devices | to_entries | map(select(.value.installed == true)) | .[0].key // ""' "$STATE" 2>/dev/null || true)"
    state_set_default "$next"
  fi
  # Keep the shared floor while another card still uses it; drop the EVO
  # seat rule only when neither EVO remains.
  if [[ $dev == evo8 || $dev == evo4 ]]; then
    if ! state_installed evo8 && ! state_installed evo4; then
      mq_sudo rm -f "$UDEV_RULE" 2>/dev/null && mq_sudo udevadm control --reload-rules 2>/dev/null || true
    fi
  fi
  install_defaults
  ok "$dev removed from the Mixbay foundation (shared WirePlumber floor kept)"
}

remove_all(){
  info "Removing the Mixbay audio foundation"
  rm -f "$BASE_CONF" "$EVO_CONF" "$EVO4_CONF" "$WP_CONF" "$DEFAULT_SCRIPT" "$DEFAULT_UNIT"
  systemctl --user disable --now mixbay-audio-defaults.service 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  if [[ -f $UDEV_RULE ]]; then
    mq_sudo rm -f "$UDEV_RULE" && mq_sudo udevadm control --reload-rules \
      && ok "udev seat rule removed" || warn "could not remove $UDEV_RULE"
  fi
  if [[ -f $PLATFORM_AUDIO ]]; then
    mq_sudo rm -f "$PLATFORM_AUDIO" && ok "audio panel hints removed" \
      || warn "could not remove $PLATFORM_AUDIO"
  fi
  state_init
  printf '{"default":"","devices":{}}\n' > "$STATE"
  ok "foundation files removed (pipewire-settings config untouched)"
  (( RESTART )) && restart_audio || true
}

needs(){
  local dev="${DEV:-evo8}" miss=0
  if [[ ! -f $UDEV_RULE ]]; then echo "udev seat rule for /dev/evo4 + /dev/evo8"; miss=1; fi
  if [[ ! -f $WP_CONF ]]; then echo "WirePlumber anti-suspend/no-upmix rule"; miss=1; fi
  if [[ ! -f $PLATFORM_AUDIO ]]; then echo "audio panel hints (one entry per interface)"; miss=1; fi
  if [[ $dev == evo8 ]]; then
    local node ch; read -r node ch < <(discover_node evo8 output)
    if [[ "$(state_split evo8)" != off ]] && evo_present evo8 && [[ ( -z $node || $ch -lt 6 ) ]]; then
      echo "EVO 8 6-channel Pro Audio node (select the multichannel profile / check the USB connection)"
      miss=1
    fi
    if [[ -n $node && $ch -ge 6 && ! -f $EVO_CONF && "$(state_split evo8)" != off ]]; then echo "EVO 8 stereo split (6-channel Pro Audio node)"; miss=1; fi
    if [[ ! -f $DEFAULT_UNIT ]]; then echo "EVO 8 default sink/source service"; miss=1; fi
  fi
  if [[ $dev == ssl12 ]]; then
    systemctl --user is-active --quiet douze 2>/dev/null || { echo "douze daemon (SSL 12 backend)"; miss=1; }
    [[ -d "$CONF/omarchy/plugins/fenrirrhogar.omarchy360" ]] || { echo "Omarchy360 plugin (full SSL 12 surface)"; miss=1; }
    [[ -f "$PW_DIR/99-ssl12-sinks.conf" ]] || { echo "SSL 12 PipeWire playback-pair split (only when the card is connected)"; miss=1; }
  fi
  return $(( miss == 0 ))
}

case $MODE in
  status) if (( JSON )); then status_json; else status_human; fi ;;
  needs) needs ;;
  apply) apply ;;
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
  reset-history)
    printf '[]\n' > "$CONNLOG"
    ok "connected-interface history cleared (installed configs are kept)"
    ;;
esac
