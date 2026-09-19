#!/bin/bash

# OSX-KVM Installer for Omarchy (Arch Linux)
# This script sets up everything needed to run macOS in a VM using QEMU/KVM

set -eo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/elevate.bash"  # mq_sudo: native pkexec prompt when not root

# Cleanup function for failures
cleanup() {
    local exit_code=$?
    # Don't print error on user interrupt (Ctrl+C = 130) or clean exit
    if [[ $exit_code -ne 0 && $exit_code -ne 130 ]]; then
        print_error "Installation failed. Check the error messages above."
    fi
}
trap cleanup EXIT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Installation directory
INSTALL_DIR="$HOME/OSX-KVM"
VMS_DIR="$INSTALL_DIR/vms"

# Current VM being configured (set during VM creation)
CURRENT_VM_NAME=""
CURRENT_VM_DIR=""
CURRENT_MACOS_VERSION=""
CURRENT_MACOS_DISPLAY_NAME=""
CURRENT_VM_RAM=""
CURRENT_VM_CORES=""
CURRENT_VM_THREADS=""

# Feature configuration (set during VM setup)
USB_PASSTHROUGH_ARGS=""
USB_PASSTHROUGH_DEVICES=()
SMBIOS_GENERATED=false
SMBIOS_MODEL=""
SMBIOS_SERIAL=""
SMBIOS_MLB=""
SMBIOS_UUID=""
BOOT_ARGS=""

print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           OSX-KVM Installer for Omarchy                   ║"
    echo "║         Run macOS on QEMU/KVM with OpenCore               ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# Map version arg to display name
get_macos_display_name() {
    case $1 in
        high-sierra) echo "macOS High Sierra" ;;
        mojave) echo "macOS Mojave" ;;
        catalina) echo "macOS Catalina" ;;
        big-sur) echo "macOS Big Sur" ;;
        monterey) echo "macOS Monterey" ;;
        ventura) echo "macOS Ventura" ;;
        sonoma) echo "macOS Sonoma" ;;
        sequoia) echo "macOS Sequoia" ;;
        tahoe) echo "macOS Tahoe" ;;
        *) echo "macOS" ;;
    esac
}

# List existing VMs
list_existing_vms() {
    local vms=()
    if [[ -d "$VMS_DIR" ]]; then
        shopt -s nullglob
        for vm_dir in "$VMS_DIR"/*/; do
            if [[ -d "$vm_dir" ]]; then
                local vm_name
                vm_name=$(basename "$vm_dir")
                local version_file="$vm_dir/.macos-version"
                local display_name="Unknown"
                if [[ -f "$version_file" ]]; then
                    display_name=$(tr -d '\n' < "$version_file")
                fi
                vms+=("$vm_name:$display_name")
            fi
        done
        shopt -u nullglob
    fi
    echo "${vms[@]}"
}

# Count existing VMs
count_existing_vms() {
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

# Check for legacy installation (old single-VM style)
check_legacy_installation() {
    if [[ -f "$INSTALL_DIR/mac_hdd_ng.img" ]] && [[ ! -d "$VMS_DIR" ]]; then
        return 0  # Legacy installation found
    fi
    return 1
}

# Migrate legacy installation to new multi-VM structure
migrate_legacy_installation() {
    print_info "Found legacy single-VM installation"
    echo ""
    echo "Your existing macOS VM will be migrated to the new multi-VM structure."
    echo "This allows you to have multiple VMs with different macOS versions."
    echo ""

    read -rp "Enter a name for your existing VM [legacy]: " legacy_name
    legacy_name=${legacy_name:-legacy}
    legacy_name=$(echo "$legacy_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-_')

    # Create VMs directory and VM subdirectory
    mkdir -p "$VMS_DIR/$legacy_name"

    # Move disk image
    if [[ -f "$INSTALL_DIR/mac_hdd_ng.img" ]]; then
        mv "$INSTALL_DIR/mac_hdd_ng.img" "$VMS_DIR/$legacy_name/"
        print_status "Moved disk image to $VMS_DIR/$legacy_name/"
    fi

    # Move or copy BaseSystem.img if it exists
    if [[ -f "$INSTALL_DIR/BaseSystem.img" ]]; then
        mv "$INSTALL_DIR/BaseSystem.img" "$VMS_DIR/$legacy_name/"
        print_status "Moved BaseSystem.img to $VMS_DIR/$legacy_name/"
    fi

    # Create version file (unknown version for legacy)
    echo "macOS (Migrated)" > "$VMS_DIR/$legacy_name/.macos-version"

    # Set current VM variables for launcher creation
    CURRENT_VM_NAME="$legacy_name"
    CURRENT_VM_DIR="$VMS_DIR/$legacy_name"
    CURRENT_MACOS_DISPLAY_NAME="macOS (Migrated)"

    # Set default resources for migrated VM (can be changed later in start-macos.sh)
    CURRENT_VM_RAM=8192      # 8GB
    CURRENT_VM_CORES=4
    CURRENT_VM_THREADS=8

    # Save default config
    cat > "$CURRENT_VM_DIR/.vm-config" << EOF
RAM_GB=8
RAM_MIB=8192
CPU_CORES=4
CPU_THREADS=8
EOF

    # Create new launcher for migrated VM
    create_launcher
    create_desktop_entry

    # Remove old launcher and desktop entry if they exist
    rm -f "$INSTALL_DIR/start-macos.sh"
    rm -f "$HOME/.local/share/applications/macos-vm.desktop"

    print_status "Migration complete!"
    echo ""
}

# Show existing VMs menu
show_vm_menu() {
    echo ""
    echo -e "${BLUE}Existing macOS VMs:${NC}"
    echo ""

    local i=1
    local vm_list=()
    shopt -s nullglob
    for vm_dir in "$VMS_DIR"/*/; do
        if [[ -d "$vm_dir" && -f "$vm_dir/mac_hdd_ng.img" ]]; then
            local vm_name
            vm_name=$(basename "$vm_dir")
            local version_file="$vm_dir/.macos-version"
            local config_file="$vm_dir/.vm-config"
            local display_name="Unknown Version"
            local ram_info="8GB"
            local cpu_info="4 cores"

            if [[ -f "$version_file" ]]; then
                display_name=$(cat "$version_file")
            fi

            # Read resource config if available (in subshell to avoid variable pollution)
            if [[ -f "$config_file" ]]; then
                # shellcheck source=/dev/null
                ram_info="$(source "$config_file"; echo "${RAM_GB:-8}")GB"
                # shellcheck source=/dev/null
                cpu_info="$(source "$config_file"; echo "${CPU_CORES:-4}") cores"
            fi

            local disk_size
            disk_size=$(du -h "$vm_dir/mac_hdd_ng.img" 2>/dev/null | cut -f1)
            echo "  $i) $display_name ($vm_name)"
            echo "     RAM: $ram_info | CPU: $cpu_info | Disk: $disk_size"
            vm_list+=("$vm_name")
            ((i++)) || true
        fi
    done
    shopt -u nullglob

    echo ""
    echo "  N) Create a NEW macOS VM"
    echo "  D) Delete a VM"
    echo "  Q) Quit"
    echo ""

    read -rp "Select an option: " choice

    if [[ $choice =~ ^[Nn]$ ]]; then
        return 0  # Signal to create new VM
    elif [[ $choice =~ ^[Dd]$ ]]; then
        delete_vm
        # After deletion, show menu again if VMs remain
        local remaining
        remaining=$(count_existing_vms)
        if [[ $remaining -gt 0 ]]; then
            show_vm_menu
        else
            return 0  # No VMs left, prompt to create new
        fi
    elif [[ $choice =~ ^[Qq]$ ]]; then
        exit 0
    elif [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
        local selected_vm="${vm_list[$((choice-1))]}"
        launch_existing_vm "$selected_vm"
        exit 0
    else
        print_error "Invalid selection"
        show_vm_menu
    fi
}

# Launch an existing VM
launch_existing_vm() {
    local vm_name="$1"
    local vm_dir="$VMS_DIR/$vm_name"
    local launcher="$vm_dir/start-macos.sh"

    if [[ -x "$launcher" ]]; then
        print_info "Launching $vm_name..."
        exec "$launcher"
    else
        print_error "Launcher not found for $vm_name"
        exit 1
    fi
}

# Delete a VM
delete_vm() {
    echo ""
    echo -e "${RED}Delete a macOS VM${NC}"
    echo ""
    echo "Select a VM to delete:"
    echo ""

    local i=1
    local vm_list=()
    shopt -s nullglob
    for vm_dir in "$VMS_DIR"/*/; do
        if [[ -d "$vm_dir" && -f "$vm_dir/mac_hdd_ng.img" ]]; then
            local vm_name
            vm_name=$(basename "$vm_dir")
            local version_file="$vm_dir/.macos-version"
            local display_name="Unknown Version"
            if [[ -f "$version_file" ]]; then
                display_name=$(cat "$version_file")
            fi
            local disk_size
            disk_size=$(du -h "$vm_dir/mac_hdd_ng.img" 2>/dev/null | cut -f1)
            echo "  $i) $display_name ($vm_name) - Disk: $disk_size"
            vm_list+=("$vm_name")
            ((i++)) || true
        fi
    done
    shopt -u nullglob

    echo ""
    echo "  C) Cancel"
    echo ""

    read -rp "Select VM to delete: " choice

    if [[ $choice =~ ^[Cc]$ ]]; then
        return 1  # Cancelled
    elif [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
        local selected_vm="${vm_list[$((choice-1))]}"
        local selected_dir="$VMS_DIR/$selected_vm"
        local version_file="$selected_dir/.macos-version"
        local display_name="$selected_vm"
        if [[ -f "$version_file" ]]; then
            display_name=$(cat "$version_file")
        fi

        echo ""
        print_warning "You are about to delete: $display_name ($selected_vm)"
        print_warning "This will permanently delete:"
        echo "  - Virtual disk (mac_hdd_ng.img)"
        echo "  - macOS base image (BaseSystem.img)"
        echo "  - VM configuration and launcher"
        echo "  - Desktop menu entry"
        echo ""

        read -rp "Type 'DELETE' to confirm: " confirm
        if [[ "$confirm" == "DELETE" ]]; then
            # Remove desktop entry
            local desktop_file="$HOME/.local/share/applications/macos-vm-${selected_vm}.desktop"
            if [[ -f "$desktop_file" ]]; then
                rm -f "$desktop_file"
                print_status "Removed desktop entry"
            fi

            # Remove VM directory
            rm -rf "$selected_dir"
            print_status "Deleted VM: $selected_vm"
            echo ""

            # Check if any VMs remain
            local remaining
            remaining=$(count_existing_vms)
            if [[ $remaining -eq 0 ]]; then
                print_info "No VMs remaining."
            fi

            return 0
        else
            print_info "Deletion cancelled"
            return 1
        fi
    else
        print_error "Invalid selection"
        return 1
    fi
}

# Check if running as root (we don't want that)
check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        print_error "Please run this script as a normal user, not root."
        print_info "The script will ask for sudo when needed."
        exit 1
    fi
}

# Check CPU virtualization support
check_cpu_support() {
    print_info "Checking CPU virtualization support..."
    
    if grep -E '(vmx|svm)' /proc/cpuinfo > /dev/null 2>&1; then
        if grep -q 'vmx' /proc/cpuinfo; then
            print_status "Intel VT-x supported"
        else
            print_status "AMD-V supported"
        fi
    else
        print_error "CPU virtualization not supported or not enabled in BIOS"
        print_info "Please enable VT-x (Intel) or AMD-V in your BIOS settings"
        exit 1
    fi
}

# Check if KVM is available
check_kvm() {
    print_info "Checking KVM availability..."
    
    if [[ -e /dev/kvm ]]; then
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            print_status "KVM is available and accessible"
        else
            print_warning "KVM exists but not accessible. Will fix permissions..."
        fi
    else
        print_warning "KVM device not found. Will load modules..."
    fi
}

# Install required packages
install_packages() {
    print_info "Installing required packages..."

    # Official repo packages (installed via pacman)
    local pacman_packages=(
        qemu-full
        libvirt
        virt-manager
        dnsmasq
        edk2-ovmf
        swtpm
        git
        wget
        python
        python-pip
        p7zip
        openbsd-netcat
        screen
        htop
    )

    # AUR packages (installed via yay)
    local aur_packages=(
        dmg2img
        cdrtools
    )

    # Check which pacman packages need to be installed
    local to_install=()
    for pkg in "${pacman_packages[@]}"; do
        if ! pacman -Qi "$pkg" > /dev/null 2>&1; then
            to_install+=("$pkg")
        fi
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        print_info "Installing from official repos: ${to_install[*]}"
        mq_sudo pacman -S --needed --noconfirm "${to_install[@]}"
        print_status "Official repo packages installed"
    else
        print_status "All official repo packages already installed"
    fi

    # Check for yay
    if ! command -v yay &> /dev/null; then
        print_error "yay not found. Please install yay to continue."
        print_info "AUR packages needed: ${aur_packages[*]}"
        exit 1
    fi

    # Check which AUR packages need to be installed
    local aur_to_install=()
    for pkg in "${aur_packages[@]}"; do
        if ! pacman -Qi "$pkg" > /dev/null 2>&1; then
            aur_to_install+=("$pkg")
        fi
    done

    if [[ ${#aur_to_install[@]} -gt 0 ]]; then
        print_info "Installing from AUR: ${aur_to_install[*]}"
        yay -S --needed --noconfirm "${aur_to_install[@]}"
        print_status "AUR packages installed"
    else
        print_status "All AUR packages already installed"
    fi
}

# Configure user groups
configure_groups() {
    print_info "Configuring user groups..."
    
    local groups=("kvm" "libvirt" "input")
    local added_groups=()
    
    for group in "${groups[@]}"; do
        if ! id -nG "$USER" | grep -qw "$group"; then
            mq_sudo usermod -aG "$group" "$USER"
            added_groups+=("$group")
        fi
    done
    
    if [[ ${#added_groups[@]} -gt 0 ]]; then
        print_status "Added user to groups: ${added_groups[*]}"
        print_warning "You must log out and back in for group changes to take effect."
        echo ""
        print_info "Options:"
        echo "  1) Exit now, relog, then run this script again"
        echo "  2) Continue anyway (you'll need to relog before running the VM)"
        echo ""
        local group_choice
        read -rp "Choose (1 or 2) [1]: " -n 1 group_choice
        echo
        group_choice=${group_choice:-1}
        if [[ $group_choice == "1" ]]; then
            print_info "Please log out and back in, then run this script again."
            exit 0
        fi
        NEEDS_RELOGIN=true
    else
        print_status "User already in required groups"
    fi
}

# Enable and start services
configure_services() {
    print_info "Configuring services..."
    
    # Enable libvirtd
    if ! systemctl is-enabled libvirtd > /dev/null 2>&1; then
        mq_sudo systemctl enable libvirtd
        print_status "Enabled libvirtd service"
    fi
    
    if ! systemctl is-active libvirtd > /dev/null 2>&1; then
        mq_sudo systemctl start libvirtd
        print_status "Started libvirtd service"
    fi
    
    print_status "Services configured"
}

# Configure KVM module
configure_kvm() {
    print_info "Configuring KVM module..."
    
    # Create modprobe config for KVM
    local kvm_conf="/etc/modprobe.d/kvm.conf"
    
    if [[ ! -f "$kvm_conf" ]] || ! grep -q "ignore_msrs=1" "$kvm_conf" 2>/dev/null; then
        echo "options kvm ignore_msrs=1" | mq_sudo tee "$kvm_conf" > /dev/null
        print_status "Created KVM configuration"
    else
        print_status "KVM already configured"
    fi
    
    # Load KVM module with ignore_msrs
    mq_sudo modprobe kvm
    echo 1 | mq_sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null
    print_status "KVM module configured"
}

# Check IOMMU groups (for passthrough compatibility)
check_iommu() {
    print_info "Checking IOMMU configuration..."

    # Check if IOMMU is enabled
    if [[ ! -d /sys/kernel/iommu_groups ]] || [[ -z "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
        print_warning "IOMMU is not enabled or not available"
        echo ""
        echo "To enable IOMMU, add to your kernel parameters:"
        if grep -q 'vendor_id.*GenuineIntel' /proc/cpuinfo; then
            echo "  intel_iommu=on iommu=pt"
        else
            echo "  amd_iommu=on iommu=pt"
        fi
        echo ""
        echo "Edit /etc/default/grub or your bootloader config, then reboot."
        echo ""
        return 1
    fi

    print_status "IOMMU is enabled"

    local show_groups
    read -rp "Show IOMMU groups? (useful for GPU/USB passthrough) (y/n) [n]: " -n 1 show_groups
    echo

    if [[ $show_groups =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${BLUE}IOMMU Groups:${NC}"
        echo "─────────────────────────────────────────────────────────"
        for iommu_group in /sys/kernel/iommu_groups/*/devices/*; do
            if [[ -e "$iommu_group" ]]; then
                local group_num
                group_num=$(echo "$iommu_group" | grep -oP 'iommu_groups/\K[0-9]+')
                local device
                device=$(basename "$iommu_group")
                local desc
                desc=$(lspci -nns "$device" 2>/dev/null | cut -d' ' -f2-)
                echo -e "  Group ${GREEN}$group_num${NC}: $device"
                echo "         $desc"
            fi
        done
        echo "─────────────────────────────────────────────────────────"
        echo ""
        print_info "For passthrough, all devices in a group must be passed together"
        echo ""
    fi

    return 0
}

# Configure USB passthrough for a VM
configure_usb_passthrough() {
    print_info "USB Passthrough Configuration"
    echo ""
    echo "You can pass USB devices directly to the macOS VM."
    echo "This is useful for iPhones, USB drives, etc."
    echo ""

    local setup_usb
    read -rp "Configure USB passthrough? (y/n) [n]: " -n 1 setup_usb
    echo

    if [[ ! $setup_usb =~ ^[Yy]$ ]]; then
        return
    fi

    # Check if lsusb is available
    if ! command -v lsusb &> /dev/null; then
        print_warning "lsusb not found. Installing usbutils..."
        mq_sudo pacman -S --needed --noconfirm usbutils
    fi

    echo ""
    echo -e "${BLUE}Available USB devices:${NC}"
    echo "─────────────────────────────────────────────────────────"

    local i=1
    local usb_devices=()
    local usb_names=()

    while IFS= read -r line; do
        local vid pid name
        vid=$(echo "$line" | grep -oP 'ID \K[0-9a-f]{4}' || true)
        pid=$(echo "$line" | grep -oP 'ID [0-9a-f]{4}:\K[0-9a-f]{4}' || true)
        [[ -z "$vid" || -z "$pid" ]] && continue
        # Extract device name (everything after the ID)
        name=${line#*ID [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f][0-9a-f][0-9a-f] }

        # Skip root hubs and internal controllers
        if [[ "$name" =~ "hub" ]] || [[ "$name" =~ "Host Controller" ]]; then
            continue
        fi

        echo "  $i) [$vid:$pid] $name"
        usb_devices+=("$vid:$pid")
        usb_names+=("$name")
        ((i++)) || true
    done < <(lsusb)

    echo "─────────────────────────────────────────────────────────"
    echo ""

    if [[ ${#usb_devices[@]} -eq 0 ]]; then
        print_warning "No passthrough-suitable USB devices found"
        return
    fi

    echo "Enter device numbers to pass through (comma-separated, e.g., 1,3,5)"
    echo "Or press Enter to skip."
    read -rp "Devices: " selected_devices

    if [[ -z "$selected_devices" ]]; then
        return
    fi

    # Parse selected devices and build USB args
    USB_PASSTHROUGH_ARGS=""
    USB_PASSTHROUGH_DEVICES=()

    IFS=',' read -ra selections <<< "$selected_devices"
    for sel in "${selections[@]}"; do
        sel=$(echo "$sel" | tr -d ' ')
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#usb_devices[@]} )); then
            local idx=$((sel - 1))
            local vidpid="${usb_devices[$idx]}"
            local vid="${vidpid%:*}"
            local pid="${vidpid#*:}"
            USB_PASSTHROUGH_ARGS+="    -device usb-host,vendorid=0x${vid},productid=0x${pid}"$'\n'
            USB_PASSTHROUGH_DEVICES+=("${usb_names[$idx]} ($vidpid)")
            print_status "Added: ${usb_names[$idx]}"
        fi
    done

    if [[ -n "$USB_PASSTHROUGH_ARGS" ]]; then
        echo ""
        print_info "USB devices will be passed to this VM"
        print_warning "These devices will be unavailable to the host while VM is running"
    fi
}

# Setup GenSMBIOS for iCloud/iMessage compatibility
setup_gensmbios() {
    print_info "SMBIOS Configuration (for iCloud/iMessage)"
    echo ""
    echo "Generating unique SMBIOS data can help with:"
    echo "  - iCloud sign-in"
    echo "  - iMessage/FaceTime activation"
    echo "  - App Store access"
    echo ""

    local setup_smbios
    read -rp "Generate SMBIOS data? (y/n) [n]: " -n 1 setup_smbios
    echo

    if [[ ! $setup_smbios =~ ^[Yy]$ ]]; then
        return
    fi

    local gensmbios_dir="$INSTALL_DIR/tools/GenSMBIOS"

    # Clone GenSMBIOS if not present
    if [[ ! -d "$gensmbios_dir" ]]; then
        print_info "Downloading GenSMBIOS..."
        mkdir -p "$INSTALL_DIR/tools"
        git clone --depth 1 https://github.com/corpnewt/GenSMBIOS.git "$gensmbios_dir"
    fi

    # Determine appropriate Mac model based on macOS version
    local mac_model
    case "$CURRENT_MACOS_VERSION" in
        high-sierra|mojave|catalina)
            mac_model="iMac19,1"
            ;;
        big-sur|monterey)
            mac_model="iMacPro1,1"
            ;;
        ventura|sonoma|sequoia|tahoe|*)
            mac_model="MacPro7,1"
            ;;
    esac

    echo ""
    echo "Recommended model for $CURRENT_MACOS_DISPLAY_NAME: $mac_model"
    read -rp "Use this model? (y/n) [y]: " -n 1 use_default
    echo

    if [[ ! $use_default =~ ^[Nn]$ ]]; then
        SMBIOS_MODEL="$mac_model"
    else
        echo "Available models: iMac19,1, iMac20,1, iMacPro1,1, MacPro7,1, MacBookPro16,1"
        read -rp "Enter model: " SMBIOS_MODEL
        SMBIOS_MODEL=${SMBIOS_MODEL:-$mac_model}
    fi

    # Generate SMBIOS using macserial if available in OSX-KVM
    local macserial="$INSTALL_DIR/OpenCore/macserial"
    if [[ -x "$macserial" ]]; then
        print_info "Generating SMBIOS data for $SMBIOS_MODEL..."

        local serial_output
        serial_output=$("$macserial" -m "$SMBIOS_MODEL" -g -n 1 2>/dev/null)

        if [[ -n "$serial_output" ]]; then
            SMBIOS_SERIAL=$(echo "$serial_output" | cut -d'|' -f1 | tr -d ' ')
            SMBIOS_MLB=$(echo "$serial_output" | cut -d'|' -f2 | tr -d ' ')
            SMBIOS_UUID=$(uuidgen)

            echo ""
            echo -e "${GREEN}Generated SMBIOS:${NC}"
            echo "  Model:  $SMBIOS_MODEL"
            echo "  Serial: $SMBIOS_SERIAL"
            echo "  MLB:    $SMBIOS_MLB"
            echo "  UUID:   $SMBIOS_UUID"
            echo ""

            # Save to VM directory
            cat > "$CURRENT_VM_DIR/.smbios" << EOF
SMBIOS_MODEL=$SMBIOS_MODEL
SMBIOS_SERIAL=$SMBIOS_SERIAL
SMBIOS_MLB=$SMBIOS_MLB
SMBIOS_UUID=$SMBIOS_UUID
EOF
            print_status "SMBIOS data saved to $CURRENT_VM_DIR/.smbios"
            print_info "You'll need to manually apply these in OpenCore Configurator"
            SMBIOS_GENERATED=true
        else
            print_warning "Failed to generate SMBIOS data"
        fi
    else
        print_warning "macserial not found in OSX-KVM"
        print_info "Run GenSMBIOS manually: python3 $gensmbios_dir/GenSMBIOS.py"
    fi
}

# Configure OpenCore boot arguments
configure_boot_args() {
    print_info "Boot Arguments Configuration"
    echo ""
    echo "Boot arguments customize macOS startup behavior."
    echo ""

    local setup_bootargs
    read -rp "Configure boot arguments? (y/n) [n]: " -n 1 setup_bootargs
    echo

    if [[ ! $setup_bootargs =~ ^[Yy]$ ]]; then
        return
    fi

    echo ""
    echo -e "${BLUE}Common boot arguments:${NC}"
    echo "─────────────────────────────────────────────────────────"
    echo "  1) -v                  Verbose boot (see boot messages)"
    echo "  2) debug=0x100         Debug mode (don't reboot on panic)"
    echo "  3) keepsyms=1          Keep symbols for debugging"
    echo "  4) -no_compat_check    Skip compatibility check (older Macs)"
    echo "  5) amfi_get_out_of_my_way=1  Disable AMFI (for unsigned kexts)"
    echo "─────────────────────────────────────────────────────────"
    echo ""
    echo "  Presets:"
    echo "    D) Debug mode (-v debug=0x100 keepsyms=1)"
    echo "    N) None (clean boot)"
    echo "    C) Custom (enter your own)"
    echo ""

    read -rp "Select options (comma-separated, e.g., 1,2 or D): " bootarg_choice

    BOOT_ARGS=""

    case "$bootarg_choice" in
        [Dd])
            BOOT_ARGS="-v debug=0x100 keepsyms=1"
            ;;
        [Nn])
            BOOT_ARGS=""
            ;;
        [Cc])
            read -rp "Enter boot arguments: " BOOT_ARGS
            ;;
        *)
            IFS=',' read -ra selections <<< "$bootarg_choice"
            for sel in "${selections[@]}"; do
                sel=$(echo "$sel" | tr -d ' ')
                case "$sel" in
                    1) BOOT_ARGS+=" -v" ;;
                    2) BOOT_ARGS+=" debug=0x100" ;;
                    3) BOOT_ARGS+=" keepsyms=1" ;;
                    4) BOOT_ARGS+=" -no_compat_check" ;;
                    5) BOOT_ARGS+=" amfi_get_out_of_my_way=1" ;;
                esac
            done
            BOOT_ARGS=$(echo "$BOOT_ARGS" | xargs)  # Trim whitespace
            ;;
    esac

    if [[ -n "$BOOT_ARGS" ]]; then
        echo ""
        print_status "Boot arguments: $BOOT_ARGS"

        # Save to VM directory
        echo "BOOT_ARGS=\"$BOOT_ARGS\"" >> "$CURRENT_VM_DIR/.vm-config"

        echo ""
        print_info "To apply boot arguments:"
        echo "  1. Boot into macOS"
        echo "  2. Mount the OpenCore EFI partition"
        echo "  3. Edit EFI/OC/config.plist"
        echo "  4. Find NVRAM > Add > 7C436110... > boot-args"
        echo "  5. Add: $BOOT_ARGS"
        echo ""
    fi
}

# Clone OSX-KVM repository
clone_repository() {
    print_info "Setting up OSX-KVM repository..."
    
    if [[ -d "$INSTALL_DIR" ]]; then
        print_warning "OSX-KVM directory already exists at $INSTALL_DIR"
        local update_choice
        read -rp "Do you want to update it? (y/n): " -n 1 update_choice
        echo
        if [[ $update_choice =~ ^[Yy]$ ]]; then
            cd "$INSTALL_DIR" || { print_error "Failed to cd to $INSTALL_DIR"; exit 1; }
            if ! git pull --rebase; then
                print_warning "Git pull failed, continuing with existing version"
            fi
            if ! git submodule update --init --recursive; then
                print_warning "Submodule update failed, continuing anyway"
            fi
            print_status "Repository updated"
        fi
    else
        if ! git clone --depth 1 --recursive https://github.com/kholia/OSX-KVM.git "$INSTALL_DIR"; then
            print_error "Failed to clone OSX-KVM repository"
            exit 1
        fi
        print_status "Repository cloned to $INSTALL_DIR"
    fi
}

# Select and download macOS version
download_macos() {
    local version_arg=""
    local version_choice=""
    local confirmed=false

    while [[ "$confirmed" != "true" ]]; do
        print_info "macOS Version Selection"
        echo ""
        echo -e "${BLUE}Available macOS versions:${NC}"
        echo ""
        echo "  Older versions (lighter, faster):"
        echo "    1) High Sierra (10.13) - 4GB+ RAM, Penryn CPU"
        echo "    2) Mojave (10.14)      - 4GB+ RAM, Penryn CPU"
        echo "    3) Catalina (10.15)    - 4GB+ RAM, Penryn CPU"
        echo ""
        echo "  Modern versions (recommended):"
        echo "    4) Big Sur (11)        - 8GB+ RAM, Penryn CPU"
        echo "    5) Monterey (12)       - 8GB+ RAM, Penryn CPU"
        echo "    6) Ventura (13)        - 8GB+ RAM, Haswell CPU"
        echo "    7) Sonoma (14)         - 8GB+ RAM, Skylake CPU [RECOMMENDED]"
        echo ""
        echo "  Latest versions (may have issues):"
        echo "    8) Sequoia (15)        - 8GB+ RAM, Skylake CPU"
        echo "    9) Tahoe (26)          - 16GB+ RAM, Skylake CPU [BETA]"
        echo ""

        # Clear any buffered input
        read -r -t 0.1 -n 10000 _discard 2>/dev/null || true

        read -rp "Select macOS version (1-9) [7]: " version_choice
        version_choice=${version_choice:-7}
        # Normalize input: trim whitespace and convert to lowercase
        version_choice=$(echo "$version_choice" | tr '[:upper:]' '[:lower:]' | xargs)

        # Map choice to version name (accept both numbers and names)
        case $version_choice in
            1|high-sierra|highsierra|sierra)
                version_arg="high-sierra" ;;
            2|mojave)
                version_arg="mojave" ;;
            3|catalina)
                version_arg="catalina" ;;
            4|big-sur|bigsur)
                version_arg="big-sur" ;;
            5|monterey)
                version_arg="monterey" ;;
            6|ventura)
                version_arg="ventura" ;;
            7|sonoma)
                version_arg="sonoma" ;;
            8|sequoia)
                version_arg="sequoia" ;;
            9|tahoe)
                version_arg="tahoe" ;;
            *)
                print_warning "Invalid selection '$version_choice', defaulting to Sonoma"
                version_arg="sonoma" ;;
        esac

        # Confirm selection
        local display_name
        display_name=$(get_macos_display_name "$version_arg")
        echo ""
        print_info "You selected: $display_name"
        read -rp "Is this correct? (y/n) [y]: " confirm
        confirm=${confirm:-y}
        if [[ $confirm =~ ^[Yy]$ ]]; then
            confirmed=true
        else
            echo ""
        fi
    done

    # Set global version variables
    CURRENT_MACOS_VERSION="$version_arg"
    CURRENT_MACOS_DISPLAY_NAME=$(get_macos_display_name "$version_arg")

    # Prompt for VM name (default to version name)
    echo ""
    print_info "VM Name"
    echo "  This identifies your VM. You can have multiple VMs of the same macOS version."
    echo "  Default: $version_arg"
    echo ""
    read -rp "Enter VM name [$version_arg]: " vm_name
    vm_name=${vm_name:-$version_arg}

    # Sanitize VM name (lowercase, replace spaces with dashes)
    vm_name=$(echo "$vm_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-_')

    # Check if VM already exists and handle name conflicts
    CURRENT_VM_NAME="$vm_name"
    CURRENT_VM_DIR="$VMS_DIR/$vm_name"

    while [[ -d "$CURRENT_VM_DIR" ]]; do
        print_warning "A VM named '$vm_name' already exists!"
        echo ""
        echo "  1) Overwrite existing VM"
        echo "  2) Choose a different name"
        echo ""
        read -rp "Select option (1 or 2): " -n 1 overwrite_choice
        echo

        if [[ $overwrite_choice == "1" ]]; then
            rm -rf "$CURRENT_VM_DIR"
            break
        else
            read -rp "Enter a new VM name: " vm_name
            vm_name=$(echo "$vm_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-_')
            if [[ -z "$vm_name" ]]; then
                vm_name="$version_arg"
            fi
            CURRENT_VM_NAME="$vm_name"
            CURRENT_VM_DIR="$VMS_DIR/$vm_name"
        fi
    done

    # Create VM directory
    mkdir -p "$CURRENT_VM_DIR"
    print_status "Created VM directory: $CURRENT_VM_DIR"

    # Save version info
    echo "$CURRENT_MACOS_DISPLAY_NAME" > "$CURRENT_VM_DIR/.macos-version"

    cd "$INSTALL_DIR" || { print_error "Failed to cd to $INSTALL_DIR"; exit 1; }

    # Check for python3
    if ! command -v python3 &> /dev/null; then
        print_error "python3 not found. Please install python."
        exit 1
    fi

    # Check that fetch script exists
    if [[ ! -f "./fetch-macOS-v2.py" ]]; then
        print_error "fetch-macOS-v2.py not found in OSX-KVM repo"
        print_info "The repository may be incomplete. Try removing $INSTALL_DIR and re-running."
        exit 1
    fi

    print_info "Downloading $CURRENT_MACOS_DISPLAY_NAME recovery image..."
    print_info "This may take a while depending on your internet connection..."

    # Clean up any previous download to avoid using cached/wrong version
    rm -rf com.apple.recovery.boot 2>/dev/null || true
    rm -f BaseSystem.dmg BaseSystem.chunklist 2>/dev/null || true

    # Debug: show the exact command being run
    print_info "Running: python3 ./fetch-macOS-v2.py -s \"$CURRENT_MACOS_VERSION\""

    # Run the fetch script
    # Note: The -s shortname flag ignores -o and always outputs to current directory
    if ! python3 ./fetch-macOS-v2.py -s "$CURRENT_MACOS_VERSION"; then
        print_error "Failed to download macOS recovery image"
        exit 1
    fi

    # Find the downloaded DMG file
    # The -s flag downloads to current directory (.), not com.apple.recovery.boot
    print_info "Looking for downloaded DMG file..."
    local dmg_path=""

    # Check current directory first (where -s shortname saves)
    if [[ -f "./BaseSystem.dmg" ]]; then
        dmg_path="./BaseSystem.dmg"
    elif [[ -f "com.apple.recovery.boot/BaseSystem.dmg" ]]; then
        dmg_path="com.apple.recovery.boot/BaseSystem.dmg"
    else
        # Look for any .dmg file in current dir or subdirs
        dmg_path=$(find . -maxdepth 2 -name "*.dmg" -type f 2>/dev/null | head -1)
    fi

    if [[ -z "$dmg_path" || ! -f "$dmg_path" ]]; then
        print_error "No DMG file found"
        print_info "Contents of current directory:"
        ls -la ./*.dmg 2>/dev/null || echo "  No .dmg files found"
        exit 1
    fi

    print_status "Found DMG: $dmg_path"

    # Verify dmg2img is available
    if ! command -v dmg2img &> /dev/null; then
        print_error "dmg2img not found. Try: yay -S dmg2img"
        exit 1
    fi

    # Convert DMG to IMG
    print_info "Converting $(basename "$dmg_path") to BaseSystem.img..."
    if ! dmg2img -i "$dmg_path" "$CURRENT_VM_DIR/BaseSystem.img"; then
        print_error "Failed to convert DMG to IMG"
        print_info "This can happen if the DMG is corrupted or dmg2img has issues"
        print_info "Try: rm -rf com.apple.recovery.boot && re-run the script"
        exit 1
    fi

    # Verify the output file was created
    if [[ ! -f "$CURRENT_VM_DIR/BaseSystem.img" ]]; then
        print_error "BaseSystem.img was not created"
        exit 1
    fi

    print_status "macOS image ready: $CURRENT_VM_DIR/BaseSystem.img"
}

# Configure VM resources (RAM and CPU)
configure_vm_resources() {
    print_info "VM Resource Configuration for $CURRENT_MACOS_DISPLAY_NAME"

    # Get system info for recommendations
    local total_ram_kb
    total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_gb=$((total_ram_kb / 1024 / 1024))
    local recommended_ram=$((total_ram_gb / 2))
    [[ $recommended_ram -lt 4 ]] && recommended_ram=4
    [[ $recommended_ram -gt 16 ]] && recommended_ram=16

    local total_cores
    total_cores=$(nproc)
    local recommended_cores=$((total_cores / 2))
    [[ $recommended_cores -lt 2 ]] && recommended_cores=2
    [[ $recommended_cores -gt 8 ]] && recommended_cores=8

    echo ""
    echo "Your system: ${total_ram_gb}GB RAM, ${total_cores} CPU cores"
    echo ""
    echo -e "${BLUE}RAM Configuration:${NC}"
    echo "  - Minimum for macOS: 4GB"
    echo "  - Recommended: 8GB+"
    echo "  - For development: 16GB+"
    echo "  - Your system has: ${total_ram_gb}GB"
    echo ""

    read -rp "RAM for this VM in GB [${recommended_ram}]: " vm_ram
    vm_ram=${vm_ram:-$recommended_ram}

    # Validate RAM input
    if ! [[ "$vm_ram" =~ ^[0-9]+$ ]] || [[ "$vm_ram" -lt 2 ]]; then
        print_warning "Invalid RAM value, using ${recommended_ram}GB"
        vm_ram=$recommended_ram
    fi

    if [[ "$vm_ram" -gt "$total_ram_gb" ]]; then
        print_warning "Requested RAM exceeds system RAM, using ${recommended_ram}GB"
        vm_ram=$recommended_ram
    fi

    # Convert to MiB for QEMU
    CURRENT_VM_RAM=$((vm_ram * 1024))

    echo ""
    echo -e "${BLUE}CPU Configuration:${NC}"
    echo "  - Minimum for macOS: 2 cores"
    echo "  - Recommended: 4 cores"
    echo "  - For development: 6-8 cores"
    echo "  - Your system has: ${total_cores} cores"
    echo ""

    read -rp "CPU cores for this VM [${recommended_cores}]: " vm_cores
    vm_cores=${vm_cores:-$recommended_cores}

    # Validate cores input
    if ! [[ "$vm_cores" =~ ^[0-9]+$ ]] || [[ "$vm_cores" -lt 1 ]]; then
        print_warning "Invalid core count, using ${recommended_cores}"
        vm_cores=$recommended_cores
    fi

    if [[ "$vm_cores" -gt "$total_cores" ]]; then
        print_warning "Requested cores exceed system cores, using ${recommended_cores}"
        vm_cores=$recommended_cores
    fi

    CURRENT_VM_CORES=$vm_cores

    # Calculate threads (use 2 threads per core if hyperthreading likely available)
    if [[ $total_cores -ge 4 ]]; then
        CURRENT_VM_THREADS=$((vm_cores * 2))
    else
        CURRENT_VM_THREADS=$vm_cores
    fi

    echo ""
    print_status "VM will use: ${vm_ram}GB RAM, ${vm_cores} CPU cores"

    # Save config to VM directory
    cat > "$CURRENT_VM_DIR/.vm-config" << EOF
MACOS_VERSION=$CURRENT_MACOS_VERSION
RAM_GB=$vm_ram
RAM_MIB=$CURRENT_VM_RAM
CPU_CORES=$CURRENT_VM_CORES
CPU_THREADS=$CURRENT_VM_THREADS
EOF
}

# Create virtual disk
create_virtual_disk() {
    print_info "Virtual Disk Setup for $CURRENT_MACOS_DISPLAY_NAME ($CURRENT_VM_NAME)"

    local disk_path="$CURRENT_VM_DIR/mac_hdd_ng.img"

    if [[ -f "$disk_path" ]]; then
        print_warning "Virtual disk already exists for this VM"
        local disk_choice
        read -rp "Do you want to create a new one? This will DELETE the existing disk! (y/n): " -n 1 disk_choice
        echo
        if [[ ! $disk_choice =~ ^[Yy]$ ]]; then
            print_status "Keeping existing virtual disk"
            return
        fi
        rm -f "$disk_path"
    fi

    echo ""
    echo "Recommended disk sizes:"
    echo "  - Minimum: 64GB"
    echo "  - Recommended: 128GB"
    echo "  - For development: 256GB+"
    echo ""

    read -rp "Enter disk size in GB [128]: " disk_size
    disk_size=${disk_size:-128}

    print_info "Creating ${disk_size}GB virtual disk..."
    qemu-img create -f qcow2 "$disk_path" "${disk_size}G"
    print_status "Virtual disk created: $disk_path"
}

# Setup Samba shared folder
setup_samba_share() {
    print_info "Shared Folder Setup"
    echo ""
    read -rp "Do you want to set up a shared folder with macOS? (y/n) [y]: " setup_share
    setup_share=${setup_share:-y}
    
    if [[ ! $setup_share =~ ^[Yy]$ ]]; then
        print_info "Skipping shared folder setup"
        return
    fi
    
    # Install Samba if needed
    if ! pacman -Qi samba > /dev/null 2>&1; then
        print_info "Installing Samba..."
        mq_sudo pacman -S --needed --noconfirm samba
    fi
    
    # Create shared directory
    local share_dir="$HOME/macos-shared"
    read -rp "Shared folder path [$share_dir]: " custom_share_dir
    share_dir=${custom_share_dir:-$share_dir}
    
    mkdir -p "$share_dir"
    chmod 755 "$share_dir"
    print_status "Created shared folder: $share_dir"
    
    # Backup existing smb.conf if it exists
    if [[ -f /etc/samba/smb.conf ]]; then
        mq_sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup
        print_status "Backed up existing smb.conf to smb.conf.backup"
    fi

    # Create Samba config
    print_info "Configuring Samba..."

    # Check if smb.conf exists and has content
    if [[ -f /etc/samba/smb.conf ]] && [[ -s /etc/samba/smb.conf ]]; then
        # Check if macos-shared section already exists
        if grep -q '^\[macos-shared\]' /etc/samba/smb.conf; then
            print_warning "macos-shared share already exists in smb.conf, skipping"
        else
            # Append the new share to existing config
            print_info "Appending macos-shared to existing Samba config..."
            mq_sudo tee -a /etc/samba/smb.conf > /dev/null << EOF

[macos-shared]
   comment = macOS VM Shared Folder
   path = $share_dir
   browseable = yes
   read only = no
   writable = yes
   guest ok = no
   valid users = $USER
   create mask = 0755
   directory mask = 0755
EOF
        fi
    else
        # Create new smb.conf
        mq_sudo tee /etc/samba/smb.conf > /dev/null << EOF
[global]
   workgroup = WORKGROUP
   server string = Samba Server
   security = user
   map to guest = Bad User
   dns proxy = no

[macos-shared]
   comment = macOS VM Shared Folder
   path = $share_dir
   browseable = yes
   read only = no
   writable = yes
   guest ok = no
   valid users = $USER
   create mask = 0755
   directory mask = 0755
EOF
    fi
    
    # Set Samba password for user
    print_info "Setting Samba password for user '$USER'"
    print_info "This can be different from your login password"
    mq_sudo smbpasswd -a "$USER"
    
    # Enable and start Samba services
    mq_sudo systemctl enable smb nmb
    mq_sudo systemctl restart smb nmb
    
    # Get local IP for instructions (try multiple methods for robustness)
    local local_ip=""
    local_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || true)
    [[ -z "$local_ip" ]] && local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$local_ip" ]] && local_ip=$(ip addr show 2>/dev/null | grep -oP 'inet \K[0-9.]+' | grep -v '127.0.0.1' | head -1)
    [[ -z "$local_ip" ]] && local_ip="YOUR_IP_ADDRESS"
    
    print_status "Samba configured successfully"
    
    # Save connection info for later display
    SAMBA_SHARE_PATH="$share_dir"
    SAMBA_IP="$local_ip"
}

# Get version-specific QEMU configuration
# Returns: cpu_args, net_device, display_args, boot_select, boot_notes
get_version_config() {
    local version="$1"

    case "$version" in
        high-sierra)
            # High Sierra (10.13) - oldest supported, needs Penryn CPU
            VERSION_CPU='Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
            VERSION_NET='vmxnet3'
            VERSION_DISPLAY='-device vmware-svga'
            VERSION_BOOT_SELECT='macOS Base System'
            VERSION_BOOT_NOTES='High Sierra may take longer to boot. Be patient.'
            ;;
        mojave)
            # Mojave (10.14)
            VERSION_CPU='Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
            VERSION_NET='vmxnet3'
            VERSION_DISPLAY='-device vmware-svga'
            VERSION_BOOT_SELECT='macOS Base System'
            VERSION_BOOT_NOTES=''
            ;;
        catalina)
            # Catalina (10.15)
            VERSION_CPU='Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
            VERSION_NET='virtio-net-pci'
            VERSION_DISPLAY='-device vmware-svga'
            VERSION_BOOT_SELECT='macOS Base System'
            VERSION_BOOT_NOTES=''
            ;;
        big-sur)
            # Big Sur (11)
            VERSION_CPU='Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
            VERSION_NET='virtio-net-pci'
            VERSION_DISPLAY='-display gtk,gl=on -vga virtio'
            VERSION_BOOT_SELECT='macOS Base System'
            VERSION_BOOT_NOTES=''
            ;;
        monterey)
            # Monterey (12)
            VERSION_CPU='Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
            VERSION_NET='virtio-net-pci'
            VERSION_DISPLAY='-display gtk,gl=on -vga virtio'
            VERSION_BOOT_SELECT='macOS Base System'
            VERSION_BOOT_NOTES=''
            ;;
        ventura)
            # Ventura (13) - needs newer CPU model
            VERSION_CPU='Haswell-noTSX,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
            VERSION_NET='virtio-net-pci'
            VERSION_DISPLAY='-display gtk,gl=on -vga virtio'
            VERSION_BOOT_SELECT='macOS Base System'
            VERSION_BOOT_NOTES='Ventura requires more resources. 8GB+ RAM recommended.'
            ;;
        sonoma)
            # Sonoma (14) - needs Skylake CPU
            VERSION_CPU='Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
            VERSION_NET='virtio-net-pci'
            VERSION_DISPLAY='-display gtk,gl=on -vga virtio'
            VERSION_BOOT_SELECT='macOS Base System'
            VERSION_BOOT_NOTES='Sonoma requires 8GB+ RAM and may be slow on first boot.'
            ;;
        sequoia)
            # Sequoia (15) - needs Skylake CPU
            VERSION_CPU='Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
            VERSION_NET='virtio-net-pci'
            VERSION_DISPLAY='-display gtk,gl=on -vga virtio'
            VERSION_BOOT_SELECT='macOS Base System'
            VERSION_BOOT_NOTES='Sequoia is newest. Requires 8GB+ RAM, 16GB recommended.'
            ;;
        tahoe)
            # Tahoe (26) - Beta, needs Skylake CPU
            VERSION_CPU='Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
            VERSION_NET='virtio-net-pci'
            VERSION_DISPLAY='-display gtk,gl=on -vga virtio'
            VERSION_BOOT_SELECT='macOS Base System'
            VERSION_BOOT_NOTES='Tahoe is BETA software. Expect issues. 16GB RAM recommended.'
            ;;
        *)
            # Default/fallback - use Penryn for safety
            VERSION_CPU='Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'
            VERSION_NET='virtio-net-pci'
            VERSION_DISPLAY='-display gtk,gl=on -vga virtio'
            VERSION_BOOT_SELECT='macOS Base System'
            VERSION_BOOT_NOTES=''
            ;;
    esac
}

# Generate a unique SSH port for a VM based on its name
generate_ssh_port() {
    # Hash the VM name to get a consistent port between 10022-10999
    local hash
    # Use full md5 hex and convert to decimal to ensure we have enough digits
    hash=$(echo -n "$1" | md5sum | cut -c1-8)
    local decimal=$((16#$hash % 978))
    local port=$((10022 + decimal))
    echo "$port"
}

# Generate a unique MAC address for a VM based on its name
generate_mac_address() {
    # Use the VM name to generate consistent last 3 octets
    local hash
    hash=$(echo -n "$1" | md5sum)
    local oct1=${hash:0:2}
    local oct2=${hash:2:2}
    local oct3=${hash:4:2}
    echo "52:54:00:$oct1:$oct2:$oct3"
}

# Create launcher script
create_launcher() {
    print_info "Creating launcher script for $CURRENT_MACOS_DISPLAY_NAME..."

    local launcher="$CURRENT_VM_DIR/start-macos.sh"

    # Generate unique network settings for this VM
    local ssh_port
    ssh_port=$(generate_ssh_port "$CURRENT_VM_NAME")
    local mac_addr
    mac_addr=$(generate_mac_address "$CURRENT_VM_NAME")

    # Use configured values or defaults
    local ram_mib=${CURRENT_VM_RAM:-8192}
    local cpu_cores=${CURRENT_VM_CORES:-4}
    local cpu_threads=${CURRENT_VM_THREADS:-8}
    local ram_gb=$((ram_mib / 1024))

    # Get version-specific configuration
    get_version_config "$CURRENT_MACOS_VERSION"

    cat > "$launcher" << EOF
#!/bin/bash

# $CURRENT_MACOS_DISPLAY_NAME VM Launcher
# VM Name: $CURRENT_VM_NAME
# macOS Version: $CURRENT_MACOS_VERSION
# Resources: ${ram_gb}GB RAM, ${cpu_cores} CPU cores
# SSH Port: $ssh_port (ssh -p $ssh_port localhost)

OSX_KVM_DIR="$INSTALL_DIR"
VM_DIR="$CURRENT_VM_DIR"

cd "\$OSX_KVM_DIR" || { echo "Error: OSX-KVM directory not found"; exit 1; }

# Check if KVM is accessible
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "Error: Cannot access /dev/kvm"
    echo "Try: sudo chmod 666 /dev/kvm"
    exit 1
fi

# Set ignore_msrs if not set
if [[ "\$(cat /sys/module/kvm/parameters/ignore_msrs)" != "1" ]]; then
    echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null
fi

# Check required files exist
if [[ ! -f "\$VM_DIR/mac_hdd_ng.img" ]]; then
    echo "Error: Virtual disk not found at \$VM_DIR/mac_hdd_ng.img"
    exit 1
fi

if [[ ! -f "\$VM_DIR/BaseSystem.img" ]]; then
    echo "Error: macOS base image not found at \$VM_DIR/BaseSystem.img"
    exit 1
fi

# VM Resource Configuration
# Edit these values to change RAM/CPU allocation
ALLOCATED_RAM="$ram_mib"  # MiB (${ram_gb}GB)
CPU_SOCKETS="1"
CPU_CORES="$cpu_cores"
CPU_THREADS="$cpu_threads"

REPO_PATH="\$OSX_KVM_DIR"
OVMF_DIR="\$REPO_PATH"

# Unique network settings for this VM
SSH_PORT="$ssh_port"
MAC_ADDR="$mac_addr"

# Display boot information
echo "========================================"
echo " $CURRENT_MACOS_DISPLAY_NAME"
echo "========================================"
echo ""
echo "Resources: \$((ALLOCATED_RAM / 1024))GB RAM, \$CPU_CORES CPU cores"
echo "SSH Port:  \$SSH_PORT (after enabling Remote Login in macOS)"
echo ""
echo "----------------------------------------"
echo " FIRST BOOT INSTRUCTIONS"
echo "----------------------------------------"
echo "1. In OpenCore menu, select: '$VERSION_BOOT_SELECT'"
echo "2. Wait for Recovery to load (may take a few minutes)"
echo "3. Open 'Disk Utility' from the menu"
echo "4. Select the QEMU HARDDISK and click 'Erase'"
echo "5. Name: 'Macintosh HD', Format: 'APFS', click 'Erase'"
echo "6. Close Disk Utility, select 'Reinstall macOS'"
echo "7. Follow the installation wizard"
echo ""
echo "AFTER INSTALLATION:"
echo "  Select 'Macintosh HD' in OpenCore menu to boot"
echo ""
EOF

    # Add version-specific notes if any
    if [[ -n "$VERSION_BOOT_NOTES" ]]; then
        cat >> "$launcher" << EOF
echo "NOTE: $VERSION_BOOT_NOTES"
echo ""
EOF
    fi

    # Add USB passthrough info if configured
    if [[ -n "$USB_PASSTHROUGH_ARGS" ]]; then
        cat >> "$launcher" << EOF
echo "USB Passthrough enabled for:"
EOF
        for dev in "${USB_PASSTHROUGH_DEVICES[@]}"; do
            cat >> "$launcher" << EOF
echo "  - $dev"
EOF
        done
        cat >> "$launcher" << EOF
echo ""
EOF
    fi

    cat >> "$launcher" << 'EOF'
# Check for Samba share and display connection info
if grep -q '^\[macos-shared\]' /etc/samba/smb.conf 2>/dev/null; then
    SAMBA_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -n "$SAMBA_IP" ]]; then
        echo "----------------------------------------"
        echo " SHARED FOLDER"
        echo "----------------------------------------"
        echo "In macOS: Finder → Go → Connect to Server"
        echo "Enter: smb://$SAMBA_IP/macos-shared"
        echo "Username: $USER"
        echo ""
    fi
fi
EOF

    cat >> "$launcher" << EOF
echo "Press Ctrl+Alt+G to release mouse from VM"
echo "========================================"
echo ""

# shellcheck disable=SC2054
args=(
    -enable-kvm -m "\$ALLOCATED_RAM" -cpu $VERSION_CPU
    -machine q35
    -usb -device usb-kbd -device usb-tablet
    -smp "\$CPU_THREADS",cores="\$CPU_CORES",sockets="\$CPU_SOCKETS"
    -device usb-ehci,id=ehci
    -device nec-usb-xhci,id=xhci
    -global nec-usb-xhci.msi=off
    -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
    -drive if=pflash,format=raw,readonly=on,file="\$OVMF_DIR/OVMF_CODE_4M.fd"
    -drive if=pflash,format=raw,file="\$OVMF_DIR/OVMF_VARS-1920x1080.fd"
    -smbios type=2
    -device ich9-intel-hda -device hda-duplex
    -device ich9-ahci,id=sata
    -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file="\$REPO_PATH/OpenCore/OpenCore.qcow2"
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot
    -device ide-hd,bus=sata.3,drive=InstallMedia
    -drive id=InstallMedia,if=none,file="\$VM_DIR/BaseSystem.img",format=raw
    -drive id=MacHDD,if=none,file="\$VM_DIR/mac_hdd_ng.img",format=qcow2
    -device ide-hd,bus=sata.4,drive=MacHDD
    -netdev "user,id=net0,hostfwd=tcp::\${SSH_PORT}-:22" -device "$VERSION_NET,netdev=net0,id=net0,mac=\${MAC_ADDR}"
EOF

    # Add USB passthrough devices if configured
    if [[ -n "$USB_PASSTHROUGH_ARGS" ]]; then
        echo "    # USB Passthrough devices" >> "$launcher"
        echo -n "$USB_PASSTHROUGH_ARGS" >> "$launcher"
    fi

    cat >> "$launcher" << EOF
    -monitor stdio
    $VERSION_DISPLAY
)

qemu-system-x86_64 "\${args[@]}"
EOF

    chmod +x "$launcher"
    print_status "Launcher script created: $launcher"
    print_info "This VM's SSH port: $ssh_port"

    # Show USB passthrough summary
    if [[ -n "$USB_PASSTHROUGH_ARGS" ]]; then
        print_info "USB passthrough configured for ${#USB_PASSTHROUGH_DEVICES[@]} device(s)"
    fi
}

# Create desktop entry
create_desktop_entry() {
    print_info "Creating desktop entry for $CURRENT_MACOS_DISPLAY_NAME..."

    local desktop_dir="$HOME/.local/share/applications"
    mkdir -p "$desktop_dir"

    # Use VM name for unique desktop file, display name for menu entry
    local desktop_file="$desktop_dir/macos-vm-${CURRENT_VM_NAME}.desktop"

    # Detect available terminal emulator
    local terminal_cmd
    if command -v alacritty &> /dev/null; then
        terminal_cmd="alacritty -e"
    elif command -v kitty &> /dev/null; then
        terminal_cmd="kitty"
    elif command -v gnome-terminal &> /dev/null; then
        terminal_cmd="gnome-terminal --"
    elif command -v konsole &> /dev/null; then
        terminal_cmd="konsole -e"
    elif command -v xterm &> /dev/null; then
        terminal_cmd="xterm -e"
    else
        # Fallback to using Terminal=true
        cat > "$desktop_file" << EOF
[Desktop Entry]
Name=$CURRENT_MACOS_DISPLAY_NAME
Comment=Run $CURRENT_MACOS_DISPLAY_NAME in QEMU/KVM ($CURRENT_VM_NAME)
Exec=$CURRENT_VM_DIR/start-macos.sh
Icon=computer
Terminal=true
Type=Application
Categories=System;Emulator;
EOF
        print_status "Desktop entry created: $CURRENT_MACOS_DISPLAY_NAME (using default terminal)"
        return
    fi

    cat > "$desktop_file" << EOF
[Desktop Entry]
Name=$CURRENT_MACOS_DISPLAY_NAME
Comment=Run $CURRENT_MACOS_DISPLAY_NAME in QEMU/KVM ($CURRENT_VM_NAME)
Exec=$terminal_cmd $CURRENT_VM_DIR/start-macos.sh
Icon=computer
Terminal=false
Type=Application
Categories=System;Emulator;
EOF

    print_status "Desktop entry created: $CURRENT_MACOS_DISPLAY_NAME"
}

# Print final instructions
print_instructions() {
    local ram_gb=$((CURRENT_VM_RAM / 1024))

    # Get version-specific configuration
    get_version_config "$CURRENT_MACOS_VERSION"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║               Installation Complete!                      ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}VM Created:${NC}  $CURRENT_MACOS_DISPLAY_NAME ($CURRENT_VM_NAME)"
    echo -e "${BLUE}Location:${NC}    $CURRENT_VM_DIR"
    echo -e "${BLUE}Resources:${NC}   ${ram_gb}GB RAM, ${CURRENT_VM_CORES} CPU cores"
    echo ""
    echo -e "${BLUE}To start this VM:${NC}"
    echo "  $CURRENT_VM_DIR/start-macos.sh"
    echo ""
    echo -e "${BLUE}Or use the app menu:${NC} '$CURRENT_MACOS_DISPLAY_NAME'"
    echo ""
    echo -e "${BLUE}To create another VM or manage existing VMs:${NC}"
    echo "  Press Super+Alt+A for the VM Manager TUI"
    echo "  Or run: $0"
    echo ""

    # Check if Samba is configured (either from this session or previously)
    local smb_ip="${SAMBA_IP:-}"
    local smb_path="${SAMBA_SHARE_PATH:-$HOME/macos-shared}"

    # If not set this session, try to detect existing config
    if [[ -z "$smb_ip" ]] && grep -q '^\[macos-shared\]' /etc/samba/smb.conf 2>/dev/null; then
        smb_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || true)
        [[ -z "$smb_ip" ]] && smb_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "$smb_ip" ]] && smb_ip="YOUR_IP"
        # Try to get the path from smb.conf
        smb_path=$(grep -A5 '^\[macos-shared\]' /etc/samba/smb.conf 2>/dev/null | grep 'path' | awk '{print $3}' || echo "$HOME/macos-shared")
    fi

    if [[ -n "$smb_ip" ]]; then
        echo -e "${BLUE}Shared Folder:${NC}"
        echo "  Linux folder: $smb_path"
        echo "  In macOS: Finder → Go → Connect to Server"
        echo "  Enter: smb://$smb_ip/macos-shared"
        echo "  Username: $USER"
        echo "  Password: (the Samba password you set)"
        echo ""
    fi

    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                   FIRST BOOT INSTRUCTIONS${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  1. In OpenCore boot menu, select: ${GREEN}'$VERSION_BOOT_SELECT'${NC}"
    echo "  2. Wait for Recovery to load (may take a few minutes)"
    echo "  3. Open 'Disk Utility' from the menu"
    echo "  4. Select the QEMU HARDDISK and click 'Erase'"
    echo "  5. Name: 'Macintosh HD', Format: 'APFS', click 'Erase'"
    echo "  6. Close Disk Utility, select 'Reinstall macOS'"
    echo "  7. Follow the installation wizard"
    echo "  8. Installation takes 30-60 minutes, VM reboots several times"
    echo ""
    echo -e "  ${GREEN}AFTER INSTALLATION:${NC}"
    echo "  Select 'Macintosh HD' in OpenCore menu to boot normally"
    echo ""

    if [[ -n "$VERSION_BOOT_NOTES" ]]; then
        echo -e "  ${YELLOW}NOTE: $VERSION_BOOT_NOTES${NC}"
        echo ""
    fi

    # Show USB passthrough info if configured
    if [[ -n "$USB_PASSTHROUGH_ARGS" ]]; then
        echo -e "${BLUE}USB Passthrough:${NC}"
        for dev in "${USB_PASSTHROUGH_DEVICES[@]}"; do
            echo "  - $dev"
        done
        echo ""
    fi

    # Show SMBIOS info if generated
    if [[ "$SMBIOS_GENERATED" == "true" ]]; then
        echo -e "${BLUE}SMBIOS (for iCloud/iMessage):${NC}"
        echo "  Model:  $SMBIOS_MODEL"
        echo "  Serial: $SMBIOS_SERIAL"
        echo "  Config: $CURRENT_VM_DIR/.smbios"
        echo "  (Apply these in OpenCore config.plist after first boot)"
        echo ""
    fi

    # Show boot args if configured
    if [[ -n "$BOOT_ARGS" ]]; then
        echo -e "${BLUE}Boot Arguments:${NC} $BOOT_ARGS"
        echo "  (Apply in OpenCore config.plist → NVRAM → boot-args)"
        echo ""
    fi

    echo -e "${YELLOW}Tips:${NC}"
    echo "  - Press Ctrl+Alt+G to release mouse from VM"
    echo "  - Be patient - first boot and installation are slow"
    echo "  - To change RAM/CPU: edit values in start-macos.sh"
    echo ""

    if [[ "$NEEDS_RELOGIN" == "true" ]]; then
        echo -e "${RED}IMPORTANT:${NC} You need to log out and back in before running the VM!"
        echo "           This is required for the group permissions to take effect."
        echo ""
    fi
}

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create the TUI manager script
setup_tui_script() {
    print_info "Creating TUI manager script..."

    local tui_script="$SCRIPT_DIR/macos-vm-tui.sh"

    cat > "$tui_script" << 'TUIEOF'
#!/bin/bash
set -Euo pipefail

# =============================================================================
# macOS VM Manager TUI
# =============================================================================

INSTALL_DIR="$HOME/OSX-KVM"
VMS_DIR="$INSTALL_DIR/vms"
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
TUIEOF

    chmod +x "$tui_script"
    print_status "TUI script created: $tui_script"
}

# Create the TUI launcher script (detects terminal)
setup_tui_launcher() {
    print_info "Creating TUI launcher..."

    local launcher="$SCRIPT_DIR/launch-macos-tui.sh"

    cat > "$launcher" << 'EOF'
#!/bin/bash
# Launcher for macOS VM TUI - detects available terminal

# Self-locating: works wherever the scripts are deployed (~/.local/bin or a clone).
TUI_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/macos-vm-tui.sh"
CLASS="org.omarchy.MacosVmTui"

if command -v ghostty &>/dev/null; then
    exec ghostty --class="$CLASS" -e "$TUI_SCRIPT"
elif command -v kitty &>/dev/null; then
    exec kitty --class="$CLASS" -e "$TUI_SCRIPT"
elif command -v alacritty &>/dev/null; then
    exec alacritty --class "$CLASS" -e "$TUI_SCRIPT"
else
    notify-send "macOS VM Manager" "No supported terminal found (ghostty, kitty, alacritty)"
    exit 1
fi
EOF

    chmod +x "$launcher"
    print_status "TUI launcher created: $launcher"
}

# Hyprland keybinding + window rule for the TUI are OWNED by
# setup-macos-vm.sh (marker blocks in bindings.lua + hyprland.lua).
# Omarchy uses bindings.lua — the old bindings.conf appends do not exist here.
setup_keybinding() {
    print_status "Keybinding for the VM manager TUI is managed by setup-macos-vm.sh (Super+Alt+A)"
}

# Run setup for a new VM (after base system is configured)
setup_new_vm() {
    download_macos
    configure_vm_resources
    create_virtual_disk
    setup_samba_share
    configure_usb_passthrough
    setup_gensmbios
    configure_boot_args
    create_launcher
    create_desktop_entry
    print_instructions
}

# Ensure TUI files exist (called on every run, always regenerates to pick up updates)
ensure_tui_files() {
    setup_tui_script
    setup_tui_launcher
}

# Main installation flow
main() {
    print_banner

    check_not_root

    NEEDS_RELOGIN=false

    # Always ensure dependencies are installed first (functions are idempotent)
    install_packages
    configure_groups
    configure_services
    configure_kvm

    # Now check system capabilities (after packages are installed)
    check_cpu_support
    check_kvm

    # Clone repo if not present
    if [[ ! -d "$INSTALL_DIR" ]]; then
        echo ""
        print_info "Setting up OSX-KVM for the first time..."
        echo ""
        check_iommu  # Optional: check IOMMU for passthrough capabilities
        clone_repository
    fi

    # Create VMs directory
    mkdir -p "$VMS_DIR"

    # Ensure TUI files exist
    ensure_tui_files
    setup_tui_script
    setup_tui_launcher
    setup_keybinding

    # Check for legacy installation and migrate if needed
    if check_legacy_installation; then
        migrate_legacy_installation
    fi

    # Installation complete - direct user to TUI
    echo ""
    print_status "Installation complete!"
    echo ""
    print_info "To create and manage macOS VMs:"
    echo "  - Press Super+Alt+A to open the VM Manager"
    echo "  - Or run: $SCRIPT_DIR/launch-macos-tui.sh"
    echo ""

    if [[ "$NEEDS_RELOGIN" == "true" ]]; then
        print_warning "Please log out and back in for group permissions to take effect."
        echo ""
    fi
}

# Create VM mode (called from TUI)
create_vm_mode() {
    print_banner

    check_not_root
    check_cpu_support
    check_kvm

    # Ensure VMS_DIR exists
    mkdir -p "$VMS_DIR"

    setup_new_vm
}

# Parse arguments and run
case "${1:-}" in
    --create-vm)
        create_vm_mode
        ;;
    *)
        main "$@"
        ;;
esac
