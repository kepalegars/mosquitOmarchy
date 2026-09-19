#!/bin/bash
set -Euo pipefail

# =============================================================================
# Omarchy VM Manager TUI (QEMU/KVM)
# =============================================================================

VMS_ROOT="${OMARCHY_VM_ROOT:-$HOME/Omarchy-VM}"
VMS_DIR="$VMS_ROOT/vms"
SETUP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-omarchy-vm.sh"

detect_theme_colors() {
    local ghostty_conf="$HOME/.config/omarchy/current/theme/ghostty.conf"
    ACCENT_COLOR="212"
    BORDER_COLOR="240"
    SUCCESS_COLOR="42"
    WARNING_COLOR="214"
    ERROR_COLOR="196"
    if [[ -f "$ghostty_conf" ]]; then
        local palette_6
        palette_6=$(grep "^palette = 6=" "$ghostty_conf" 2>/dev/null | cut -d'=' -f3 | tr -d '#')
        [[ -n "$palette_6" ]] && ACCENT_COLOR="$palette_6"
    fi
}

center_output() {
    local width=${1:-70}
    local term_width
    term_width=$(tput cols)
    local padding=$(( (term_width - width) / 2 ))
    [[ $padding -lt 0 ]] && padding=0
    while IFS= read -r line; do
        printf "%${padding}s%s\n" "" "$line"
    done
}

cfg_get() {
    local file="$1" var="$2"
    ( set +u; source "$file" 2>/dev/null; printf '%s' "${!var:-}" )
}

cfg_set() {
    local file="$1" key="$2" val="$3"
    if grep -qE "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}

get_vm_list() {
    [[ -d $VMS_DIR ]] || return 0
    local vm_dir
    shopt -s nullglob
    for vm_dir in "$VMS_DIR"/*/; do
        [[ -f "$vm_dir/.vm-config" ]] && basename "$vm_dir"
    done
    shopt -u nullglob
}

count_vms() { get_vm_list | grep -c . || true; }

vm_running() {
    local pidfile="$VMS_DIR/$1/vm.pid"
    [[ -f $pidfile ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null
}

show_header() {
    clear
    echo ""
    gum style --foreground "$ACCENT_COLOR" --border double --border-foreground "$BORDER_COLOR" \
        --align center --width 60 --padding "1 2" "Omarchy VM Manager" "QEMU/KVM Virtual Machines" | center_output 64
    echo ""
}

prompt_name() {
    local name
    name=$(gum input --header "VM name (letters, digits, - and _)" --placeholder "omarchy") || return 1
    [[ -z $name ]] && name="omarchy"
    [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || { gum style --foreground "$ERROR_COLOR" "Invalid name." | center_output 60; sleep 1; return 1; }
    [[ -e "$VMS_DIR/$name" ]] && { gum style --foreground "$WARNING_COLOR" "A VM named '$name' already exists." | center_output 60; sleep 1; return 1; }
    printf '%s' "$name"
}

create_vm() {
    local name
    name=$(prompt_name) || return
    clear
    echo "Creating VM '$name' (downloads the ISO on first run)…"
    echo
    # Run as a CHILD (not exec): the manager must come back here to show
    # success and return to the menu, instead of the terminal closing.
    if "$SETUP_SCRIPT" --vm "$name" --create-vm; then
        echo
        gum style --foreground "$SUCCESS_COLOR" --align center --width 60 \
            "VM '$name' created successfully." | center_output 60
    else
        echo
        gum style --foreground "$ERROR_COLOR" --align center --width 60 \
            "VM creation failed — see the messages above." | center_output 60
    fi
    echo
    gum style --faint --align center --width 60 "Press Enter to return to the menu" | center_output 60
    read -r
}

select_vm() {
    local header="$1"
    local -a names=()
    while IFS= read -r n; do [[ -n $n ]] && names+=("$n"); done < <(get_vm_list)
    ((${#names[@]})) || return 1
    local -a options=()
    local n
    for n in "${names[@]}"; do
        local state="stopped"
        vm_running "$n" && state="running"
        options+=("$n  [$state]")
    done
    local selected
    selected=$(printf '%s\n' "${options[@]}" | gum choose --header "$header") || return 1
    local idx=0
    for n in "${names[@]}"; do
        [[ "${options[$idx]}" == "$selected" ]] && { printf '%s' "$n"; return 0; }
        idx=$((idx + 1))
    done
    return 1
}

start_vm() {
    local name
    name=$(select_vm "Start which VM?") || return
    local dir="$VMS_DIR/$name"
    [[ -x "$dir/start-omarchy.sh" ]] || { gum style --foreground "$ERROR_COLOR" "Launcher missing." | center_output 60; sleep 2; return; }
    exec "$dir/start-omarchy.sh"
}

stop_vm() {
    local name
    name=$(select_vm "Stop which VM?") || return
    local pidfile="$VMS_DIR/$name/vm.pid"
    if ! vm_running "$name"; then
        gum style --foreground "$WARNING_COLOR" "'$name' is not running." | center_output 60; sleep 1; return
    fi
    gum confirm "Force-stop '$name'? (unsaved guest data may be lost)" || return
    kill "$(cat "$pidfile")" 2>/dev/null || true
    sleep 1
    vm_running "$name" && kill -9 "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
    gum style --foreground "$SUCCESS_COLOR" "'$name' stopped." | center_output 60; sleep 1
}

delete_vm() {
    local name
    name=$(select_vm "Delete which VM?") || return
    gum confirm "Delete '$name' and its disk? This cannot be undone!" || return
    rm -f "$HOME/.local/share/applications/omarchy-vm-$name.desktop"
    [[ $name == omarchy ]] && rm -f "$HOME/.local/share/applications/omarchy-vm.desktop"
    rm -rf "${VMS_DIR:?}/${name:?}"
    command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    gum style --foreground "$SUCCESS_COLOR" "VM '$name' deleted." | center_output 60; sleep 1
}

view_vm() {
    local name
    name=$(select_vm "View which VM?") || return
    local dir="$VMS_DIR/$name" cfg="$VMS_DIR/$name/.vm-config"
    local ram cores iso boot gpu shared ssh size state
    ram=$(cfg_get "$cfg" RAM_MB); cores=$(cfg_get "$cfg" CPU_CORES)
    iso=$(cfg_get "$cfg" ISO_PATH); boot=$(cfg_get "$cfg" BOOT_ORDER)
    gpu=$(cfg_get "$cfg" GPU_ACCEL); shared=$(cfg_get "$cfg" SHARED_FOLDER)
    ssh=$(cfg_get "$cfg" SSH_PORT)
    size="n/a"; [[ -f "$dir/disk.qcow2" ]] && size=$(du -h "$dir/disk.qcow2" 2>/dev/null | cut -f1)
    state="stopped"; vm_running "$name" && state="running"
    show_header
    gum style --foreground "$ACCENT_COLOR" --border normal --align center --width 60 --padding "1 2" "$name" | center_output 64
    echo ""
    gum style --align left --width 54 \
        "State:        $state" \
        "RAM:          $(( ${ram:-0} / 1024 )) GB" \
        "CPU cores:    ${cores:-?}" \
        "Disk:         $size" \
        "Boot order:   $boot  (d = ISO, c = disk)" \
        "GPU (virgl):  ${gpu:-?}" \
        "Shared 9p:    ${shared:-off}" \
        "SSH port:     ${ssh:-?} (host -> guest 22)" \
        "ISO:          ${iso:-none}" \
        "Location:     $dir" | center_output 54
    echo ""
    gum style --faint --align center --width 60 "Press Enter to go back" | center_output 60
    read -r
}

edit_ram() {
    local name; name=$(select_vm "Edit RAM for which VM?") || return
    local cfg="$VMS_DIR/$name/.vm-config"
    local total opts=()
    total=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    local g; for g in 2 4 8 16 32 64; do (( g <= total )) && opts+=("${g} GB"); done
    local sel; sel=$(printf '%s\n' "${opts[@]}" | gum choose --header "RAM for '$name' (host: ${total} GB)") || return
    cfg_set "$cfg" RAM_MB "$(( ${sel% *} * 1024 ))"
    gum style --foreground "$SUCCESS_COLOR" "RAM set to $sel." | center_output 60; sleep 1
}

edit_cpu() {
    local name; name=$(select_vm "Edit CPU for which VM?") || return
    local cfg="$VMS_DIR/$name/.vm-config"
    local max; max=$(nproc)
    local opts=(); local c; for (( c=1; c<=max; c++ )); do opts+=("$c core(s)"); done
    local sel; sel=$(printf '%s\n' "${opts[@]}" | gum choose --header "vCPU for '$name' (host: $max)") || return
    cfg_set "$cfg" CPU_CORES "${sel%% *}"
    gum style --foreground "$SUCCESS_COLOR" "CPU set to ${sel%% *} core(s)." | center_output 60; sleep 1
}

edit_disk() {
    local name; name=$(select_vm "Grow disk for which VM?") || return
    local disk="$VMS_DIR/$name/disk.qcow2"
    [[ -f $disk ]] || { gum style --foreground "$ERROR_COLOR" "Disk not found." | center_output 60; sleep 2; return; }
    local cur new
    cur=$(qemu-img info "$disk" 2>/dev/null | sed -n 's/.*virtual size:.*(\([0-9]*\) bytes).*/\1/p')
    cur=$(( ${cur:-0} / 1024 / 1024 / 1024 ))
    new=$(gum input --header "New disk size in GB (current: ${cur}G)" --value "$((cur + 32))") || return
    [[ $new =~ ^[0-9]+$ ]] || { gum style --foreground "$ERROR_COLOR" "Invalid size." | center_output 60; sleep 2; return; }
    (( new <= cur )) && { gum style --foreground "$WARNING_COLOR" "Shrinking is not supported." | center_output 60; sleep 2; return; }
    qemu-img resize "$disk" "${new}G" >/dev/null || return
    gum style --foreground "$SUCCESS_COLOR" "Disk grown to ${new}G — extend the partition inside the guest." | center_output 60; sleep 2
}

toggle_setting() {
    local name; name=$(select_vm "Edit which VM?") || return
    local cfg="$VMS_DIR/$name/.vm-config"
    local key="$1" on="$2" off="$3" label="$4"
    local cur; cur=$(cfg_get "$cfg" "$key")
    if [[ $cur == "$on" ]]; then
        cfg_set "$cfg" "$key" "\"$off\""
        gum style --foreground "$SUCCESS_COLOR" "$label: $off" | center_output 60
    else
        cfg_set "$cfg" "$key" "\"$on\""
        gum style --foreground "$SUCCESS_COLOR" "$label: $on" | center_output 60
    fi
    sleep 1
}

toggle_boot() {
    local name; name=$(select_vm "Boot order for which VM?") || return
    local cfg="$VMS_DIR/$name/.vm-config"
    local cur; cur=$(cfg_get "$cfg" BOOT_ORDER)
    if [[ $cur == "d" ]]; then cfg_set "$cfg" BOOT_ORDER '"c"'; else cfg_set "$cfg" BOOT_ORDER '"d"'; fi
    gum style --foreground "$SUCCESS_COLOR" "Boot order set to $( [[ $cur == d ]] && echo c || echo d ) (install=ISO)" | center_output 60
    sleep 1
}

mark_installed() {
    local name; name=$(select_vm "Mark which VM's install as complete?") || return
    local cfg="$VMS_DIR/$name/.vm-config"
    cfg_set "$cfg" BOOT_ORDER '"c"'
    gum style --foreground "$SUCCESS_COLOR" "'$name' now boots the installed disk." | center_output 60
    sleep 1
}

usb_passthrough() {
    local name; name=$(select_vm "USB passthrough for which VM?") || return
    local cfg="$VMS_DIR/$name/.vm-config"
    command -v lsusb >/dev/null || { gum style --foreground "$ERROR_COLOR" "lsusb not found (install usbutils)." | center_output 60; sleep 2; return; }
    local -a devs=() descs=()
    while IFS= read -r line; do
        local id
        id=$(printf '%s' "$line" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}')
        [[ -z $id ]] && continue
        devs+=("$id"); descs+=("$id  ${line##*ID $id }")
    done < <(lsusb 2>/dev/null)
    ((${#devs[@]})) || { gum style --foreground "$WARNING_COLOR" "No USB devices found." | center_output 60; sleep 2; return; }
    local selected
    selected=$(printf '%s\n' "${descs[@]}" | gum choose --no-limit --header "Select USB devices to pass through (Tab/x, Enter)") || return
    local line="USB_PASSTHROUGH=("
    while IFS= read -r s; do
        [[ -z $s ]] && continue
        line+="\"${s%%  *}\" "
    done <<< "$selected"
    line+=")"
    sed -i "s|^USB_PASSTHROUGH=.*|$line|" "$cfg"
    gum style --foreground "$SUCCESS_COLOR" "USB passthrough updated." | center_output 60; sleep 1
}

pci_passthrough() {
    local name; name=$(select_vm "PCI/GPU passthrough for which VM?") || return
    local cfg="$VMS_DIR/$name/.vm-config"
    command -v lspci >/dev/null || { gum style --foreground "$ERROR_COLOR" "lspci not found (install pciutils)." | center_output 60; sleep 2; return; }
    local -a addrs=() descs=()
    while IFS= read -r line; do
        local addr
        addr=$(printf '%s' "$line" | awk '{print $1}')
        [[ $addr =~ ^[0-9a-fA-F]{4}: ]] || continue
        addrs+=("$addr"); descs+=("$addr  ${line#* }")
    done < <(lspci -Dnn 2>/dev/null | sort)
    ((${#addrs[@]})) || { gum style --foreground "$WARNING_COLOR" "No PCI devices found." | center_output 60; sleep 2; return; }
    local selected
    selected=$(printf '%s\n' "${descs[@]}" | gum choose --no-limit --header "Select PCI devices (bind vfio-pci first; GPU needs IOMMU)") || return
    local line="VFIO_DEVICES=("
    while IFS= read -r s; do
        [[ -z $s ]] && continue
        line+="\"${s%%  *}\" "
    done <<< "$selected"
    line+=")"
    sed -i "s|^VFIO_DEVICES=.*|$line|" "$cfg"
    gum style --foreground "$SUCCESS_COLOR" "PCI passthrough updated." | center_output 60; sleep 1
}

show_no_vms() {
    show_header
    gum style --foreground "$WARNING_COLOR" --align center --width 60 "No Omarchy VM found" | center_output 60
    echo ""
    gum style --faint --align center --width 60 "Would you like to create one?" | center_output 60
    echo ""
    local choice
    choice=$(gum choose "Create New VM" "Exit") || exit 0
    [[ "$choice" == "Create New VM" ]] && create_vm
    exit 0
}

show_main_menu() {
    local vm_count
    vm_count=$(count_vms)
    [[ $vm_count -eq 0 ]] && show_no_vms

    while true; do
        show_header
        gum style --foreground "$ACCENT_COLOR" --align center --width 60 "Found $vm_count Omarchy VM(s)" | center_output 60
        echo ""
        local choice
        choice=$(gum choose \
            "Create New VM" \
            "Start VM" \
            "Stop VM" \
            "Delete VM" \
            "View VM Details" \
            "Edit RAM" \
            "Edit CPU cores" \
            "Grow disk" \
            "Mark installation complete (boot disk)" \
            "Toggle boot order (ISO / disk)" \
            "Toggle virgl 3D accel" \
            "Toggle shared 9p folder" \
            "USB passthrough" \
            "PCI/GPU passthrough" \
            "Exit" --header "What do you want to do?") || exit 0
        case "$choice" in
            "Create New VM") create_vm ;;
            "Start VM") start_vm ;;
            "Stop VM") stop_vm ;;
            "Delete VM") delete_vm; vm_count=$(count_vms) ;;
            "View VM Details") view_vm ;;
            "Edit RAM") edit_ram ;;
            "Edit CPU cores") edit_cpu ;;
            "Grow disk") edit_disk ;;
            "Mark installation complete (boot disk)") mark_installed ;;
            "Toggle boot order (ISO / disk)") toggle_boot ;;
            "Toggle virgl 3D accel") toggle_setting GPU_ACCEL on off "virgl" ;;
            "Toggle shared 9p folder") toggle_setting SHARED_FOLDER on off "shared folder" ;;
            "USB passthrough") usb_passthrough ;;
            "PCI/GPU passthrough") pci_passthrough ;;
            *) exit 0 ;;
        esac
    done
}

command -v gum &>/dev/null || { echo "Error: gum required. Install: sudo pacman -S gum"; exit 1; }
detect_theme_colors
show_main_menu
