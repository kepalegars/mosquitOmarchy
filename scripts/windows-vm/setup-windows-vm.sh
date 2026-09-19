#!/bin/bash
# =============================================================================
# Omarchy Custom - Setup Windows VM (all-in-one, auto-detection)
# =============================================================================
# Merges the former setup-windows-vm.sh / setup-winvm-menu.sh /
# setup-windows-vm-debloat.sh into a single script. One simple run detects what
# is present and applies whatever is relevant:
#
#   1. Launcher "windows-vm-usb"  : starts the VM + redirects external drives
#      via RDP (+ DPI/scale identical to the official launcher)
#   2. Menu entry "Windows" pointing to this launcher
#   3. Manager "winvm"      : RAM / CPU / disk / start / stop / status (gum TUI)
#   4. Entry "Setup > Windows VM" launching winvm in the Omarchy menu
#   5. Debloat (dockur /oem)     : registry + WinUtil + RDP drive mapping, applied
#      automatically if the VM is detected as installed (otherwise skipped)
#
# Usage :
#   ./setup-windows-vm.sh             # applies everything (idempotent, auto-detects)
#   ./setup-windows-vm.sh --fresh     # debloat via Windows REINSTALL (overwrites data.img)
#   ./setup-windows-vm.sh --remove    # removes helpers + menu entries (keeps the config)
#
# Prerequisites : Omarchy + (ideally) VM installed via 'omarchy-windows-vm install'.
# If the VM is not there yet, the script offers it ; winvm remains usable.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m !\033[0m $*"; }
die()   { warn "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$HOME/.config/windows/docker-compose.yml"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
MENU_DIR="$HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
OEM_DIR="$HOME/.config/windows/oem"
DATA_IMG="$HOME/.windows/data.img"
PRESET="Standard"          # Standard | Minimal | Advanced

BLOCK_WINVM_START="// >>> Omarchy_Custom_Scripts - managed by setup-windows-vm.sh"
BLOCK_WINVM_END="// <<< Omarchy_Custom_Scripts"

FRESH=false REMOVE=false
for a in "$@"; do
  case "$a" in
    --fresh) FRESH=true ;;
    --remove) REMOVE=true ;;
    -y|--yes) : ;;
    -h|--help) sed -n '1,26p' "$0"; exit 0 ;;
    *) echo "Unknown option: $a (supported: --fresh --remove -y)" >&2; exit 1 ;;
  esac
done

# -----------------------------------------------------------------------------
# 0. Prerequisites / auto-detection
# -----------------------------------------------------------------------------
[[ -d /usr/share/omarchy ]] || die "This script is meant for Omarchy."

if [[ $REMOVE == false ]] && [[ ! -f $COMPOSE ]]; then
  warn "Windows VM not installed (~/.config/windows/docker-compose.yml missing)."
  warn "Run first: omarchy-windows-vm install   (long download)."
  warn "The 'winvm' manager and the launcher will still be installed."
  warn "Debloat will be skipped until the VM exists (rerun this script afterwards)."
fi

# -----------------------------------------------------------------------------
# 1. Launcher windows-vm-usb
# -----------------------------------------------------------------------------
if [[ $REMOVE == false ]]; then
  info "Deploying launcher $BIN_DIR/windows-vm-usb"
  mkdir -p "$BIN_DIR"

  cat > "$BIN_DIR/windows-vm-usb" << 'LAUNCHER_EOF'
#!/bin/bash
# Launch the Omarchy Windows VM and redirect removable drives via RDP.
# Usage: windows-vm-usb [-k|--keep-alive]
#   -k  keep the VM running after the RDP session closes

COMPOSE="$HOME/.config/windows/docker-compose.yml"
CONTAINER="omarchy-windows"
KEEP_ALIVE=false
[[ $1 == "-k" || $1 == "--keep-alive" ]] && KEEP_ALIVE=true

if [[ ! -f $COMPOSE ]]; then
  echo "Windows VM not configured. Run: omarchy-windows-vm install" >&2
  exit 1
fi

WIN_USER=$(grep "USERNAME:" "$COMPOSE" | sed 's/.*USERNAME: "\(.*\)"/\1/')
WIN_PASS=$(grep "PASSWORD:" "$COMPOSE" | sed 's/.*PASSWORD: "\(.*\)"/\1/')
[[ -z $WIN_USER ]] && WIN_USER="docker"
[[ -z $WIN_PASS ]] && WIN_PASS="admin"

STATE=$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null)

if [[ $STATE != "running" ]]; then
  echo "Starting Windows VM..."
  omarchy-notification-send -g "Starting Windows VM" "This can take 15-30 seconds" -t 15000
  if ! docker compose -f "$COMPOSE" up -d; then
    omarchy-notification-send -u critical "Windows VM" "Failed to start"
    exit 1
  fi
fi

# Timestamp of THIS boot: ignore any success message from previous boots
BOOT=$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER")

echo "Waiting for Windows..."
READY=""
NOT_RUNNING=0
for i in {1..120}; do
  STATE=$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null)
  if [[ $STATE != "running" ]]; then
    NOT_RUNNING=$((NOT_RUNNING + 1))
    if (( NOT_RUNNING > 15 )); then
      echo "Container left 'running' state (crash or stop). Aborting." >&2
      omarchy-notification-send -u critical "Windows VM" "Container stopped unexpectedly"
      exit 1
    fi
    sleep 2
    continue
  fi
  NOT_RUNNING=0
  if docker logs --since "$BOOT" "$CONTAINER" 2>&1 | grep -qi "windows started successfully"; then
    READY=1
    break
  fi
  sleep 2
done

if [[ -z $READY ]]; then
  echo "Timeout: Windows did not become ready in time. Check: docker logs $CONTAINER" >&2
  omarchy-notification-send -u critical "Windows VM" "Not ready in time - try again or check logs"
  exit 1
fi

# Belt & suspenders: RDP port must actually accept connections
for i in {1..20}; do
  (exec 3<>/dev/tcp/127.0.0.1/3389) 2>/dev/null && break
  sleep 1
done

# Redirect every mounted removable medium as a drive named after its label
DRIVE_ARGS=()
for mnt in /run/media/$USER/*/; do
  [[ -d $mnt ]] || continue
  label=$(basename "$mnt")
  safe=$(echo "$label" | sed 's/[^A-Za-z0-9_-]/_/g')
  DRIVE_ARGS+=("/drive:${mnt%/},${safe}")
  echo "Redirecting: $label -> \\\\tsclient\\${safe}"
done

if (( ${#DRIVE_ARGS[@]} == 0 )); then
  echo "No removable drive detected under /run/media/$USER/ - connecting without drive redirection."
fi

# Detect display scale from Hyprland (same logic as omarchy-windows-vm)
HYPR_SCALE=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select (.focused == true) | .scale')
SCALE_PERCENT=$(echo "$HYPR_SCALE" | awk '{print int($1 * 100)}')
RDP_SCALE=""
if (( SCALE_PERCENT >= 170 )); then
  RDP_SCALE="/scale:180"
elif (( SCALE_PERCENT >= 130 )); then
  RDP_SCALE="/scale:140"
fi

# Initial window size = logical size of the focused monitor.
RDP_SIZE=""
MON_JSON=$(hyprctl monitors -j 2>/dev/null | jq -c '.[] | select (.focused == true)')
if [[ -n $MON_JSON ]]; then
  SIZE_STR=$(jq -nr --argjson m "$MON_JSON" '"\($m.width / $m.scale | floor)x\($m.height / $m.scale | floor)"')
  RDP_SIZE="/size:$SIZE_STR"
  echo "Initial RDP size: $RDP_SIZE"
fi

xfreerdp3 /u:"$WIN_USER" /p:"$WIN_PASS" /v:127.0.0.1:3389 \
  -grab-keyboard /sound /microphone /clipboard /cert:ignore \
  /title:"Windows VM - Omarchy" /dynamic-resolution /gfx:AVC444 \
  /floatbar:sticky:off,default:visible,show:fullscreen $RDP_SIZE $RDP_SCALE \
  "${DRIVE_ARGS[@]}"

if [[ $KEEP_ALIVE == "false" ]]; then
  echo ""
  echo "RDP session closed. Stopping Windows VM (graceful shutdown, can take up to 2 min)..."
  docker compose -f "$COMPOSE" down
  echo "Windows VM stopped."
else
  echo ""
  echo "RDP session closed. Windows VM is still running."
  echo "To stop it: omarchy-windows-vm stop"
fi
LAUNCHER_EOF

  chmod +x "$BIN_DIR/windows-vm-usb"
  bash -n "$BIN_DIR/windows-vm-usb"
  ok "windows-vm-usb deployed (-k to keep the VM running after closing)"

  # Menu entry "Windows"
  info "Configuring the 'Windows' menu entry"
  DESKTOP="$APPS_DIR/windows-vm.desktop"
  if [[ -f $DESKTOP ]]; then
    sed -i \
      -e 's|Exec=uwsm app -- omarchy-windows-vm launch|Exec=uwsm app -- windows-vm-usb|' \
      -e 's|Comment=Start Windows VM via Docker and connect with RDP$|Comment=Start Windows VM via Docker and connect with RDP (external drives redirected)|' \
      "$DESKTOP"
  else
    cat > "$DESKTOP" << EOF
[Desktop Entry]
Name=Windows
Comment=Start Windows VM via Docker and connect with RDP (external drives redirected)
Exec=uwsm app -- windows-vm-usb
Icon=windows
Terminal=false
Type=Application
Categories=System;Virtualization;
EOF
  fi
  rm -f "$APPS_DIR/windows-vm-usb.desktop"
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" 2>/dev/null || true
  ok "Menu entry 'Windows' now points to windows-vm-usb"
fi

# -----------------------------------------------------------------------------
# 2. winvm manager
# -----------------------------------------------------------------------------
if [[ $REMOVE == false ]]; then
  info "Deploying the winvm manager"
  mkdir -p "$BIN_DIR"

  cat > "$BIN_DIR/winvm" << 'WINVM_EOF'
#!/bin/bash

COMPOSE_FILE="$HOME/.config/windows/docker-compose.yml"
CONTAINER="omarchy-windows"
WEB_URL="http://127.0.0.1:8006"

have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "❌ $*" >&2; exit 1; }

require_config() {
	[[ -f $COMPOSE_FILE ]] || die "VM not configured. Run first: omarchy windows vm install"
}

ensure_docker() {
	systemctl is-active --quiet docker && return 0
	echo "Docker is stopped, starting..."
	sudo systemctl start docker 2>/dev/null || die "Could not start Docker. Try: sudo systemctl start docker"
}

run_compose() {
	if have docker-compose; then
		docker-compose -f "$COMPOSE_FILE" "$@"
	else
		docker compose -f "$COMPOSE_FILE" "$@"
	fi
}

state() { docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "absent"; }

get_conf() { awk -v k="$1:" '$1==k {gsub(/"/, "", $2); print $2; exit}' "$COMPOSE_FILE"; }

set_conf() { sed -i "s|^\([[:space:]]*$1:[[:space:]]*\).*|\1\"$2\"|" "$COMPOSE_FILE"; }

confirm() {
	if have gum; then
		gum confirm "$1"
	else
		read -r -p "$1 [y/N] " r
		[[ $r =~ ^[yY] ]]
	fi
}

total_ram_gb() { awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo; }

to_gb() {
	local v=${1^^}
	case $v in
	*M) echo $((${v%M} / 1024)) ;;
	*G) echo ${v%G} ;;
	*) echo $v ;;
	esac
}

prompt_value() {
	local header=$1 current=$2
	if have gum; then
		gum input --value="$current" --header="$header"
	else
		read -r -p "$header [$current] " r
		echo "${r:-$current}"
	fi
}

choose_option() {
	local header=$1 selected=$2
	shift 2
	if have gum; then
		printf '%s\n' "$@" | gum choose --selected="$selected" --header="$header"
	else
		local i=1 opt r
		for opt in "$@"; do
			echo "  $i) $opt"
			((i++))
		done
		read -r -p "Choice [1-$#]: " r
		if [[ $r =~ ^[0-9]+$ ]] && ((r >= 1 && r <= $#)); then
			echo "${!r}"
		fi
	fi
}

show_status() {
	require_config
	local st
	st=$(state)
	echo "── VM Windows ($CONTAINER) ─────────────"
	echo " Status      : $st"
	echo " RAM         : $(get_conf RAM_SIZE)  (host machine : $(total_ram_gb)G)"
	echo " CPU cores   : $(get_conf CPU_CORES)  (host machine : $(nproc))"
	echo " Disk        : $(get_conf DISK_SIZE)"
	echo " Web UI      : $WEB_URL"
	echo " RDP         : 127.0.0.1:3389  (connect : omarchy-windows-vm launch)"
	echo "────────────────────────────────────────"
}

apply_changes() {
	ensure_docker
	local st
	st=$(state)
	if [[ $st == running ]]; then
		confirm "The VM is currently running. Changes require restarting it (data is preserved). Continue?" || return 1
		echo "Stopping the VM (up to 2 min for a clean shutdown)..."
		run_compose down
	fi
	echo "Recreating the container with the new configuration..."
	run_compose up -d || die "Failed to start. Logs: docker logs $CONTAINER"
	echo ""
	echo "✅ Config applied! Windows starts (15-30 s)."
	echo "   Monitor: $WEB_URL"
}

change_ram() {
	require_config
	local total current new
	total=$(total_ram_gb)
	current=$(get_conf RAM_SIZE)

	new=$1
	if [[ -z $new ]]; then
		local opts=()
		for size in 2 4 8 16 32 64; do
			((size <= total)) && opts+=("${size}G")
		done
		(( ${#opts[@]} == 0 )) && die "Not enough free RAM on the host machine."
		new=$(choose_option "How much RAM for Windows? (current: $current)" "$current" "${opts[@]}")
		[[ -z $new ]] && echo "Cancelled." && return 1
	fi

	[[ $new =~ ^[0-9]+$ ]] && new="${new}G"
	[[ $new =~ ^[0-9]+[GMm]$ ]] || die "Invalid format: '$new'. Valid examples: 8G, 512M, 16"

	if (( $(to_gb "$new") > total )); then
		die "$new exceeds the host machine RAM (${total}G)."
	fi

	if [[ $new == "$current" ]]; then
		echo "RAM is already set to $new."
		return 0
	fi

	set_conf RAM_SIZE "$new"
	echo "RAM: $current → $new"
	apply_changes
}

change_cpu() {
	require_config
	local max current new
	max=$(nproc)
	current=$(get_conf CPU_CORES)

	new=$1
	while [[ -z $new ]]; do
		new=$(prompt_value "Number of CPU cores for Windows? (current: $current, max: $max)" "$current")
		[[ -z $new ]] && echo "Cancelled." && return 1
		if ! [[ $new =~ ^[0-9]+$ ]] || ((new < 1 || new > max)); then
			echo "Invalid value (1-$max)." >&2
			new=""
		fi
	done

	if ((new > max)); then
		die "$new cores requested but the host machine only has $max."
	fi

	if [[ $new == "$current" ]]; then
		echo "CPU cores are already set to $new."
		return 0
	fi

	set_conf CPU_CORES "$new"
	echo "CPU: $current → $new cores"
	apply_changes
}

change_disk() {
	require_config
	local current new cur_gb new_gb
	current=$(get_conf DISK_SIZE)
	cur_gb=$(to_gb "$current")

	new=$1
	if [[ -z $new ]]; then
		new=$(prompt_value "New disk size in GB? (current: $current)" "$current")
		[[ -z $new ]] && echo "Cancelled." && return 1
	fi

	[[ $new =~ ^[0-9]+$ ]] && new="${new}G"
	[[ $new =~ ^[0-9]+G$ ]] || die "Invalid format: '$new'. Valid example: 128G"

	new_gb=$(to_gb "$new")
	((new_gb < cur_gb)) && die "Shrinking impossible without data loss (${cur_gb}G → ${new_gb}G)."
	((new_gb > cur_gb)) || { echo "Size unchanged."; return 0; }

	local avail
	avail=$(( $(df "$HOME" | awk 'NR==2 {print int($4/1024/1024)}') + cur_gb ))
	((new_gb > avail)) && die "$new exceeds available disk space (~${avail}G usable)."

	set_conf DISK_SIZE "$new"
	echo "Disk: $current → $new"
	apply_changes
	echo ""
	echo "ℹ️  In Windows, now extend the C: partition:"
	echo "   Disk Management → right-click on C: → Extend Volume."
}

start_vm() {
	require_config
	ensure_docker
	if [[ $(state) == running ]]; then
		echo "The VM is already running."
		return 0
	fi
	echo "Starting the Windows VM..."
	run_compose up -d || die "Failed to start. Logs: docker logs $CONTAINER"
	echo ""
	echo "✅ VM started (15-30 s before Windows is ready)."
	echo "   Web UI: $WEB_URL"
	echo "   RDP connection: omarchy-windows-vm launch"
}

stop_vm() {
	require_config
	echo "Stopping the VM (up to 2 min for a clean shutdown)..."
	run_compose down
	echo "✅ VM stopped."
}

show_help() {
	cat <<EOF
winvm — Windows VM management (Omarchy / dockurr-windows)

Usage:
  winvm                    Interactive menu
  winvm status             Show status and configuration
  winvm ram [SIZE]         Change RAM (e.g. 8G, 16, 512M)
  winvm cpu [NB]           Change CPU cores (e.g. 4)
  winvm disk [SIZE]        Grow the disk (e.g. 128G, shrinking not possible)
  winvm start              Start the VM
  winvm stop               Stop the VM cleanly

Without a size argument, an interactive choice menu is shown.
Each change restarts the VM if it is running (data preserved).

Examples:
  winvm ram 16G            Allocate 16 GB of RAM
  winvm cpu 6              Allocate 6 CPU cores
EOF
}

interactive_menu() {
	require_config
	local choice
	while true; do
		clear
		show_status
		echo ""
		if have gum; then
			choice=$(gum choose "Change RAM" "Change CPU cores" "Grow disk" \
				"Start VM" "Stop VM" "Quit" --header="What do you want to change?") || break
		else
			select choice in "Change RAM" "Change CPU cores" "Grow disk" "Start VM" "Stop VM" "Quit"; do
				[[ -z $choice ]] && choice="Quit"
				break
			done
		fi
		case $choice in
		"Change RAM") change_ram ;;
		"Change CPU cores") change_cpu ;;
		"Grow disk") change_disk ;;
		"Start VM") start_vm ;;
		"Stop VM") stop_vm ;;
		*) clear; break ;;
		esac
		[[ $choice != Quit ]] && { echo ""; read -r -p "Press Enter to return to the menu..." _; }
	done
}

case ${1:-menu} in
menu)
	if have gum; then
		interactive_menu
	else
		show_status
	fi
	;;
status | s)
	show_status
	;;
ram | memoire | memory)
	shift
	change_ram "$@"
	;;
cpu | cores | coeurs)
	shift
	change_cpu "$@"
	;;
disk | disque)
	shift
	change_disk "$@"
	;;
start | up)
	start_vm
	;;
stop | down)
	stop_vm
	;;
help | --help | -h | help)
	show_help
	;;
*)
	echo "Unknown command: $1" >&2
	echo "" >&2
	show_help >&2
	exit 1
	;;
esac
WINVM_EOF

  chmod +x "$BIN_DIR/winvm"
  bash -n "$BIN_DIR/winvm"
  ok "winvm deployed (status | ram | cpu | disk | start | stop | interactive menu)"
fi

# -----------------------------------------------------------------------------
# 3. Omarchy menu entries (block "Setup > Windows VM")
# -----------------------------------------------------------------------------
read_menu_block() {
  cat <<BLOCK_EOF
$BLOCK_WINVM_START
  "setup.winvm": {
    "icon": "󰖳",
    "label": "Windows VM",
    "description": "RAM, CPU, disk, start/stop management (winvm)",
    "aliases": ["winvm", "vm", "windows"],
    "action": "omarchy-launch-or-focus-tui winvm"
  }
$BLOCK_WINVM_END
BLOCK_EOF
}

insert_menu_block() {
  local start end
  mkdir -p "$MENU_DIR"
  BLOCK_TMP=$(mktemp)
  read_menu_block > "$BLOCK_TMP"

  if [[ ! -f $MENU ]]; then
    { echo "{"; cat "$BLOCK_TMP"; echo "}"; } > "$MENU"
  elif grep -qF "$BLOCK_WINVM_START" "$MENU"; then
    start=$(grep -nF "$BLOCK_WINVM_START" "$MENU" | cut -d: -f1 | head -1)
    end=$(grep -nF "$BLOCK_WINVM_END" "$MENU" | cut -d: -f1 | head -1)
    if [[ -z $start || -z $end || $end -le $start ]]; then
      rm -f "$BLOCK_TMP"; warn "Inconsistent markers in $MENU."; return
    fi
    tmp=$(mktemp)
    head -n $((start - 1)) "$MENU" > "$tmp"
    cat "$BLOCK_TMP" >> "$tmp"
    tail -n +$((end + 1)) "$MENU" >> "$tmp"
    mv "$tmp" "$MENU"
  else
    close_line=$(grep -n "^}" "$MENU" | cut -d: -f1 | tail -1 || true)
    tmp=$(mktemp)
    if [[ -n ${close_line:-} ]]; then
      head -n $((close_line - 1)) "$MENU" > "$tmp"
      last_info=$(grep -vEn '^[[:space:]]*$|^[[:space:]]*//' "$tmp" | tail -1 || true)
      if [[ -n $last_info ]]; then
        last_num=${last_info%%:*}
        last_text=${last_info#*:}
        if [[ ! $last_text =~ ,[[:space:]]*$ && ! $last_text =~ [][{][[:space:]]*$ ]]; then
          sed -i "${last_num}s/[[:space:]]*\$/ ,/" "$tmp"
        fi
      fi
      cat "$BLOCK_TMP" >> "$tmp"
      tail -n +${close_line} "$MENU" >> "$tmp"
    else
      cp "$MENU" "$tmp"; cat "$BLOCK_TMP" >> "$tmp"; echo "}" >> "$tmp"
    fi
    mv "$tmp" "$MENU"
  fi
  rm -f "$BLOCK_TMP"
}

remove_menu_block() {
  [[ -f $MENU ]] || return 0
  if grep -qF "$BLOCK_WINVM_START" "$MENU"; then
    local s e
    s=$(grep -nF "$BLOCK_WINVM_START" "$MENU" | cut -d: -f1 | head -1)
    e=$(grep -nF "$BLOCK_WINVM_END" "$MENU" | cut -d: -f1 | head -1)
    if [[ -n $s && -n $e && $e -gt $s ]]; then
      tmp=$(mktemp)
      head -n $((s - 1)) "$MENU" > "$tmp"
      tail -n +$((e + 1)) "$MENU" >> "$tmp"
      mv "$tmp" "$MENU"
      sed -i ':a;N;$!ba;s/,\([[:space:]]*\n[[:space:]]*\)}/\1}/' "$MENU"
      ok "Block 'Setup > Windows VM' removed from the menu"
    fi
  fi
}

if [[ $REMOVE == false ]]; then
  info "Adding the 'Setup > Windows VM' entry to the Omarchy menu"
  insert_menu_block
  ok "Menu configured: Setup > Windows VM (interactive TUI)"
else
  remove_menu_block
fi

# -----------------------------------------------------------------------------
# 4. Debloat (auto-detected: skipped if the VM is not installed)
# -----------------------------------------------------------------------------
do_debloat() {
  command -v docker >/dev/null || die "docker not found"
  info "Generating the OEM payload ($OEM_DIR)"
  mkdir -p "$OEM_DIR"

  WINUTIL_JSON="$OEM_DIR/winutil.json"
  if [[ -f $SCRIPT_DIR/winutil-omarchy-vm.json ]]; then
    iconv -f UTF-16LE -t UTF-8 "$SCRIPT_DIR/winutil-omarchy-vm.json" \
      > "$WINUTIL_JSON" 2>/dev/null \
      || cp "$SCRIPT_DIR/winutil-omarchy-vm.json" "$WINUTIL_JSON"
    ok "Personal WinUtil config integrated (winutil.json)"
  fi

  cat > "$OEM_DIR/map-drives.cmd" << 'EOF'
@echo off
rem Map each \\tsclient\<label> share (drives redirected by RDP)
rem to an identical letter, if free. Rerun after plugging a drive.
for /f "delims=" %%D in ('dir /b \\tsclient 2^>nul') do (
  if not exist "%%D:\" net use "%%D:" "\\tsclient\%%D" /persistent:no >nul 2>&1 && echo   %%D: -^> \\tsclient\%%D
)
EOF

  cat > "$OEM_DIR/install.bat" << 'EOF'
@echo off
setlocal
cd /d "%~dp0"
echo === OEM Omarchy: debloat + drive access ===

echo [1/4] Registry tweaks (telemetry / ads / suggestions)...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338388Enabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338389Enabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SilentInstalledAppsEnabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableSoftLanding /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f >nul 2>&1

echo [2/4] RDP drive redirection explicitly allowed...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v fDisableCdm /t REG_DWORD /d 0 /f >nul 2>&1

echo [3/4] Logon task: mapping external \\tsclient drives...
schtasks /create /tn "MapTsclientDrives" /tr "\"%~dp0map-drives.cmd\"" /sc onlogon /rl highest /f >nul 2>&1

echo [4/4] WinUtil (custom config if present, otherwise Standard preset)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { & ([ScriptBlock]::Create((irm https://christitus.com/win))) -Config '%~dp0winutil.json' -Run } catch { & ([ScriptBlock]::Create((irm https://christitus.com/win))) -Preset Standard }"

echo === OEM done ===
exit /b 0
EOF
  ok "install.bat / map-drives.cmd generated"

  if grep -q ":/oem" "$COMPOSE"; then
    ok "Volume /oem already present in the compose file"
  else
    info "Adding the /oem volume to docker-compose.yml"
    sed -i "\|Windows:/shared|a\      - $HOME/.config/windows/oem:/oem" "$COMPOSE"
    grep -A4 "volumes:" "$COMPOSE" | sed 's/^/    /'
  fi

  if [[ $FRESH == true ]]; then
    info "FRESH mode: complete Windows reinstall"
    if [[ -f $DATA_IMG ]]; then
      BAK="$DATA_IMG.bak.$(date +%Y%m%d%H%M%S)"
      warn "Backing up data.img -> $BAK (renamed, instant)"
      mv "$DATA_IMG" "$BAK"
    fi
    docker compose -f "$COMPOSE" down >/dev/null 2>&1 || true
    docker compose -f "$COMPOSE" up -d
    ok "Reinstall launched: Windows download + auto install (~15-30 min)"
    info "Follow progress at http://localhost:8006 - nothing to do, the OEM will apply by itself."
  else
    info "Existing VM: immediate manual application possible"
    mkdir -p "$HOME/Windows"
    cp -f "$OEM_DIR/install.bat" "$OEM_DIR/map-drives.cmd" "$HOME/Windows/"
    [[ -f $WINUTIL_JSON ]] && cp -f "$WINUTIL_JSON" "$HOME/Windows/winutil.json"
    ok "Payload copied to the share: \\\\host.lan\\Data\\install.bat"
    cat << 'MSG'

  Inside the VM (admin session recommended):
    1. Open \\host.lan\Data in the explorer
    2. Double-click install.bat
       -> registry + logon task + WinUtil all apply by themselves

  For a future clean REINSTALL with everything applied:
    ./setup-windows-vm.sh --fresh     (overwrites data.img, auto backup)

MSG
  fi

  echo ""
  info "Debloat summary:"
  echo "  • OEM attached        -> $OEM_DIR mounted on /oem (C:\\OEM in the VM)"
  echo "  • Debloat            -> registry + silent WinUtil '$PRESET'"
  echo "  • External drives   -> RDP redirection + auto letter mapping (logon)"
  echo "  • New machine repro -> omarchy-windows-vm install THEN this script --fresh"
}

if [[ $REMOVE == false ]]; then
  if [[ -f $COMPOSE ]]; then
    do_debloat
  else
    warn "VM not installed: debloat skipped. Rerun after 'omarchy-windows-vm install'."
  fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
info "setup-windows-vm:"
if [[ $REMOVE == true ]]; then
  echo "  • Helpers & menus removed; the VM config (~/.config/windows) is kept."
else
  echo "  • 'Windows' menu launcher   -> VM + redirected external drives + DPI managed"
  echo "  • Manager             -> winvm (status | ram | cpu | disk | start | stop)"
  echo "  • Menu                -> Setup > Windows VM (interactive TUI)"
  echo "  • Keep the VM running -> windows-vm-usb -k | Stop: omarchy-windows-vm stop"
  echo "  • iLok-style licenses -> activate inside the VM itself"
  echo "  • Remove everything   -> ./setup-windows-vm.sh --remove"
fi
