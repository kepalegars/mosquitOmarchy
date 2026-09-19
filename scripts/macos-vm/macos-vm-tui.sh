#!/bin/bash
set -Euo pipefail

# =============================================================================
# macOS VM Manager TUI
# =============================================================================

INSTALL_DIR="$HOME/OSX-KVM"
VMS_DIR="$INSTALL_DIR/vms"
# Self-locating: works wherever the scripts are deployed (~/.local/bin or a clone).
INSTALLER_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/osx-kvm-installer.sh"

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

count_vms() {
    local count=0
    if [[ -d "$VMS_DIR" ]]; then
        shopt -s nullglob
        for vm_dir in "$VMS_DIR"/*/; do
            if [[ -d "$vm_dir" && -f "$vm_dir/mac_hdd_ng.img" ]]; then
                ((count++)) || true
            fi
        done
        shopt -u nullglob
    fi
    echo "$count"
}

get_vm_list() {
    local vms=()
    if [[ -d "$VMS_DIR" ]]; then
        shopt -s nullglob
        for vm_dir in "$VMS_DIR"/*/; do
            if [[ -d "$vm_dir" && -f "$vm_dir/mac_hdd_ng.img" ]]; then
                vms+=("$(basename "$vm_dir")")
            fi
        done
        shopt -u nullglob
    fi
    [[ ${#vms[@]} -gt 0 ]] && printf '%s\n' "${vms[@]}"
}

get_vm_display_name() {
    local version_file="$VMS_DIR/$1/.macos-version"
    [[ -f "$version_file" ]] && cat "$version_file" || echo "macOS ($1)"
}

get_vm_info() {
    local vm_dir="$VMS_DIR/$1"
    local config_file="$vm_dir/.vm-config"
    local ram="8GB" cores="4" disk_size="N/A"
    if [[ -f "$config_file" ]]; then
        # Read config in subshell to avoid variable pollution
        ram="$(source "$config_file"; echo "${RAM_GB:-8}")GB"
        cores="$(source "$config_file"; echo "${CPU_CORES:-4}")"
    fi
    [[ -f "$vm_dir/mac_hdd_ng.img" ]] && disk_size=$(du -h "$vm_dir/mac_hdd_ng.img" 2>/dev/null | cut -f1)
    echo "RAM: $ram | CPU: $cores cores | Disk: $disk_size"
}

show_header() {
    clear
    echo ""
    gum style --foreground "$ACCENT_COLOR" --border double --border-foreground "$BORDER_COLOR" \
        --align center --width 60 --padding "1 2" "macOS VM Manager" "QEMU/KVM Virtual Machines" | center_output 64
    echo ""
}

show_no_vms() {
    show_header
    gum style --foreground "$WARNING_COLOR" --align center --width 60 "No macOS VMs found" | center_output 60
    echo ""
    gum style --faint --align center --width 60 "Would you like to create one?" | center_output 60
    echo ""
    local choice
    choice=$(gum choose "Create New VM" "Exit") || exit 0
    [[ "$choice" == "Create New VM" ]] && exec "$INSTALLER_SCRIPT" --create-vm
    exit 0
}

show_main_menu() {
    local vm_count
    vm_count=$(count_vms)
    [[ $vm_count -eq 0 ]] && show_no_vms

    while true; do
        show_header
        gum style --foreground "$ACCENT_COLOR" --align center --width 60 "Found $vm_count macOS VM(s)" | center_output 60
        echo ""
        gum style --faint --align center --width 60 "Launch VMs from the application menu" | center_output 60
        echo ""
        local choice
        choice=$(gum choose "Create New VM" "Delete VM" "View VM Details" "Exit") || exit 0
        case "$choice" in
            "Create New VM") exec "$INSTALLER_SCRIPT" --create-vm ;;
            "Delete VM") select_and_delete_vm; vm_count=$(count_vms) ;;
            "View VM Details") select_and_view_vm ;;
            "Exit") exit 0 ;;
            *) exit 0 ;;
        esac
    done
}

select_and_delete_vm() {
    show_header
    gum style --foreground "$ERROR_COLOR" --align center --width 60 "Select VM to Delete" | center_output 60
    echo ""

    local -a vm_names=()
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        vm_names+=("$vm_name")
    done < <(get_vm_list)

    local -a options=()
    for vm_name in "${vm_names[@]}"; do
        local disk_size
        disk_size=$(du -h "$VMS_DIR/$vm_name/mac_hdd_ng.img" 2>/dev/null | cut -f1)
        options+=("$(get_vm_display_name "$vm_name") - Disk: $disk_size")
    done
    options+=("← Back")

    local selected
    selected=$(printf '%s\n' "${options[@]}" | gum choose) || return
    [[ "$selected" == "← Back" || -z "$selected" ]] && return

    for i in "${!options[@]}"; do
        if [[ "${options[$i]}" == "$selected" && $i -lt ${#vm_names[@]} ]]; then
            local vm_to_delete="${vm_names[$i]}"
            echo ""
            if gum confirm "Delete $(get_vm_display_name "$vm_to_delete")? This cannot be undone!"; then
                rm -f "$HOME/.local/share/applications/macos-vm-${vm_to_delete}.desktop" 2>/dev/null || true
                rm -rf "${VMS_DIR:?}/${vm_to_delete:?}"
                gum style --foreground "$SUCCESS_COLOR" --align center --width 60 "✓ VM deleted" | center_output 60
                sleep 1
            fi
            return
        fi
    done
}

select_and_view_vm() {
    show_header
    gum style --foreground "$ACCENT_COLOR" --align center --width 60 "Select VM to View" | center_output 60
    echo ""

    local -a vm_names=()
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        vm_names+=("$vm_name")
    done < <(get_vm_list)

    local -a options=()
    for vm_name in "${vm_names[@]}"; do
        options+=("$(get_vm_display_name "$vm_name")")
    done
    options+=("← Back")

    local selected
    selected=$(printf '%s\n' "${options[@]}" | gum choose) || return
    [[ "$selected" == "← Back" || -z "$selected" ]] && return

    for i in "${!options[@]}"; do
        if [[ "${options[$i]}" == "$selected" && $i -lt ${#vm_names[@]} ]]; then
            local vm_name="${vm_names[$i]}"
            local vm_dir="$VMS_DIR/$vm_name"
            local config_file="$vm_dir/.vm-config"
            local ram="8" cores="4" version="unknown"
            if [[ -f "$config_file" ]]; then
                ram="$(source "$config_file"; echo "${RAM_GB:-8}")"
                cores="$(source "$config_file"; echo "${CPU_CORES:-4}")"
                version="$(source "$config_file"; echo "${MACOS_VERSION:-unknown}")"
            fi
            local disk_size="N/A"
            [[ -f "$vm_dir/mac_hdd_ng.img" ]] && disk_size=$(du -h "$vm_dir/mac_hdd_ng.img" 2>/dev/null | cut -f1)
            show_header
            gum style --foreground "$ACCENT_COLOR" --border normal --align center --width 60 --padding "1 2" "$(get_vm_display_name "$vm_name")" | center_output 64
            echo ""
            gum style --align left --width 50 "VM Name:      $vm_name" "macOS:        $version" "RAM:          ${ram}GB" "CPU Cores:    $cores" "Disk Size:    $disk_size" "Location:     $vm_dir" | center_output 50
            echo ""
            gum style --faint --align center --width 60 "Press Enter to go back" | center_output 60
            read -r
            return
        fi
    done
}

command -v gum &>/dev/null || { echo "Error: gum required. Install: sudo pacman -S gum"; exit 1; }
detect_theme_colors
show_main_menu
