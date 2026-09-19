#!/bin/bash
# =============================================================================
# Omarchy Custom - Setup Omarchy VM (QEMU/KVM + UEFI/OVMF)
# =============================================================================
# Provisions a virtual machine that boots the official Omarchy ISO, so you can
# install Omarchy *inside* Omarchy (disposable sandbox, tests, demos…). It
# mirrors the windows-vm / macos-vm modules:
#
#   1. Downloads the official Omarchy ISO into a cache dir and verifies its
#      SHA-256 (iso.omarchy.org, pinned version + checksum below).
#   2. Creates a QEMU/KVM VM: q35 + UEFI/OVMF, virtio-blk disk, virtio-net
#      (SSH port-forward), virtio-vga (3D accel via virgl), HDA audio,
#      optional 9p shared folder, optional USB / GPU (vfio) passthrough.
#   3. Deploys the launcher "omarchy-vm", a ".desktop" entry, the gum manager
#      "omarchy-vm-tui.sh" and the Omarchy menu entry "Setup > Omarchy VM"
#      (floating window rule + the SUPER+ALT+V guest-shortcuts toggle).
#
# Usage :
#   ./setup-omarchy-vm.sh               # deploy + provision the default VM (idempotent)
#   ./setup-omarchy-vm.sh --status      # show what is installed, change nothing
#   ./setup-omarchy-vm.sh --create-vm   # only create/resume the VM (used by the TUI)
#   ./setup-omarchy-vm.sh --vm NAME     # target another VM name
#   ./setup-omarchy-vm.sh --iso FILE    # use a local ISO instead of downloading
#   ./setup-omarchy-vm.sh --no-verify   # skip the SHA-256 check (local ISOs)
#   ./setup-omarchy-vm.sh --remove      # remove helpers/menus (keeps the VM dir + ISO cache)
#   ./setup-omarchy-vm.sh --purge       # --remove + delete the VM dir and the ISO cache
#
# First boot: the VM starts on the ISO (BOOT_ORDER=d). Install Omarchy, then
# mark the install as done (TUI: "Mark installation complete") or edit
# BOOT_ORDER="c" in ~/VMs/omarchy/vms/<name>/.vm-config.
# =============================================================================
# gui-run: reopen in a terminal when launched from a file manager. Optional, so
# the self-deployed copy in ~/.local/bin works without the repo tree.
GUI_RUN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"
# shellcheck disable=SC1090
[[ -f $GUI_RUN ]] && source "$GUI_RUN"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/keybindings.bash"  # kb_*: managed SUPER bindings
set -euo pipefail

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m !\033[0m $*"; }
die()   { warn "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Version of THIS script (the installer), not of the Omarchy ISO/VM it builds.
SCRIPT_VERSION="1.0.0"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
MENU_DIR="$HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
HYPR_DIR="$HOME/.config/hypr"
HYPRLAND="$HYPR_DIR/hyprland.lua"

# ─── Official Omarchy ISO (pinned; verify at https://omarchy.org/install) ───
OMARCHY_VERSION="4.0.4"
OMARCHY_ISO_URL="https://iso.omarchy.org/omarchy-${OMARCHY_VERSION}.iso"
OMARCHY_ISO_SIG_URL="${OMARCHY_ISO_URL}.sig"
OMARCHY_ISO_SHA256="ddeded2758c48318d201dfdac905ecb28f570441883f0c052ea3cd5d05acf92d"
ISO_CACHE="${OMARCHY_VM_ISO_CACHE:-$HOME/.cache/omarchy-vm}"

# ─── VM layout (mirrors ~/OSX-KVM of the macOS module) ──────────────────────
MOSQUITO_VM_ROOT="${MOSQUITO_VM_ROOT:-$HOME/VMs}"
VMS_ROOT="${OMARCHY_VM_ROOT:-$MOSQUITO_VM_ROOT/omarchy}"
VMS_DIR="$VMS_ROOT/vms"
DEFAULT_VM="omarchy"
DISK_SIZE="64G"
SHARED_DIR="${MOSQUITO_VM_ROOT}/shared"
# NVRAM file name inside each VM dir (written to .vm-config, read back by the
# generated launcher). Defined here so ensure_vm can reference it.
OVMF_VARS="OVMF_VARS.fd"

# Managed marker blocks (removal is --remove).
BLOCK_BEGIN='// >>> Omarchy_Custom_Scripts_OmarchyVm'
BLOCK_END='// <<< Omarchy_Custom_Scripts_OmarchyVm'
HYPR_BEGIN='-- >>> Omarchy_Custom_Scripts_OmarchyVm'
HYPR_END='-- <<< Omarchy_Custom_Scripts_OmarchyVm'
KEYBIND="SUPER + ALT + O"
MENU_KEY='setup.omarchyvm'

# ── Omarchy menu helpers (JSONC, marker-based) ─────────────────────────────
# strip_menu_key removes a JSON key's object by brace counting — anywhere in
# the file, so a legacy UNMARKED duplicate (from an older installer) is caught
# too. normalize_menu drops trailing commas so a removed key never leaves an
# invalid tail. Together with strip_marker_block they make insert_menu_block
# idempotent and impossible to corrupt (the bug that wiped menu entries: a
# duplicate `setup.macosvm` + a missing comma made the whole file unparseable).
strip_marker_block() {
  [[ -f $MENU ]] || return 0
  local tmp; tmp=$(mktemp)
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    skip {next}
    {print}
  ' "$MENU" > "$tmp" && mv "$tmp" "$MENU"
}

strip_menu_key() {
  [[ -f $MENU ]] || return 0
  local key="$1" tmp; tmp=$(mktemp)
  awk -v key="$key" '
    !skip && $0 ~ ("^[[:space:]]*\"" key "\"[[:space:]]*:[[:space:]]*\\{") {
      o=gsub(/\{/,"{"); c=gsub(/\}/,"}");
      depth=o-c;
      if (depth<=0) next
      skip=1; next
    }
    skip {
      o=gsub(/\{/,"{"); c=gsub(/\}/,"}");
      depth+=o-c;
      if (depth<=0) skip=0
      next
    }
    {print}
  ' "$MENU" > "$tmp" && mv "$tmp" "$MENU"
}

normalize_menu() {
  [[ -f $MENU ]] || return 0
  python3 - "$MENU" <<'PY' 2>/dev/null || true
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = re.sub(r',(\s*[}\]])', r'\1', t)
open(p, "w", encoding="utf-8").write(t)
PY
}


YES=0 STATUS_ONLY=0 REMOVE=false PURGE=false NO_VERIFY=false SETUP_ONLY=false CREATE_ONLY=false
VM_NAME="$DEFAULT_VM"
LOCAL_ISO=""
while (( $# )); do
  case "$1" in
    -y|--yes) YES=1 ;;
    --status) STATUS_ONLY=1 ;;
    --setup-only) SETUP_ONLY=true ;;  # deploy tools/menu/app only; no ISO/VM
    --create-vm) CREATE_ONLY=true ;;  # VM creation only (manager-driven): skip menu/rule
    --vm) shift; VM_NAME="${1:-$DEFAULT_VM}" ;;
    --vm=*) VM_NAME="${1#*=}" ;;
    --iso) shift; LOCAL_ISO="${1:-}" ;;
    --iso=*) LOCAL_ISO="${1#*=}" ;;
    --no-verify) NO_VERIFY=true ;;
    --remove|--uninstall) REMOVE=true ;;
    --purge) REMOVE=true; PURGE=true ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (supported: -y --status --setup-only --create-vm --vm NAME --iso FILE --no-verify --remove --purge)" >&2; exit 1 ;;
  esac
  shift
done
[[ -n $VM_NAME ]] || VM_NAME="$DEFAULT_VM"
ISO_PATH="$ISO_CACHE/omarchy-${OMARCHY_VERSION}.iso"

confirm() {
  local q="$1" r
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$q"
  else
    read -r -p "$q [y/N] " r
    [[ ${r:-n} =~ ^[yY] ]]
  fi
}

pkg_present() {
  case "$1" in
    qemu) command -v qemu-system-x86_64 >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1 ;;
    ovmf) [[ -n ${OVMF_CODE:-} && -n ${OVMF_VARS_SRC:-} ]] ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}

detect_ovmf() {
  local f
  OVMF_CODE=""; OVMF_VARS_SRC=""
  for f in /usr/share/edk2/x64/OVMF_CODE.4m.fd \
           /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
           /usr/share/edk2/x64/OVMF_CODE.fd \
           /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -f $f ]] && { OVMF_CODE="$f"; break; }
  done
  for f in /usr/share/edk2/x64/OVMF_VARS.4m.fd \
           /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd \
           /usr/share/edk2/x64/OVMF_VARS.fd \
           /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -f $f ]] && { OVMF_VARS_SRC="$f"; break; }
  done
}

total_ram_mb() { awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo; }
default_ram_mb() {
  local half=$(( $(total_ram_mb) / 2 / 1024 * 1024 ))
  (( half < 2048 )) && half=2048
  (( half > 16384 )) && half=16384
  echo "$half"
}
default_cores() {
  local c; c=$(nproc); (( c > 4 )) && c=4; (( c < 1 )) && c=1; echo "$c"
}
next_ssh_port() {
  local p=2222 c
  while :; do
    local used=0
    for c in "$VMS_DIR"/*/.vm-config; do
      [[ -f $c ]] || continue
      grep -qE "^SSH_PORT=$p$" "$c" && used=1
    done
    (( used == 0 )) && { echo "$p"; return; }
    p=$((p + 1))
  done
}

verify_iso() {
  [[ -f $ISO_PATH ]] || return 1
  echo "$OMARCHY_ISO_SHA256  $ISO_PATH" | sha256sum -c --status - 2>/dev/null
}

show_status() {
  echo "── Omarchy VM module ───────────────────────────────────────"
  echo " ISO version : $OMARCHY_VERSION"
  echo " ISO URL     : $OMARCHY_ISO_URL"
  if [[ -f $ISO_PATH ]]; then
    if verify_iso; then echo " ISO cache   : $ISO_PATH  (sha256 OK)"; else echo " ISO cache   : $ISO_PATH  (sha256 MISMATCH)"; fi
  else
    echo " ISO cache   : not downloaded ($ISO_PATH)"
  fi
  echo " VM root     : $VMS_ROOT"
  [[ -n ${OVMF_CODE:-} ]] && echo " OVMF code   : $OVMF_CODE" || echo " OVMF code   : missing (install edk2-ovmf)"
  echo " Helpers     :"
  local f
  for f in omarchy-vm omarchy-vm-tui.sh launch-omarchy-tui.sh; do
    [[ -x "$BIN_DIR/$f" ]] && echo "                ✓ $f" || echo "                ✗ $f"
  done
  echo " Menu block  : $( [[ -f $MENU ]] && grep -qF "$BLOCK_BEGIN" "$MENU" && echo present || echo absent )"
  echo " Window rule : $( [[ -f $HYPRLAND ]] && grep -qF "$HYPR_BEGIN" "$HYPRLAND" && echo present || echo absent )"
  echo " VMs         :"
  local dir found=0
  if [[ -d $VMS_DIR ]]; then
    for dir in "$VMS_DIR"/*/; do
      [[ -d $dir ]] || continue
      found=1
      local name; name="$(basename "$dir")"
      local pid="stopped"
      [[ -f "$dir/vm.pid" ]] && kill -0 "$(cat "$dir/vm.pid" 2>/dev/null)" 2>/dev/null && pid="running (pid $(cat "$dir/vm.pid"))"
      local size="n/a"; [[ -f "$dir/disk.qcow2" ]] && size=$(du -h "$dir/disk.qcow2" 2>/dev/null | cut -f1)
      echo "                • $name — $pid, disk $size"
    done
  fi
  (( found == 0 )) && echo "                (none yet)"
  echo "────────────────────────────────────────────────────────────"
}

# -----------------------------------------------------------------------------
# 0. Prerequisites / dependencies
# -----------------------------------------------------------------------------
[[ -d /usr/share/omarchy ]] || die "This script is meant for Omarchy."

detect_ovmf
MISSING=()
pkg_present qemu || MISSING+=(qemu-desktop)
[[ -n $OVMF_CODE && -n $OVMF_VARS_SRC ]] || MISSING+=(edk2-ovmf)
pkg_present gum || MISSING+=(gum)
pkg_present curl || MISSING+=(curl)

if [[ $STATUS_ONLY == 0 && $REMOVE == false && $SETUP_ONLY == false && ${#MISSING[@]} -gt 0 ]]; then
  warn "Missing dependencies: ${MISSING[*]}"
  if [[ $YES == 1 ]] || confirm "Install them now with pacman?"; then
    mq_sudo -v || die "Password required to install: ${MISSING[*]}"
    mq_sudo pacman -S --needed --noconfirm "${MISSING[@]}" || die "pacman failed."
    detect_ovmf
    ok "Dependencies installed."
  else
    die "Cannot continue without: ${MISSING[*]}"
  fi
elif [[ $SETUP_ONLY == true && ${#MISSING[@]} -gt 0 ]]; then
  warn "Not installing now (--setup-only): ${MISSING[*]} — the manager will need them to create/run the VM."
fi

if [[ ! -e /dev/kvm ]]; then
  warn "/dev/kvm is missing — the VM will run under slow TCG emulation."
  warn "Enable VT-x/AMD-V in the BIOS and load the kvm module for native speed."
fi

if [[ $STATUS_ONLY == 1 ]]; then
  show_status
  exit 0
fi

# -----------------------------------------------------------------------------
# 1. Removal
# -----------------------------------------------------------------------------
remove_menu_block() {
  [[ -f $MENU ]] || return 0
  strip_marker_block
  strip_menu_key "$MENU_KEY"
  normalize_menu
  ok "Block 'Setup > Omarchy VM' removed from the menu"
}

drop_block_from_file() {
  local file="$1" b="$2" e="$3"
  [[ -f $file ]] || return 0
  if grep -qF -- "$b" "$file"; then
    local sb se tmp
    sb=$(grep -nF -- "$b" "$file" | cut -d: -f1 | head -1)
    se=$(grep -nF -- "$e" "$file" | cut -d: -f1 | head -1)
    if [[ -n $sb && -n $se && $se -gt $sb ]]; then
      tmp=$(mktemp)
      head -n $((sb - 1)) "$file" > "$tmp"
      tail -n +$((se + 1)) "$file" >> "$tmp"
      mv "$tmp" "$file"
    fi
  fi
}

if [[ $REMOVE == true ]]; then
  info "Removing the Omarchy VM module (helpers / menus)"
  rm -f "$BIN_DIR/omarchy-vm" "$BIN_DIR/setup-omarchy-vm.sh" \
        "$BIN_DIR/omarchy-vm-tui" "$BIN_DIR/omarchy-vm-tui.sh" "$BIN_DIR/launch-omarchy-tui.sh" \
        "$BIN_DIR/omarchy-vm-focus"
  rm -f "$APPS_DIR"/omarchy-vm*.desktop
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" 2>/dev/null || true
  remove_menu_block
  drop_block_from_file "$HYPRLAND" "$HYPR_BEGIN" "$HYPR_END"
  kb_remove "$KEYBIND" || warn "Could not remove $KEYBIND"
  hyprctl reload >/dev/null 2>&1 || true
  if [[ $PURGE == true ]]; then
    rm -rf "$VMS_ROOT" "$ISO_CACHE" && ok "VMs ($VMS_ROOT) and ISO cache ($ISO_CACHE) deleted"
  else
    warn "VMs kept in $VMS_ROOT and the ISO cache in $ISO_CACHE (use --purge to delete them)."
  fi
  ok "Helpers, menu entry and window rule removed"
  echo ""
  info "setup-omarchy-vm: removed"
  exit 0
fi

# -----------------------------------------------------------------------------
# 2. ISO download + verification (cache dir)
# -----------------------------------------------------------------------------
# Searches the usual places for a locally-downloaded Omarchy ISO (e.g. the
# latest release already fetched by hand) and returns the highest-version one,
# or nothing. The pinned cache path is excluded — ensure_iso handles it.
find_latest_local_iso() {
  local d f
  local -a cands=()
  for d in "$ISO_CACHE" "$HOME/Downloads" "$HOME/Documents" "$HOME" "$PWD"; do
    [[ -d $d ]] || continue
    while IFS= read -r f; do
      [[ -f $f ]] || continue
      [[ "$(readlink -f "$f")" == "$(readlink -f "$ISO_PATH" 2>/dev/null || echo __none__)" ]] && continue
      cands+=("$f")
    done < <(find "$d" -maxdepth 2 -type f -iname 'omarchy-*.iso' 2>/dev/null)
  done
  ((${#cands[@]})) || return 1
  # Highest version first (version-aware sort on the basename).
  printf '%s\n' "${cands[@]}" | awk -F/ '{print $NF"\t"$0}' | sort -Vr | cut -f2- | head -1
}

ensure_iso() {
  mkdir -p "$ISO_CACHE"

  # Offer a locally-found Omarchy ISO before downloading the pinned one.
  if [[ -z $LOCAL_ISO ]]; then
    local found base
    if found="$(find_latest_local_iso)"; then
      base="$(basename "$found")"
      if [[ $YES == 1 ]]; then
        info "Found a local Omarchy ISO: $found"
        LOCAL_ISO="$found"
      else
        warn "A local Omarchy ISO was found: $found"
        if confirm "Use it ($base) to install the VM instead of downloading the pinned $OMARCHY_VERSION ISO?"; then
          LOCAL_ISO="$found"
        else
          info "Keeping the pinned $OMARCHY_VERSION ISO (download/cache)."
        fi
      fi
    fi
  fi

  if [[ -n $LOCAL_ISO ]]; then
    [[ -f $LOCAL_ISO ]] || die "Local ISO not found: $LOCAL_ISO"
    ISO_PATH="$(readlink -f "$LOCAL_ISO")"
    ok "Using local ISO: $ISO_PATH"
    # A local ISO of another version can't match the pinned checksum.
    if [[ $(basename "$ISO_PATH") != "omarchy-${OMARCHY_VERSION}.iso" ]]; then
      warn "Not the pinned $OMARCHY_VERSION ISO — skipping the pinned SHA-256 check."
      NO_VERIFY=true
    fi
    if [[ $NO_VERIFY == false ]]; then
      echo "$OMARCHY_ISO_SHA256  $ISO_PATH" | sha256sum -c --status - \
        || die "SHA-256 mismatch for $ISO_PATH (use --no-verify to override)."
      ok "SHA-256 verified."
    fi
    return 0
  fi

  if [[ -f $ISO_PATH ]] && verify_iso; then
    ok "ISO already cached and verified: $ISO_PATH"
    return 0
  fi

  if [[ -f $ISO_PATH ]]; then
    warn "Cached ISO failed verification — re-downloading."
    rm -f "$ISO_PATH"
  fi

  info "Downloading the official Omarchy $OMARCHY_VERSION ISO (~5.8 GB)"
  echo "     $OMARCHY_ISO_URL"
  echo "     -> $ISO_PATH"
  curl -L --fail --retry 3 --continue-at - --progress-bar -o "$ISO_PATH" "$OMARCHY_ISO_URL" \
    || die "ISO download failed."
  if [[ $NO_VERIFY == false ]]; then
    verify_iso || die "SHA-256 mismatch — refusing to use the downloaded ISO."
    ok "ISO downloaded and SHA-256 verified."
    info "Detached PGP signature available at $OMARCHY_ISO_SIG_URL"
  else
    warn "SHA-256 verification skipped (--no-verify)."
  fi
}
# VM creation is deferred to the manager when only the setup is requested.
if [[ $SETUP_ONLY == false ]]; then
  ensure_iso
fi

# -----------------------------------------------------------------------------
# 3. Deploy the helpers to ~/.local/bin
# -----------------------------------------------------------------------------
deploy_file() {
  local src="$1" dst="$2"
  [[ -f $src ]] || die "Missing file: $src"
  [[ "$(readlink -f "$src")" == "$(readlink -f "$dst" 2>/dev/null || echo __none__)" ]] && return 0
  install -m 0755 "$src" "$dst"
  bash -n "$dst" || die "Syntax error in $dst"
}

info "Deploying the Omarchy VM helpers to $BIN_DIR"
mkdir -p "$BIN_DIR"
# The setup script is deployed too, so the TUI can create VMs without the
# clone (its repo-relative deps are optional when run from ~/.local/bin).
for s in setup-omarchy-vm.sh omarchy-vm-tui.sh launch-omarchy-tui.sh omarchy-vm-focus; do
  deploy_file "$SCRIPT_DIR/$s" "$BIN_DIR/$s"
  ok "$s deployed"
done

cat > "$BIN_DIR/omarchy-vm" << 'WRAPPER_EOF'
#!/bin/bash
# Start an Omarchy VM in QEMU/KVM. Usage: omarchy-vm [VM_NAME]
set -euo pipefail
VMS_DIR="${OMARCHY_VM_ROOT:-${MOSQUITO_VM_ROOT:-$HOME/VMs}/omarchy}/vms"
name="${1:-}"
if [[ -z $name ]]; then
  [[ -f "$VMS_DIR/omarchy/.vm-config" ]] && name=omarchy
fi
if [[ -z $name ]]; then
  name="$(find "$VMS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -1 || true)"
fi
[[ -n $name && -f "$VMS_DIR/$name/.vm-config" ]] || { echo "No Omarchy VM found. Run: setup-omarchy-vm.sh" >&2; exit 1; }
exec "$VMS_DIR/$name/start-omarchy.sh"
WRAPPER_EOF
chmod +x "$BIN_DIR/omarchy-vm"
bash -n "$BIN_DIR/omarchy-vm"
ok "omarchy-vm launcher deployed"

# The Omarchy menu action and the app entry call
# `omarchy-launch-or-focus-tui omarchy-vm-tui`, which resolves the command on
# PATH — so a name WITHOUT the .sh is required (xdg-terminal-exec does not try
# extensions). This tiny wrapper execs the real TUI; without it the menu entry
# silently does nothing.
cat > "$BIN_DIR/omarchy-vm-tui" << 'TUI_WRAPPER_EOF'
#!/usr/bin/env bash
# Wrapper so `omarchy-launch-or-focus-tui omarchy-vm-tui` (Omarchy menu /
# app entry) finds the TUI under a PATH name without the .sh extension.
exec "$(dirname "$(readlink -f "$0")")/omarchy-vm-tui.sh" "$@"
TUI_WRAPPER_EOF
chmod +x "$BIN_DIR/omarchy-vm-tui"
bash -n "$BIN_DIR/omarchy-vm-tui"
ok "omarchy-vm-tui wrapper deployed (menu/app launch)"

# -----------------------------------------------------------------------------
# 4. VM creation (disk, OVMF vars, config, per-VM launcher, .desktop)
# -----------------------------------------------------------------------------
write_config() {
  local dir="$1" port="$2"
  cat > "$dir/.vm-config" <<EOF
# Omarchy VM configuration — edited by omarchy-vm-tui.sh, read by start-omarchy.sh
VM_NAME="$VM_NAME"
RAM_MB=$RAM_MB
CPU_CORES=$CPU_CORES
CPU_SOCKETS=1
DISK_IMG="disk.qcow2"
ISO_PATH="$ISO_PATH"
OVMF_CODE="$OVMF_CODE"
OVMF_VARS="OVMF_VARS.fd"
# "c" = boot the installed disk FIRST (OVMF falls back to the ISO when the disk
# is not bootable, so the very first boot still runs the installer); "d" = force
# the ISO first. Default "c" means: install once, and every reboot boots the
# installed Omarchy automatically.
BOOT_ORDER="c"
SHARED_FOLDER="off"
SHARED_DIR="$SHARED_DIR"
SSH_PORT=$port
DISPLAY_BACKEND="gtk"
# "off" (default) = std VGA at XRESxYRES, high fixed resolution, tileable;
# "on" = virtio-vga-gl (virgl 3D) — resolution then driven by the guest, which
# is low on a Wayland guest that does not follow the window. Toggle in the TUI.
GPU_ACCEL="off"
# Guest display resolution for the std-VGA path (see write_launcher): a high
# fixed mode keeps the guest crisp; the GTK window tiles freely and scales.
XRES=1920
YRES=1080
SPICE_PORT=5930
USB_PASSTHROUGH=()
VFIO_DEVICES=()
EOF
}

write_launcher() {
  local dir="$1"
  cat > "$dir/start-omarchy.sh" <<'LAUNCHER_EOF'
#!/bin/bash
# start-omarchy.sh — generated by setup-omarchy-vm.sh (regenerated on each run).
set -euo pipefail
VM_DIR="__VM_DIR__"
CONF="$VM_DIR/.vm-config"
[[ -f $CONF ]] || { echo "Missing VM config: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

VM_NAME="${VM_NAME:-__VM_NAME__}"
RAM="${RAM_MB:-8192}"
CORES="${CPU_CORES:-4}"
SOCKETS="${CPU_SOCKETS:-1}"
DISK_IMG="${DISK_IMG:-disk.qcow2}"
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS="${OVMF_VARS:-OVMF_VARS.fd}"
BOOT_ORDER="${BOOT_ORDER:-c}"
ISO_PATH="${ISO_PATH:-}"
SHARED_DIR="${SHARED_DIR:-${MOSQUITO_VM_ROOT:-$HOME/VMs}/shared}"
SHARED_FOLDER="${SHARED_FOLDER:-off}"
SSH_PORT="${SSH_PORT:-2222}"
DISPLAY_BACKEND="${DISPLAY_BACKEND:-gtk}"
GPU_ACCEL="${GPU_ACCEL:-off}"
SPICE_PORT="${SPICE_PORT:-5930}"

command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 not found (install qemu-desktop)" >&2; exit 1; }
[[ -f "$VM_DIR/$DISK_IMG" ]] || { echo "Disk image missing: $VM_DIR/$DISK_IMG" >&2; exit 1; }
[[ -f $OVMF_CODE ]] || { echo "OVMF code firmware missing: $OVMF_CODE (install edk2-ovmf)" >&2; exit 1; }
[[ -f "$VM_DIR/$OVMF_VARS" ]] || { echo "OVMF vars missing: $VM_DIR/$OVMF_VARS" >&2; exit 1; }

echo "========================================"
echo " Omarchy VM — $VM_NAME"
echo "========================================"
echo "Resources : $((RAM / 1024)) GB RAM, $CORES vCPU"
echo "Disk      : $DISK_IMG"
echo "SSH       : localhost:$SSH_PORT (enable sshd inside the guest first)"
[[ -n $ISO_PATH && -f $ISO_PATH ]] && echo "ISO       : $ISO_PATH"
echo ""
echo "Install   : pick 'Install' in the Omarchy ISO, then mark the install as"
echo "            done (TUI > Mark installation complete) to boot the disk."
echo "Mouse/key : Ctrl+Alt+G releases the pointer."
echo "========================================"
echo ""

if [[ -w /dev/kvm ]]; then
  CPU=host
else
  CPU=max
  echo "Note: /dev/kvm not usable — falling back to TCG emulation (slow)." >&2
fi

args=(
  -name "omarchy-${VM_NAME}"
  -machine q35,accel=kvm:tcg
  -cpu "$CPU"
  -smp "$CORES",cores="$CORES",sockets="$SOCKETS"
  -m "$RAM"
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
  -drive "if=pflash,format=raw,file=$VM_DIR/$OVMF_VARS"
  -device ich9-intel-hda -device hda-duplex
  -device qemu-xhci,id=xhci
  -device usb-kbd -device usb-tablet
  -boot "menu=on"
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
  -device "virtio-net-pci,netdev=net0"
)

# Disk: virtio-blk (fast, guest supports it), first or second in boot order.
disk_boot=1
[[ "$BOOT_ORDER" == "d" ]] && disk_boot=2
args+=(
  -drive "id=disk0,if=none,format=qcow2,cache=writeback,discard=unmap,file=$VM_DIR/$DISK_IMG"
  -device "virtio-blk-pci,drive=disk0,bootindex=$disk_boot"
)

# Installation ISO attached as a SATA CD-ROM (boot order drives selection).
if [[ -n $ISO_PATH && -f $ISO_PATH ]]; then
  cd_boot=2
  [[ "$BOOT_ORDER" == "d" ]] && cd_boot=1
  args+=(
    -device ich9-ahci,id=sata
    -drive "id=cd0,if=none,media=cdrom,readonly=on,format=raw,file=$ISO_PATH"
    -device "ide-cd,bus=sata.1,drive=cd0,bootindex=$cd_boot"
  )
fi

# ── Host display: resolution + DPI matching the monitor the VM opens on ──
# Uses the FOCUSED monitor (where the window will appear) and matches the
# host's apparent DPI: an external monitor keeps its own Hyprland scale, the
# internal panel uses 1.25. XRES/YRES then equal the host's LOGICAL size, so
# the guest content is the same apparent size as the host's windows.
detect_host_display() {
  command -v hyprctl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local name w h scale es
  read -r name w h scale < <(hyprctl monitors -j 2>/dev/null \
    | jq -r '[.[]|select(.focused==true)][0] // .[0] | "\(.name) \(.width) \(.height) \(.scale)"')
  [[ -n $name && $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || return 1
  es="${scale:-1}"
  [[ $name == eDP* ]] && es="1.25"
  XRES="$(awk -v w="$w" -v s="$es" 'BEGIN{v=(w/s)+0.5; if(v>2560)v=2560; printf "%d", v}')"
  YRES="$(awk -v h="$h" -v s="$es" 'BEGIN{v=(h/s)+0.5; if(v>1600)v=1600; printf "%d", v}')"
  return 0
}
detect_host_display || true

# Detect the fullscreen shortcut (description "Full screen" on the Omarchy
# defaults) so the recommendation notification can name it.
fullscreen_hint() {
  command -v hyprctl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local rec mask key out=""
  rec="$(hyprctl binds -j 2>/dev/null | jq -r '[.[]|select((.description // "")|test("full ?screen";"i"))][0] | "\(.modmask) \(.key)"')" || return 0
  mask="${rec%% *}"; key="${rec##* }"
  [[ -n $mask && -n $key && $key != "$rec" ]] || return 0
  (( mask & 64 )) && out="SUPER"
  (( mask & 4 ))  && out="${out:+$out + }CTRL"
  (( mask & 8 ))  && out="${out:+$out + }ALT"
  (( mask & 1 ))  && out="${out:+$out + }SHIFT"
  out="${out:+$out + }$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  printf '%s' "$out"
}
FS_KEY="$(fullscreen_hint)"

# Display. GTK: hide the "Machine / View" menubar and let the WM tile/resize
# the window freely (zoom-to-fit scales the guest into the window).
# Note: a Linux guest on a non-GNOME (Wayland) desktop does NOT auto-change its
# resolution when the window resizes, so we give it a high FIXED mode instead:
# GPU_ACCEL=off → std VGA at XRESxYRES (up to 2560x1600, no guest driver);
# GPU_ACCEL=on  → virtio-vga-gl (virgl 3D), resolution driven by the guest.
gtk_extra=""
[[ "$DISPLAY_BACKEND" == "gtk" ]] && gtk_extra=",show-menubar=off,zoom-to-fit=on"
if [[ "$DISPLAY_BACKEND" == "spice" ]]; then
  args+=( -device virtio-vga-gl -spice "port=${SPICE_PORT},addr=127.0.0.1,disable-ticketing=on" )
elif [[ "$GPU_ACCEL" == "on" ]]; then
  args+=( -device virtio-vga-gl -display "${DISPLAY_BACKEND},gl=on${gtk_extra}" )
else
  xr="${XRES:-1920}"; yr="${YRES:-1080}"
  args+=( -device "VGA,edid=on,xres=${xr},yres=${yr}" -global VGA.vgamem_mb=64 \
          -display "${DISPLAY_BACKEND}${gtk_extra}" )
fi

# 9p shared folder (guest: mount -t 9p -o trans=virtio hostshare /mnt).
if [[ "$SHARED_FOLDER" == "on" ]]; then
  mkdir -p "$SHARED_DIR"
  args+=( -virtfs "local,path=$SHARED_DIR,mount_tag=hostshare,security_model=mapped-xattr,id=hostshare" )
fi

# USB passthrough (entries "vendorid:productid", hex).
for dev in "${USB_PASSTHROUGH[@]:-}"; do
  [[ -z $dev ]] && continue
  vid="${dev%%:*}"; pid="${dev##*:}"
  args+=( -device "usb-host,vendorid=0x${vid},productid=0x${pid}" )
done

# PCI/GPU passthrough (vfio-pci host addresses, e.g. 0000:01:00.0).
for pci in "${VFIO_DEVICES[@]:-}"; do
  [[ -z $pci ]] && continue
  args+=( -device "vfio-pci,host=${pci}" )
done

echo $$ > "$VM_DIR/vm.pid"
trap 'rm -f "$VM_DIR/vm.pid"' EXIT

# Recommend fullscreen + explain the guest-shortcuts toggle (shortest form).
VM_TIP="Fullscreen: ${FS_KEY:-SUPER + F}.  Focus VM (shortcuts): SUPER + ALT + V."
if command -v omarchy-notification-send >/dev/null 2>&1; then
  omarchy-notification-send "Omarchy VM" "$VM_TIP" >/dev/null 2>&1 &
elif command -v notify-send >/dev/null 2>&1; then
  notify-send --app-name="Omarchy VM" "Omarchy VM" "$VM_TIP" >/dev/null 2>&1 &
fi

qemu-system-x86_64 "${args[@]}"
LAUNCHER_EOF
  sed -i -e "s|__VM_DIR__|$dir|g" -e "s|__VM_NAME__|$VM_NAME|g" "$dir/start-omarchy.sh"
  chmod +x "$dir/start-omarchy.sh"
  bash -n "$dir/start-omarchy.sh" || die "Syntax error in $dir/start-omarchy.sh"
}

write_desktop() {
  local name="$1"
  cat > "$APPS_DIR/omarchy-vm-$name.desktop" <<EOF
[Desktop Entry]
Name=Omarchy VM ($name)
Comment=Run Omarchy in QEMU/KVM ($name)
Exec=uwsm app -- omarchy-vm $name
Icon=omarchy
Terminal=false
Type=Application
Categories=System;Emulator;
EOF
  if [[ $name == "$DEFAULT_VM" ]]; then
    cp -f "$APPS_DIR/omarchy-vm-$name.desktop" "$APPS_DIR/omarchy-vm.desktop"
    sed -i 's/^Name=.*/Name=Omarchy VM/' "$APPS_DIR/omarchy-vm.desktop"
    sed -i 's/^Comment=.*/Comment=Run Omarchy in QEMU\/KVM/' "$APPS_DIR/omarchy-vm.desktop"
    sed -i 's/^Exec=.*/Exec=uwsm app -- omarchy-vm/' "$APPS_DIR/omarchy-vm.desktop"
  fi
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" 2>/dev/null || true
}

ensure_vm() {
  local dir="$VMS_DIR/$VM_NAME"
  mkdir -p "$dir"
  if [[ -f "$dir/disk.qcow2" ]]; then
    ok "VM '$VM_NAME' already exists ($dir)"
  else
    info "Creating VM disk '$VM_NAME' ($DISK_SIZE)"
    qemu-img create -f qcow2 "$dir/disk.qcow2" "$DISK_SIZE" >/dev/null
    ok "Disk created: $dir/disk.qcow2"
  fi
  if [[ ! -f "$dir/$OVMF_VARS" ]]; then
    cp "$OVMF_VARS_SRC" "$dir/OVMF_VARS.fd"
    ok "OVMF NVRAM initialised: $dir/OVMF_VARS.fd"
  fi
  if [[ ! -f "$dir/.vm-config" ]]; then
    RAM_MB="${OMARCHY_VM_RAM_MB:-$(default_ram_mb)}"
    CPU_CORES="${OMARCHY_VM_CPUS:-$(default_cores)}"
    write_config "$dir" "$(next_ssh_port)"
    ok "Configuration written: $dir/.vm-config"
  else
    ok "Keeping existing configuration: $dir/.vm-config"
  fi
  write_launcher "$dir"
  ok "Launcher generated: $dir/start-omarchy.sh"
  write_desktop "$VM_NAME"
  ok "Desktop entry: omarchy-vm-$VM_NAME.desktop"
}

if [[ $SETUP_ONLY == false ]]; then
  ensure_vm
fi

# -----------------------------------------------------------------------------
# 5. Omarchy menu entry ("Setup > Omarchy VM")
# -----------------------------------------------------------------------------
read_menu_block() {
  cat <<BLOCK_EOF
$BLOCK_BEGIN
  "setup.omarchyvm": {
    "icon": "\ue900",
    "iconFont": "omarchy",
    "label": "Omarchy VM",
    "description": "Omarchy inside Omarchy (QEMU/KVM) — create, launch, manage",
    "aliases": ["omarchy", "vm"],
    "action": "omarchy-launch-or-focus-tui omarchy-vm-tui"
  },
$BLOCK_END
BLOCK_EOF
}

insert_menu_block() {
  mkdir -p "$MENU_DIR"
  # Drop any previous marked block and any legacy unmarked key first, so we
  # never end up with a duplicate (which is what corrupted the file).
  strip_marker_block
  strip_menu_key "$MENU_KEY"
  normalize_menu

  local block_tmp; block_tmp=$(mktemp)
  read_menu_block > "$block_tmp"

  if [[ ! -f $MENU ]]; then
    { echo "{"; cat "$block_tmp"; echo "}"; } > "$MENU"
  else
    # Insert right after the opening brace: the block ends with a comma, so
    # whatever key follows stays valid, and normalize_menu cleans the tail.
    local open_line; open_line=$(grep -nE '^[[:space:]]*\{[[:space:]]*$' "$MENU" | cut -d: -f1 | head -1)
    if [[ -z $open_line ]]; then
      rm -f "$block_tmp"; warn "Could not find the opening brace in $MENU — entry not added."; return
    fi
    local tmp; tmp=$(mktemp)
    head -n "$open_line" "$MENU" > "$tmp"
    cat "$block_tmp" >> "$tmp"
    tail -n +$((open_line + 1)) "$MENU" >> "$tmp"
    mv "$tmp" "$MENU"
  fi
  rm -f "$block_tmp"
  normalize_menu
}

upsert_block_file() {
  local file="$1" b="$2" e="$3" body="$4" tmp
  mkdir -p "$(dirname "$file")"
  [[ -f $file ]] || : > "$file"
  if grep -qF -- "$b" "$file"; then
    local sb se
    sb=$(grep -nF -- "$b" "$file" | cut -d: -f1 | head -1)
    se=$(grep -nF -- "$e" "$file" | cut -d: -f1 | head -1)
    if [[ -n $sb && -n $se && $se -gt $sb ]]; then
      tmp=$(mktemp)
      head -n $((sb - 1)) "$file" > "$tmp"
      printf '%s\n%s\n' "$body" "$e" >> "$tmp"
      tail -n +$((se + 1)) "$file" >> "$tmp"
      mv "$tmp" "$file"
    fi
  else
    printf '\n%s\n%s\n' "$body" "$e" >> "$file"
  fi
}

omarchy_rule_body() {
  cat <<'BODY'
-- >>> Omarchy_Custom_Scripts_OmarchyVm
-- Omarchy VM Manager TUI: floating centered window (setup-omarchy-vm.sh)
o.window("org.omarchy.omarchy-vm-tui", { float = true, center = true, size = { 800, 600 } })
-- Omarchy VM keyboard: toggle where SUPER+… goes (the "focus").
-- NORMAL (default): the host keeps ALL its shortcuts, so you can fullscreen
-- the VM window (SUPER + F), move it, switch workspaces, etc.
-- SUPER + ALT + V: focus the VM — every SUPER+… shortcut goes to the in-VM
-- Omarchy instead; press it again to focus the host. Every press pops a
-- compositor notification (hyprctl notify, drawn on top even in fullscreen)
-- saying where the focus is. Both Omarchy shortcut sets therefore coexist.
o.bind("SUPER + ALT + V", "Omarchy VM: focus the VM / host shortcuts", "omarchy-vm-focus")
hl.define_submap("omarchy-vm", function()
  o.bind("SUPER + ALT + V", "Omarchy VM: focus the VM / host shortcuts", "omarchy-vm-focus")
end)
BODY
}

# Section 5 is the SETUP wiring (menu entry, window rule). When the
# manager creates an EXTRA VM it passes --create-vm: the wiring is already in
# place, so re-running it (and its hyprctl reload, which flickers the session)
# is skipped — that reload is what caused the "micro crash" on VM creation.
if [[ $CREATE_ONLY == false ]]; then
  info "Configuring the 'Setup > Omarchy VM' entry in the Omarchy menu"
  insert_menu_block
  ok "Menu configured: Setup > Omarchy VM"

  if [[ -f $HYPRLAND ]]; then
    upsert_block_file "$HYPRLAND" "$HYPR_BEGIN" "$HYPR_END" "$(omarchy_rule_body)"
    ok "Window rule added: org.omarchy.omarchy-vm-tui floats centered (800x600)"
  fi

  # No keybinding is registered on purpose: the VM manager is reached from the
  # Omarchy menu (Setup > Omarchy VM) or the app entry — no global shortcut.
  hyprctl reload >/dev/null 2>&1 || true
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
info "setup-omarchy-vm:"
if [[ $SETUP_ONLY == true ]]; then
  echo "  • Setup only -> the manager, its menu entry and window rule are installed."
  echo "  • No ISO downloaded and no VM created (by design)."
  echo ""
  echo "  ► Continue in the Omarchy VM manager:"
  echo "      Omarchy menu → Setup → Omarchy VM"
  echo "    There you create the VM; it downloads the Omarchy ISO and builds the disk."
  echo ""
  echo "  • Remove -> ./setup-omarchy-vm.sh --remove [--purge]"
  exit 0
fi
if [[ $NO_VERIFY == true ]]; then
  echo "  • ISO        -> $ISO_PATH (verification skipped)"
else
  echo "  • ISO        -> $ISO_PATH (SHA-256 verified, cached)"
fi
echo "  • VM         -> $VMS_DIR/$VM_NAME (disk.qcow2, UEFI/OVMF, virtio)"
echo "  • Launcher   -> omarchy-vm [$VM_NAME]   (or the 'Omarchy VM' app entry)"
echo "  • Manager    -> Setup > Omarchy VM (or the 'Omarchy VM' app entry)"
echo "  • First boot -> install Omarchy from the ISO, then 'Mark installation complete'"
echo "  • Remove     -> ./setup-omarchy-vm.sh --remove [--purge]"
