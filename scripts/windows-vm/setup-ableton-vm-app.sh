#!/bin/bash
# =============================================================================
# Omarchy Custom - Ableton Live launcher (Windows VM) in the Omarchy apps
# =============================================================================
# Once Ableton is installed in the Windows VM, this script creates:
#   1. The wrapper ~/.local/bin/ableton-vm:
#      starts the VM if needed, waits until it is ready, then opens Ableton
#      as a remote application (RemoteApp/RAIL) via xfreerdp3 - the Ableton
#      window appears as a real local window, not the full desktop.
#   2. The "Ableton Live (VM)" menu entry (~/.local/share/applications)
#      visible in the Omarchy launcher (Super+Space).
#
# Usage:
#   ./setup-ableton-vm-app.sh                      # detect/ask for the path
#   ./setup-ableton-vm-app.sh "C:\...\Live.exe"    # explicit path
#
# The exe path is stored in ~/.config/windows/ableton.conf ;
# rerun the script (or edit this file) to change the version.
#
# RDP NOTE: Windows only admits one session per user. Launching Ableton
# while the full desktop is open in another RDP window will take over that
# session (the desktop window closes). The VM stays on after Ableton closes;
# to shut it down: winvm stop or windows-vm-usb.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # gui-run: reopen in a terminal when launched from a file manager
set -euo pipefail

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m !\033[0m $*"; }
die()   { warn "$*"; exit 1; }

COMPOSE="$HOME/.config/windows/docker-compose.yml"
CONF_DIR="$HOME/.config/windows"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
CONF="$CONF_DIR/ableton.conf"

[[ -f $COMPOSE ]] || die "VM not installed: run 'omarchy-windows-vm install' first"
command -v xfreerdp3 >/dev/null || die "xfreerdp3 not found"

mkdir -p "$CONF_DIR" "$BIN_DIR" "$APPS_DIR"

# -----------------------------------------------------------------------------
# 1. Path of the Ableton executable in the VM
# -----------------------------------------------------------------------------
EXE="${1:-}"
if [[ -z $EXE && -f $CONF ]]; then
  EXE=$(grep '^EXE=' "$CONF" | cut -d= -f2-)
fi

if [[ -z $EXE ]]; then
  DEFAULT_EXE='C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe'
  info "Ableton exe path inside the VM (verify in the VM: right-click the shortcut > Properties > Target)"
  if command -v gum >/dev/null 2>&1; then
    EXE=$(gum input --placeholder="Windows path of the exe" --value="$DEFAULT_EXE" --header="Path of Ableton.exe in the VM")
  else
    read -rp "Path [$DEFAULT_EXE]: " EXE
    [[ -z $EXE ]] && EXE="$DEFAULT_EXE"
  fi
  [[ -z $EXE ]] && die "Cancelled."
fi

printf 'EXE=%s\n' "$EXE" > "$CONF"
ok "Path saved: $EXE"

# -----------------------------------------------------------------------------
# 2. ableton-vm wrapper
# -----------------------------------------------------------------------------
info "Deploying the wrapper $BIN_DIR/ableton-vm"

cat > "$BIN_DIR/ableton-vm" << LAUNCHER_EOF
#!/bin/bash
# Launches Ableton Live (Windows VM) as a RemoteApp via RDP.
# Configured exe path: see $CONF

COMPOSE="$HOME/.config/windows/docker-compose.yml"
CONTAINER="omarchy-windows"
EXE='$EXE'

STATE=\$(docker inspect --format='{{.State.Status}}' "\$CONTAINER" 2>/dev/null)

if [[ \$STATE != "running" ]]; then
  echo "Starting the Windows VM..."
  omarchy-notification-send -g "Starting Windows VM" "Ableton will start after boot" -t 15000 || true
  docker compose -f "\$COMPOSE" up -d || { omarchy-notification-send -u critical "Windows VM" "Failed to start"; exit 1; }
fi

BOOT=\$(docker inspect --format='{{.State.StartedAt}}' "\$CONTAINER")

echo "Waiting for Windows..."
READY=""
for i in {1..120}; do
  STATE=\$(docker inspect --format='{{.State.Status}}' "\$CONTAINER" 2>/dev/null)
  [[ \$STATE == "running" ]] || { sleep 2; continue; }
  if docker logs --since "\$BOOT" "\$CONTAINER" 2>&1 | grep -qi "windows started successfully"; then READY=1; break; fi
  sleep 2
done
[[ -n \$READY ]] || { omarchy-notification-send -u critical "Windows VM" "Not ready in time"; exit 1; }

for i in {1..20}; do
  (exec 3<>/dev/tcp/127.0.0.1/3389) 2>/dev/null && break
  sleep 1
done

WIN_USER=\$(grep "USERNAME:" "\$COMPOSE" | sed 's/.*USERNAME: "\(.*\)"/\1/')
WIN_PASS=\$(grep "PASSWORD:" "\$COMPOSE" | sed 's/.*PASSWORD: "\(.*\)"/\1/')
WIN_USER=\${WIN_USER:-docker}
WIN_PASS=\${WIN_PASS:-admin}

HYPR_SCALE=\$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select (.focused == true) | .scale')
SCALE_PERCENT=\$(echo "\$HYPR_SCALE" | awk '{print int(\$1 * 100)}')
RDP_SCALE=""
if (( SCALE_PERCENT >= 170 )); then RDP_SCALE="/scale:180"
elif (( SCALE_PERCENT >= 130 )); then RDP_SCALE="/scale:140"; fi

exec xfreerdp3 /u:"\$WIN_USER" /p:"\$WIN_PASS" /v:127.0.0.1:3389 \\
  -grab-keyboard /sound /microphone /clipboard /cert:ignore \\
  /title:"Ableton Live - VM" /dynamic-resolution /gfx:AVC444 \\
  "/app:program:\$EXE" \$RDP_SCALE
LAUNCHER_EOF

chmod +x "$BIN_DIR/ableton-vm"
bash -n "$BIN_DIR/ableton-vm"
ok "ableton-vm deployed"

# -----------------------------------------------------------------------------
# 3. Omarchy application entry
# -----------------------------------------------------------------------------
info "Creating the menu entry"
DESK="$APPS_DIR/ableton-vm.desktop"
cat > "$DESK" << EOF
[Desktop Entry]
Name=Ableton Live (VM)
Comment=Launch Ableton Live in the Windows VM (RemoteApp)
Exec=uwsm app -- ableton-vm
Icon=windows
Terminal=false
Type=Application
Categories=AudioVideo;Audio;
StartupWMClass=Ableton Live - VM
EOF
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" 2>/dev/null || true
ok "Entry 'Ableton Live (VM)' added to the Omarchy launcher"

echo ""
info "Usage: Super+Space -> 'Ableton Live (VM)' (or: ableton-vm)"
warn "If the exe path changes after an Ableton update, rerun this script with the new path."
