#!/bin/bash
# =============================================================================
# mosquitOmarchy - Setup Omarchy VM (QEMU/KVM + UEFI/OVMF)
# =============================================================================
# Provisions a virtual machine that boots the official Omarchy ISO, so you can
# install Omarchy *inside* Omarchy (disposable sandbox, tests, demos…). It
# mirrors the windows-vm / macos-vm modules:
#
#   1. Downloads the latest official Omarchy ISO into a cache dir and verifies
#      its SHA-256 (iso.omarchy.org; the version is resolved from the latest
#      GitHub release, with a local ISO used only when it is current).
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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$HERE/../../../lib"
# Deployed copy in ~/.local/bin: follow the mosquitomarchy-actions symlink back
# into the checkout so mq_sudo/kb_* are still available. Without this, the copy
# ran with undefined helpers (only --remove/deps use them, but that is exactly
# when it broke).
if [[ ! -d $LIB_DIR ]]; then
  _actions="$(command -v mosquitomarchy-actions 2>/dev/null || echo "$HOME/.local/bin/mosquitomarchy-actions")"
  _repo="$(dirname "$(readlink -f "$_actions" 2>/dev/null)")/../.."
  [[ -d "$_repo/code/lib" ]] && LIB_DIR="$_repo/code/lib"
fi
GUI_RUN="$LIB_DIR/gui-run.bash"
# shellcheck disable=SC1090
[[ -f $GUI_RUN ]] && source "$GUI_RUN"
if [[ -f "$LIB_DIR/elevate.bash" ]]; then
  source "$LIB_DIR/elevate.bash"  # mq_sudo: native pkexec prompt when not root
else
  mq_sudo() { sudo "$@"; }
fi
if [[ -f "$LIB_DIR/keybindings.bash" ]]; then
  source "$LIB_DIR/keybindings.bash"  # kb_*: managed SUPER bindings
else
  kb_remove() { :; }
fi
set -euo pipefail

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m !\033[0m $*"; }
die()   { warn "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Save each VM's shared files before --purge deletes the VM dirs.
BACKUP_SHARED_LIB="$SCRIPT_DIR/backup-vm-shared.bash"
# shellcheck source=backup-vm-shared.bash
[[ -f $BACKUP_SHARED_LIB ]] && source "$BACKUP_SHARED_LIB"
# Version of THIS script (the installer), not of the Omarchy ISO/VM it builds.
SCRIPT_VERSION="1.0.0"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
MENU_DIR="$HOME/.config/omarchy/extensions"
MENU="$MENU_DIR/omarchy-menu.jsonc"
HYPR_DIR="$HOME/.config/hypr"
HYPRLAND="$HYPR_DIR/hyprland.lua"

# ─── Official Omarchy ISO (latest release, resolved at runtime) ─────────────
# There is deliberately no pinned version/checksum: the latest non-prerelease
# GitHub release is the source of truth, and the server publishes a matching
# <iso>.sha256 which is verified when reachable.
OMARCHY_RELEASES_API="https://api.github.com/repos/basecamp/omarchy/releases/latest"
ISO_BASE_URL="https://iso.omarchy.org"
ISO_CACHE="${OMARCHY_VM_ISO_CACHE:-$HOME/.cache/omarchy-vm}"
OMARCHY_VERSION=""
OMARCHY_ISO_URL=""
OMARCHY_ISO_SIG_URL=""
ISO_PATH=""

# ─── VM layout ─────────────────────────────────────────────────────────────
# Flat: VMs live directly in $MOSQUITO_VM_ROOT (<name>/), shared/ beside them.
# (The old nested omarchy/vms/<name> layout is moved up once, automatically.)
MOSQUITO_VM_ROOT="${MOSQUITO_VM_ROOT:-$HOME/VMs}"
VMS_ROOT="${OMARCHY_VM_ROOT:-$MOSQUITO_VM_ROOT}"
VMS_DIR="$VMS_ROOT"
migrate_flat_layout(){
  local old="$MOSQUITO_VM_ROOT/omarchy/vms" d name
  [[ -d $old ]] || return 0
  # An explicit OMARCHY_VM_ROOT keeps its own tree: never move under it.
  [[ -n ${OMARCHY_VM_ROOT:-} ]] && return 0
  local moved=0
  for d in "$old"/*/; do
    [[ -d $d ]] || continue
    name="$(basename "$d")"
    if [[ -e "$VMS_DIR/$name" ]]; then
      warn "Flat move skipped (already exists): $VMS_DIR/$name"
      continue
    fi
    mv "$d" "$VMS_DIR/$name" && moved=1 \
      && ok "VM moved to the flat layout: $VMS_DIR/$name" \
      || warn "Could not move $d — move it by hand."
  done
  if ((moved)); then
    # Launchers carry their absolute dir: regenerate every moved VM.
    local cfg vm
    for d in "$VMS_DIR"/*/; do
      [[ -f "$d/.vm-config" ]] || continue
      vm="$(basename "$d")"
      # Only VMs that came from the old tree (their launcher still points there).
      grep -qF "$old/$vm" "$d/start-omarchy.sh" 2>/dev/null || continue
      VM_NAME="$vm" write_launcher "$d" \
        && ok "Launcher regenerated: $d/start-omarchy.sh" \
        || warn "Regenerate by hand: setup-omarchy-vm.sh --vm $vm"
    done
  fi
  rmdir "$old" "$MOSQUITO_VM_ROOT/omarchy" 2>/dev/null || true
}
DEFAULT_VM="omarchy"
DISK_SIZE="64G"
# Legacy shared-folder paths, kept only for migrating existing VMs.
LEGACY_SHARED_DIR="${MOSQUITO_VM_ROOT}/shared"
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
    # Package names are not always binary names. wl-clipboard ships wl-copy /
    # wl-paste; testing `command -v wl-clipboard` always said "missing", then
    # pacman answered "up to date -- skipping" on every run.
    wl-clipboard) command -v wl-copy >/dev/null 2>&1 && command -v wl-paste >/dev/null 2>&1 ;;
    python) command -v python3 >/dev/null 2>&1 ;;
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
  # Explicit: when nothing is found the loop's last test is false, and the
  # caller runs under `set -e`. That silently aborted --remove/--status on a
  # machine that no longer has edk2-ovmf installed.
  return 0
}

total_ram_mb() { awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo; }
# Default VM sizing.
#
# Both figures were raised because they were sized for a machine nobody runs a
# DAW class guest on. The CPU cap of 4 and the RAM cap of 16 GB are what a
# lightly-used guest needs; a guest running Ableton or REAPER next to the host
# needs more, and a guest that gets too little does not fail — it thrashes, or
# the host audio thread gets preempted by the guest, which is far harder to
# diagnose than "out of memory".
#
# RAM: half of what the machine has, rounded down to whole GiB, floor 4 GiB,
# ceiling 32 GiB. Half leaves the host room to keep its own audio path and a
# DAW; giving the guest everything would starve it.
#
# CORES: the PHYSICAL core count, not the thread count. `nproc` reports
# hyperthreads, and a VCPU pinned to a sibling hyperthread does not get a full
# core of throughput — it shares execution units with the host's other vCPU on
# that core. So the guest is sized on physical cores, and half of them is the
# default: an audio guest does not scale linearly past that, and leaving half
# for the host is what keeps the host responsive while the guest is running.
default_ram_mb() {
  local half=$(( $(total_ram_mb) / 2 / 1024 * 1024 ))
  (( half < 4096 )) && half=4096
  (( half > 32768 )) && half=32768
  echo "$half"
}

# Physical cores, derived from the CPU topology rather than trusting nproc.
# Falls back to nproc when the topology is unreadable, and to 2 when even that
# comes back empty.
physical_cores() {
  local n=""
  if [[ -r /proc/cpuinfo ]]; then
    # "cpu cores" is absent on some kernels/architectures; count unique
    # (physical id, core id) pairs instead, which is what it means anyway.
    n=$(awk '/^physical id/{p=$4} /^core id/{print p":"$4}' /proc/cpuinfo 2>/dev/null | sort -u | grep -c .)
  fi
  if [[ -z $n || $n == 0 ]]; then
    n=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2); c=$2} /^Socket\(s\)/{gsub(/ /,"",$2); s=$2} END{print c*s}')
  fi
  [[ -z $n || $n == 0 ]] && n=$(nproc 2>/dev/null || echo 2)
  echo "$n"
}

default_cores() {
  local physical c
  physical="$(physical_cores)"
  # Half the physical cores, floor 2, ceiling 8. Capped at 8 deliberately: past
  # that an x86-64 guest spends its time in the emulator's own overhead rather
  # than doing work, and the host keeps more of the machine.
  c=$(( physical / 2 ))
  (( c < 2 )) && c=2
  (( c > 8 )) && c=8
  echo "$c"
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

iso_version_from_name() {
  local b
  b="$(basename "$1")"
  [[ $b =~ ^omarchy-([0-9][0-9A-Za-z._-]*)\.iso$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# version_is_newer A B — true when A is a newer version than B.
version_is_newer() {
  [[ $1 != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# latest_omarchy_version — the latest non-prerelease release tag, cached for an
# hour so listing/creating VMs does not hammer the GitHub API. Falls back to the
# last good cache when offline.
latest_omarchy_version() {
  local cache="$ISO_CACHE/latest-version" now ts v=""
  now="$(date +%s)"
  if [[ -f $cache ]]; then
    ts="$(stat -c %Y "$cache" 2>/dev/null || echo 0)"
    if (( now - ts >= 0 && now - ts < 3600 )); then
      cat "$cache"
      return 0
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    if command -v jq >/dev/null 2>&1; then
      v="$(curl -fsSL --max-time 15 "$OMARCHY_RELEASES_API" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)"
    else
      v="$(curl -fsSL --max-time 15 "$OMARCHY_RELEASES_API" 2>/dev/null \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    fi
    v="${v#v}"; v="${v#V}"
    if [[ $v =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
      mkdir -p "$ISO_CACHE" 2>/dev/null || true
      printf '%s\n' "$v" > "$cache" 2>/dev/null || true
      printf '%s\n' "$v"
      return 0
    fi
  fi
  [[ -f $cache ]] && { cat "$cache"; return 0; }
  return 1
}

# configure_latest_iso resolves the version + URLs for this run. No pinned
# version: the latest release is the default, and a local ISO is only a fallback.
configure_latest_iso() {
  local v found
  if v="$(latest_omarchy_version)"; then
    OMARCHY_VERSION="$v"
  elif found="$(find_latest_local_iso)"; then
    OMARCHY_VERSION="$(iso_version_from_name "$found" || true)"
    [[ -n $OMARCHY_VERSION ]] || die "Could not read the version of the local ISO: $found"
    LOCAL_ISO="$found"
    warn "GitHub unreachable — using the newest local ISO ($found, Omarchy $OMARCHY_VERSION)."
  else
    die "Could not determine the latest Omarchy release (GitHub unreachable and no local ISO). Pass --iso FILE."
  fi
  OMARCHY_ISO_URL="$ISO_BASE_URL/omarchy-${OMARCHY_VERSION}.iso"
  OMARCHY_ISO_SIG_URL="${OMARCHY_ISO_URL}.sig"
  ISO_PATH="$ISO_CACHE/omarchy-${OMARCHY_VERSION}.iso"
}

# iso_checksum_ok <iso> [version] — verify against the server's <iso>.sha256.
# The published checksum is downloaded once and cached next to the ISO. When it
# cannot be fetched (offline/first run), verification is skipped rather than
# failing the whole install; the file is still a release ISO chosen by version.
iso_checksum_ok() {
  local iso="$1" ver="${2:-}" sumfile sum want got
  [[ -f $iso ]] || return 1
  [[ -n $ver ]] || ver="$(iso_version_from_name "$iso" || true)"
  [[ -n $ver ]] || return 0
  sumfile="$ISO_CACHE/omarchy-$ver.iso.sha256"
  if [[ -s $sumfile ]]; then
    sum="$(cat "$sumfile")"
  else
    command -v curl >/dev/null 2>&1 || return 0
    sum="$(curl -fsSL --max-time 20 "$ISO_BASE_URL/omarchy-$ver.iso.sha256" 2>/dev/null || true)"
    if [[ -n $sum ]]; then
      mkdir -p "$ISO_CACHE" 2>/dev/null || true
      printf '%s\n' "$sum" > "$sumfile" 2>/dev/null || true
    fi
  fi
  [[ -n $sum ]] || return 0
  want="${sum%% *}"
  [[ $want =~ ^[0-9a-fA-F]{64}$ ]] || return 0
  got="$(sha256sum "$iso" | awk '{print $1}')"
  [[ $got == "$want" ]]
}

verify_iso_file() { iso_checksum_ok "$1" "${2:-}"; }

verify_iso() {
  [[ -n $ISO_PATH ]] || return 1
  verify_iso_file "$ISO_PATH" "${OMARCHY_VERSION:-$(iso_version_from_name "$ISO_PATH" || true)}"
}

# iso_remote_size <version> — Content-Length of that release ISO, cached for an
# hour. Used to reject a truncated local download before hashing 6 GB of it.
iso_remote_size() {
  local ver="$1" cache now ts sz
  cache="$ISO_CACHE/size-$ver"
  now="$(date +%s)"
  if [[ -s $cache ]]; then
    ts="$(stat -c %Y "$cache" 2>/dev/null || echo 0)"
    if (( now - ts >= 0 && now - ts < 3600 )); then
      cat "$cache"
      return 0
    fi
  fi
  command -v curl >/dev/null 2>&1 || return 1
  sz="$(curl -sIL --max-time 15 "$ISO_BASE_URL/omarchy-$ver.iso" 2>/dev/null | tr -d '\r' \
        | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')"
  [[ $sz =~ ^[0-9]+$ ]] || return 1
  mkdir -p "$ISO_CACHE" 2>/dev/null || true
  printf '%s\n' "$sz" > "$cache" 2>/dev/null || true
  printf '%s\n' "$sz"
}

# iso_file_complete <iso> <version> — false when the server knows a size and the
# local file is shorter (an interrupted 4 GB download). Offline, it returns true
# and the checksum decides.
iso_file_complete() {
  local iso="$1" ver="$2" want got
  [[ -f $iso ]] || return 1
  want="$(iso_remote_size "$ver" 2>/dev/null || true)"
  [[ -n $want ]] || return 0
  got="$(stat -c %s "$iso" 2>/dev/null || echo 0)"
  [[ $got == "$want" ]]
}

show_status() {
  local latest cached
  latest="$(latest_omarchy_version 2>/dev/null || true)"
  cached=""
  [[ -n $latest ]] && cached="$ISO_CACHE/omarchy-$latest.iso"
  echo "── Omarchy VM module ───────────────────────────────────────"
  echo " ISO latest  : ${latest:-unknown (GitHub unreachable)}"
  if [[ -n $cached && -f $cached ]]; then
    local sz want
    sz="$(stat -c %s "$cached" 2>/dev/null || echo 0)"
    want="$(iso_remote_size "$latest" 2>/dev/null || true)"
    if [[ -n $want && $sz != "$want" ]]; then
      echo " ISO cache   : $cached  (INCOMPLETE ${sz}/${want} bytes — a download resumes)"
    else
      echo " ISO cache   : $cached  (complete)"
    fi
  else
    echo " ISO cache   : not downloaded${cached:+ ($cached)}"
  fi
  echo " VM root     : $VMS_ROOT"
  [[ -n ${OVMF_CODE:-} ]] && echo " OVMF code   : $OVMF_CODE" || echo " OVMF code   : missing (install edk2-ovmf)"
  echo " Helpers     :"
  local f
  for f in omarchy-vm omarchy-vm-tui.sh launch-omarchy-tui.sh; do
    [[ -x "$BIN_DIR/$f" ]] && echo "                ✓ $f" || echo "                ✗ $f"
  done
  echo " Menu block  : $( [[ -f $MENU ]] && grep -qF "$BLOCK_BEGIN" "$MENU" && echo present || echo absent )"
  echo " Window rule : $( [[ -f $HYPRLAND ]] && grep -qF -- "$HYPR_BEGIN" "$HYPRLAND" && echo present || echo absent )"
  echo " VMs         :"
  local dir found=0
  if [[ -d $VMS_DIR ]]; then
    for dir in "$VMS_DIR"/*/; do
      [[ -d $dir ]] || continue
      [[ -f "$dir/.vm-config" ]] || continue
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
# Removal must work anywhere: it only deletes our own helpers/menu/binding, so
# an Omarchy install or edk2-ovmf is not a prerequisite for cleaning up.
if [[ $REMOVE == false ]]; then
  [[ -d /usr/share/omarchy ]] || die "This script is meant for Omarchy."
fi

detect_ovmf
MISSING=()
pkg_present qemu || MISSING+=(qemu-desktop)
[[ -n $OVMF_CODE && -n $OVMF_VARS_SRC ]] || MISSING+=(edk2-ovmf)
pkg_present gum || MISSING+=(gum)
pkg_present curl || MISSING+=(curl)
pkg_present wl-clipboard || MISSING+=(wl-clipboard)
pkg_present python || MISSING+=(python)

# Migrate before anything lists, creates or launches: after this point every
# path below sees the flat layout.
migrate_flat_layout || true

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
        "$BIN_DIR/omarchy-vm-tui" "$BIN_DIR/omarchy-vm-tui.sh" "$BIN_DIR/backup-vm-shared.bash" "$BIN_DIR/launch-omarchy-tui.sh" \
        "$BIN_DIR/omarchy-vm-focus" "$BIN_DIR/omarchy-vm-share"
  rm -f "$APPS_DIR"/omarchy-vm*.desktop
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" 2>/dev/null || true
  remove_menu_block
  drop_block_from_file "$HYPRLAND" "$HYPR_BEGIN" "$HYPR_END"
  kb_remove "$KEYBIND" || warn "Could not remove $KEYBIND"
  hyprctl reload >/dev/null 2>&1 || true
  if [[ $PURGE == true ]]; then
    # Preserve the shared files first: a purge that cannot save them aborts
    # instead of silently destroying the user's data.
    if [[ -f $BACKUP_SHARED_LIB ]]; then
      backup_all_vm_shared_folders "$VMS_DIR" "$VMS_DIR/shared folder backup" \
        || { warn "Shared-folder backup failed; VMs and ISO cache kept."; exit 1; }
    else
      warn "$BACKUP_SHARED_LIB missing; VMs and ISO cache kept to protect shared files."
      exit 1
    fi
    # VM dirs only: VMS_ROOT also holds the shared-folder backup, which is data.
    for d in "$VMS_DIR"/*/; do
      case "${d%/}" in "$VMS_DIR/shared folder backup"|"$VMS_DIR/shared") continue ;; esac
      [[ -f "$d/.vm-config" || -f "$d/disk.qcow2" ]] || continue
      rm -rf "$d"
    done
    rm -rf "$ISO_CACHE" && ok "VMs ($VMS_DIR) and ISO cache ($ISO_CACHE) deleted (shared files kept)"
  else
    warn "VMs kept in $VMS_DIR and the ISO cache in $ISO_CACHE (use --purge to delete them)."
  fi
  ok "Helpers, menu entry and window rule removed"
  echo ""
  info "setup-omarchy-vm: removed"
  exit 0
fi

# -----------------------------------------------------------------------------
# 2. ISO download + verification (cache dir)
# -----------------------------------------------------------------------------
# Searches the usual places for a locally-downloaded Omarchy ISO and returns
# the highest-version one that is COMPLETE, or nothing. The resolved cache path
# is excluded — ensure_iso handles it separately.
find_latest_local_iso() {
  local d f ver
  local -a cands=()
  for d in "$ISO_CACHE" "$HOME/Downloads" "$HOME/Documents" "$HOME" "$PWD"; do
    [[ -d $d ]] || continue
    while IFS= read -r f; do
      [[ -f $f ]] || continue
      [[ -n $ISO_PATH ]] && [[ "$(readlink -f "$f")" == "$(readlink -f "$ISO_PATH" 2>/dev/null || echo __none__)" ]] && continue
      ver="$(iso_version_from_name "$f" || true)"
      if [[ -n $ver ]] && ! iso_file_complete "$f" "$ver"; then
        printf ' ! Local Omarchy ISO is incomplete, ignoring it: %s\n' "$f" >&2
        continue
      fi
      cands+=("$f")
    done < <(find "$d" -maxdepth 2 -type f -iname 'omarchy-*.iso' 2>/dev/null)
  done
  ((${#cands[@]})) || return 1
  # Highest version first (version-aware sort on the basename).
  printf '%s\n' "${cands[@]}" | awk -F/ '{print $NF"\t"$0}' | sort -Vr | cut -f2- | head -1
}

use_local_iso() {
  local iso="$1" ver
  [[ -f $iso ]] || die "Local ISO not found: $iso"
  ISO_PATH="$(readlink -f "$iso")"
  ver="$(iso_version_from_name "$ISO_PATH" || true)"
  ok "Using local ISO: $ISO_PATH${ver:+ (Omarchy $ver)}"
  if [[ -n $ver && $ver != "$OMARCHY_VERSION" ]]; then
    warn "This local ISO is $ver; the latest release is $OMARCHY_VERSION."
  fi
  if [[ $NO_VERIFY == false ]]; then
    verify_iso_file "$ISO_PATH" "${ver:-$OMARCHY_VERSION}" \
      || die "SHA-256 mismatch for $ISO_PATH (use --no-verify to override)."
    ok "SHA-256 verified (or no checksum published for this version)."
  else
    warn "SHA-256 verification skipped (--no-verify)."
  fi
}

ensure_iso() {
  mkdir -p "$ISO_CACHE"

  # An explicit --iso always wins, no prompt.
  if [[ -n $LOCAL_ISO ]]; then
    use_local_iso "$LOCAL_ISO"
    return 0
  fi

  # A local ISO is only preferred when it IS the latest release (or newer).
  # An older one is reported for what it is, and the default is to download
  # the latest; -y always downloads the latest.
  local found lver
  if found="$(find_latest_local_iso)"; then
    lver="$(iso_version_from_name "$found" || true)"
    if [[ -z $lver ]]; then
      warn "A local Omarchy ISO was found but its version could not be read: $found"
      warn "The latest release is $OMARCHY_VERSION."
      if [[ $YES == 1 ]] || ! confirm "Use this unknown-version ISO anyway?"; then
        info "Downloading the latest $OMARCHY_VERSION ISO."
      else
        LOCAL_ISO="$found"
      fi
    elif ! version_is_newer "$OMARCHY_VERSION" "$lver"; then
      if [[ $lver == "$OMARCHY_VERSION" ]]; then
        info "Local Omarchy $lver ISO matches the latest release — using it."
      else
        info "Local Omarchy $lver ISO is newer than the latest release ($OMARCHY_VERSION) — using it."
      fi
      LOCAL_ISO="$found"
    elif [[ $YES == 1 ]]; then
      info "Local ISO $lver is older than the latest $OMARCHY_VERSION — downloading the latest."
    else
      warn "A local Omarchy ISO was found: $found (version $lver)."
      warn "The latest release is $OMARCHY_VERSION — this local ISO is older."
      if confirm "Download the latest $OMARCHY_VERSION ISO instead of using the older local $lver?"; then
        info "Downloading the latest $OMARCHY_VERSION ISO."
      else
        LOCAL_ISO="$found"
      fi
    fi
  fi

  if [[ -n $LOCAL_ISO ]]; then
    use_local_iso "$LOCAL_ISO"
    return 0
  fi

  if [[ -f $ISO_PATH ]]; then
    if ! iso_file_complete "$ISO_PATH" "$OMARCHY_VERSION"; then
      local have need
      have="$(stat -c %s "$ISO_PATH" 2>/dev/null || echo 0)"
      need="$(iso_remote_size "$OMARCHY_VERSION" 2>/dev/null || true)"
      warn "Cached ISO is incomplete (${have}${need:+ / $need} bytes) — the download will resume, not restart."
    elif verify_iso; then
      ok "ISO already cached and verified: $ISO_PATH"
      return 0
    else
      warn "Cached ISO failed verification (complete size, wrong checksum) — re-downloading."
      rm -f "$ISO_PATH"
    fi
  fi

  # Refuse to start/resume a download that cannot fit, instead of filling the
  # disk and failing halfway (the usual interrupted-ISO story).
  local need_bytes have_bytes missing avail
  need_bytes="$(iso_remote_size "$OMARCHY_VERSION" 2>/dev/null || true)"
  if [[ -n $need_bytes ]]; then
    have_bytes="$(stat -c %s "$ISO_PATH" 2>/dev/null || echo 0)"
    missing=$((need_bytes - have_bytes))
    avail="$(df --output=avail -B1 "$ISO_CACHE" 2>/dev/null | tail -1 | tr -d ' ')"
    if [[ $avail =~ ^[0-9]+$ ]] && (( missing > avail )); then
      die "Not enough free space in $ISO_CACHE: need $(awk -v b="$missing" 'BEGIN{printf "%.1f", b/1073741824}') GB more, have $(awk -v b="$avail" 'BEGIN{printf "%.1f", b/1073741824}') GB. Free space, or pass --iso with a COMPLETE local ISO."
    fi
  fi

  info "Downloading the latest official Omarchy $OMARCHY_VERSION ISO (~6.4 GB)"
  echo "     $OMARCHY_ISO_URL"
  echo "     -> $ISO_PATH"
  curl -L --fail --retry 3 --continue-at - --progress-bar -o "$ISO_PATH" "$OMARCHY_ISO_URL" \
    || die "ISO download failed."
  if [[ $NO_VERIFY == false ]]; then
    verify_iso_file "$ISO_PATH" "$OMARCHY_VERSION" \
      || die "SHA-256 mismatch — refusing to use the downloaded ISO."
    ok "ISO downloaded and SHA-256 verified."
    info "Detached PGP signature available at $OMARCHY_ISO_SIG_URL"
  else
    warn "SHA-256 verification skipped (--no-verify)."
  fi
}
# VM creation is deferred to the manager when only the setup is requested.
if [[ $SETUP_ONLY == false ]]; then
  configure_latest_iso
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
  # Syntax-check with the file's OWN interpreter. The clipboard bridge is Python,
  # and `bash -n` on it reports a syntax error at the first parenthesis, which
  # killed the whole setup mid-run — so the bridge was never deployed, the
  # launcher was never regenerated, and the bridge silently did nothing.
  # ast.parse rather than py_compile: no __pycache__ dropped in ~/.local/bin.
  case "$(head -c 64 "$dst")" in
    *python*) python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$dst" \
                || die "Syntax error in $dst" ;;
    *)        bash -n "$dst" || die "Syntax error in $dst" ;;
  esac
}

info "Deploying the Omarchy VM helpers to $BIN_DIR"
mkdir -p "$BIN_DIR"
# The setup script is deployed too, so the TUI can create VMs without the
# clone (its repo-relative deps are optional when run from ~/.local/bin).
# omarchy-vm-share belongs here: it is the guest half of the shared folder, exactly
# like omarchy-vm-clipboard-agent is the guest half of the clipboard. It was the one
# helper left out, so a fresh machine kept the shared-folder command in the repo
# only and "sudo omarchy-vm-share --install" answered "command not found" in the VM.
for s in setup-omarchy-vm.sh omarchy-vm-tui.sh backup-vm-shared.bash launch-omarchy-tui.sh omarchy-vm-focus omarchy-vm-share; do
  deploy_file "$SCRIPT_DIR/$s" "$BIN_DIR/$s"
  ok "$s deployed"
done

# The clipboard bridge is a PAIR, and the host half serves the guest half over
# HTTP, so the guest can install itself with one curl. They must therefore land
# in the SAME directory: the host resolves the guest half next to itself, the
# same way the TUI resolves its backend (tui-go actions.go actionsBin).
for s in omarchy-vm-clipboard omarchy-vm-clipboard-agent; do
  deploy_file "$SCRIPT_DIR/$s" "$BIN_DIR/$s"
  ok "$s deployed"
done

cat > "$BIN_DIR/omarchy-vm" << 'WRAPPER_EOF'
#!/bin/bash
# Start an Omarchy VM in QEMU/KVM. Usage: omarchy-vm [VM_NAME]
set -euo pipefail
VMS_DIR="${OMARCHY_VM_ROOT:-${MOSQUITO_VM_ROOT:-$HOME/VMs}}"
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
SHARED_FOLDER="on"
SHARED_DIR="$dir/shared folder"
SSH_PORT=$port
DISPLAY_BACKEND="gtk"
# "on" (default) = virtio-vga-gl (virgl 3D); toggle off in the TUI to use
# std VGA at XRESxYRES, with a fixed resolution that tiles reliably.
GPU_ACCEL="on"
# Guest display resolution for the std-VGA path (see write_launcher): a high
# fixed mode keeps the guest crisp; the GTK window tiles freely and scales.
XRES=1920
YRES=1080
SPICE_PORT=5930
# Shared clipboard between the VM and the host. The bridge is a host-side HTTP
# server on 127.0.0.1, which slirp exposes to the guest as 10.0.2.2 — so no
# QEMU argument changes and the display path (virgl) is untouched. The guest
# pulls its own half with: curl -s http://10.0.2.2:<port>/agent
CLIPBOARD="on"
CLIPBOARD_PORT=7789
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
SHARED_DIR="${SHARED_DIR:-$VM_DIR/shared folder}"
SHARED_FOLDER="${SHARED_FOLDER:-on}"
SSH_PORT="${SSH_PORT:-2222}"
DISPLAY_BACKEND="${DISPLAY_BACKEND:-gtk}"
GPU_ACCEL="${GPU_ACCEL:-on}"
SPICE_PORT="${SPICE_PORT:-5930}"
CLIPBOARD="${CLIPBOARD:-on}"
CLIPBOARD_PORT="${CLIPBOARD_PORT:-7789}"

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
  -name "${VM_NAME} (Omarchy VM)"
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

# 9p shared folder. The export is all the HOST can do: QEMU hands the guest a
# tag called `hostshare` and stops there. Something still has to mount it inside
# the guest, and the kernel module is not loaded on a fresh install, so without a
# nudge the folder simply never appears and the feature looks broken.
#
# So the guest is told, on the console, exactly what to run — and what to run it
# for. The old comment ("guest: mount -t 9p -o trans=virtio hostshare /mnt") was
# a note to whoever read the source, and it also omitted version=9p2000.L, which
# on a current kernel is the difference between mounting and not.
if [[ "$SHARED_FOLDER" == "on" ]]; then
  mkdir -p "$SHARED_DIR"
  args+=( -virtfs "local,path=$SHARED_DIR,mount_tag=hostshare,security_model=mapped-xattr,id=hostshare" )
  printf '\n  Shared folder: %s\n' "$SHARED_DIR"
  printf '    exported to the guest as the 9p tag "hostshare". To see it from inside\n'
  printf '    the VM, run there:\n\n'
  printf '      mkdir -p ~/VMs && curl -sf --retry 3 http://10.0.2.2:%s/share -o ~/VMs/omarchy-vm-share && sudo bash ~/VMs/omarchy-vm-share --install\n\n' "$CLIPBOARD_PORT"
  printf '    It loads virtio_9p, mounts at /mnt/host and installs a unit so it is\n'
  printf '    there on every boot. Without it the folder stays invisible — the host\n'
  printf '    side of this is already done.\n\n'
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

# ── Shared clipboard bridge ──
# Started here rather than as a separate service so it lives and dies with the
# VM: there is nothing to bridge while the VM is not running, and a daemon left
# behind holding the host clipboard would outlive its purpose.
#
# Setsid detaches it from this script's process group. Without that, Ctrl-C in
# the QEMU window — or anything else that signals the group — would take the
# bridge down with it, since it is started from the same shell.
CLIP_PID=""
if [[ "$CLIPBOARD" == "on" ]] && command -v python3 >/dev/null 2>&1; then
  # Only two places, and deliberately no $SCRIPT_DIR: the generated launcher runs
  # with `set -euo pipefail` and has no such variable, so naming it here was a
  # fatal "unbound variable" that killed the launcher BEFORE qemu ran — the VM
  # simply refused to start. An override is honoured first so a packager can
  # point at its own copy.
  CLIP_SRC=""
  for cand in "${OMARCHY_VM_CLIPBOARD_BIN:-}" \
              "$HOME/.local/bin/omarchy-vm-clipboard" \
              "$VM_DIR/omarchy-vm-clipboard"; do
    [[ -n $cand && -x $cand ]] && { CLIP_SRC="$cand"; break; }
  done
  if [[ -n $CLIP_SRC ]]; then
    # A bridge orphaned by an unclean exit still holds the port: reuse it
    # instead of stacking a second one that can never bind.
    if curl -sf --max-time 1 "http://127.0.0.1:$CLIPBOARD_PORT/ping" >/dev/null 2>&1; then
      echo "  Clipboard bridge: already listening on :$CLIPBOARD_PORT (reused)."
    else
      OMARCHY_VM_CLIPBOARD_PORT="$CLIPBOARD_PORT" \
      OMARCHY_VM_STATE_DIR="$VM_DIR/clipboard" \
        setsid python3 "$CLIP_SRC" >"$VM_DIR/clipboard.log" 2>&1 &
      CLIP_PID=$!
      # Wait for the port rather than sleeping a fixed amount: the guest is told
      # this URL the moment the VM window appears, and a bridge that is not
      # listening yet would make the first copy silently do nothing.
      for _ in $(seq 1 40); do
        if curl -sf --max-time 1 "http://127.0.0.1:$CLIPBOARD_PORT/ping" >/dev/null 2>&1; then
          break
        fi
        sleep 0.1
      done
      if curl -sf --max-time 1 "http://127.0.0.1:$CLIPBOARD_PORT/ping" >/dev/null 2>&1; then
        echo "  Clipboard bridge: listening on :$CLIPBOARD_PORT."
      else
        echo "  Clipboard bridge: NOT listening — guest clipboard and agent download will fail." >&2
      fi
    fi
  else
    echo "  Clipboard bridge: no bridge script found — guest clipboard unavailable." >&2
  fi
  if [[ "$CLIPBOARD" == "on" ]]; then
    printf '\n  Guest clipboard + shared folder, inside the VM (one command):\n'
    printf '    mkdir -p ~/VMs && curl -sf --retry 3 http://10.0.2.2:%s/share -o ~/VMs/omarchy-vm-share && sudo bash ~/VMs/omarchy-vm-share --install\n' "$CLIPBOARD_PORT"
    printf '    (it mounts the shared folder, installs the boot unit and the clipboard agent)\n'
    # The lines above go to stdout, which nobody sees when the VM is started
    # from the app entry. Mirror them into a file so they are retrievable on
    # the host (and `omarchy-vm-share --status` prints them too).
    {
      printf 'Guest setup for __VM_NAME__ — run INSIDE the VM.\n'
      printf 'Shared folder + clipboard (once; both persist via user/system units):\n'
      printf '  mkdir -p ~/VMs && curl -sf --retry 3 http://10.0.2.2:%s/share -o ~/VMs/omarchy-vm-share && sudo bash ~/VMs/omarchy-vm-share --install\n' "$CLIPBOARD_PORT"
    } >"$VM_DIR/guest-setup.txt" 2>/dev/null || true
  fi
fi

cleanup(){
  rm -f "$VM_DIR/vm.pid"
  [[ -n $CLIP_PID ]] && kill "$CLIP_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

# One-time guest provisioning: the host side is automatic, but the 9p mount
# and the clipboard agent live INSIDE the guest. Markers written by the guest
# halves let this nag disappear once the README command has been run.
VM_SETUP_MISSING=()
if [[ "$SHARED_FOLDER" == "on" && ! -f "$SHARED_DIR/.mosquitomarchy-vm-setup" ]]; then
  VM_SETUP_MISSING+=("shared folder ($SHARED_DIR -> /mnt/host)")
fi
if [[ "$CLIPBOARD" == "on" && ! -f "$VM_DIR/clipboard/agent-ready" ]]; then
  VM_SETUP_MISSING+=("shared clipboard")
fi
if ((${#VM_SETUP_MISSING[@]})); then
  vm_missing="$(IFS=', '; echo "${VM_SETUP_MISSING[*]}")"
  vm_body="VM setup incomplete: $vm_missing. README: https://github.com/kepalegars/mosquitOmarchy"
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send --app-name "Omarchy VM" --urgency critical --expire-time 0 \
      "Omarchy VM setup incomplete" "$vm_body" >/dev/null 2>&1 &
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name="Omarchy VM" --urgency=critical --expire-time=0 \
      "Omarchy VM setup incomplete" "$vm_body" >/dev/null 2>&1 &
  fi
fi

# Explain the guest-shortcuts toggle (shortest form).
VM_TIP="Focus VM: SUPER + ALT + V."
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
Name=$name (Omarchy VM)
Comment=Run Omarchy in QEMU/KVM ($name)
Exec=uwsm app -- omarchy-vm $name
Icon=omarchy
Terminal=false
Type=Application
Categories=System;Emulator;
EOF
  if [[ $name == "$DEFAULT_VM" ]]; then
    cp -f "$APPS_DIR/omarchy-vm-$name.desktop" "$APPS_DIR/omarchy-vm.desktop"
    sed -i "s/^Name=.*/Name=$name (Omarchy VM)/" "$APPS_DIR/omarchy-vm.desktop"
    sed -i 's/^Comment=.*/Comment=Run Omarchy in QEMU\/KVM/' "$APPS_DIR/omarchy-vm.desktop"
    sed -i 's/^Exec=.*/Exec=uwsm app -- omarchy-vm/' "$APPS_DIR/omarchy-vm.desktop"
  fi
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" 2>/dev/null || true
}

ensure_vm() {
  local dir="$VMS_DIR/$VM_NAME"
  mkdir -p "$dir"
  # Shared folder + clipboard are prepared at install time so every launch
  # finds them ready: the export dir exists and the bridge script is deployed.
  mkdir -p "$dir/shared folder" 2>/dev/null \
    && ok "Shared folder ready: $dir/shared folder" \
    || warn "Could not create $dir/shared folder."
  if [[ -x "$BIN_DIR/omarchy-vm-clipboard" ]]; then
    ok "Clipboard bridge deployed."
  else
    warn "Clipboard bridge missing from $BIN_DIR — guest clipboard will fail until setup re-deploys it."
  fi
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

# Migrate old global and per-VM `shared` folders. Existing files move only when
# the new destination does not exist; if both exist, keep the configured path.
migrate_shared_dirs(){
  local d cur new moved=0
  for d in "$VMS_DIR"/*/; do
    [[ -f "$d/.vm-config" ]] || continue
    new="${d%/}/shared folder"
    cur="$(sed -n 's/^SHARED_DIR="\(.*\)"/\1/p' "$d/.vm-config" | head -1)"
    [[ -n $cur ]] || cur="$LEGACY_SHARED_DIR"
    [[ $cur == "$new" ]] && { mkdir -p "$new"; continue; }
    if [[ -d $cur && -e $new ]]; then
      warn "Both shared folders exist; keeping configured path: $cur"
      continue
    elif [[ -d $cur && ( $cur != "$LEGACY_SHARED_DIR" || $moved == 0 ) ]]; then
      mv "$cur" "$new" && { [[ $cur != "$LEGACY_SHARED_DIR" ]] || moved=1; } \
        && ok "Shared folder moved: $cur -> $new" \
        || { warn "Could not migrate $cur; keeping its configured path."; continue; }
    else
      mkdir -p "$new"
    fi
    sed -i "s|^SHARED_DIR=.*|SHARED_DIR=\"$new\"|" "$d/.vm-config"
    VM_NAME="$(basename "${d%/}")" write_launcher "$d"
    ok "Shared folder is per-VM now: $new"
  done
  rmdir "$LEGACY_SHARED_DIR" 2>/dev/null || true
}

migrate_shared_dirs

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
  cat <<BODY
-- >>> Omarchy_Custom_Scripts_OmarchyVm
-- Omarchy VM Manager TUI (setup-omarchy-vm.sh): one size for every mosquito TUI.
$(bash "$(dirname "${BASH_SOURCE[0]}")/../../../lib/hypr-tui.sh" rule "org.omarchy.omarchy-vm-tui")
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
    ok "Window rule added: org.omarchy.omarchy-vm-tui floats centered (computed TUI size)"
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
