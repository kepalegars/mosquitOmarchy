# Omarchy VM module (`scripts/omarchy-vm/`)

Run Omarchy inside an Omarchy virtual machine (QEMU/KVM + UEFI/OVMF), built
from the **official Omarchy ISO**. Useful as a disposable sandbox, for testing,
or for demoing before installing on bare metal.

## What the module provides

- `setup-omarchy-vm.sh` — downloads the official ISO into a cache dir and
  verifies its SHA-256, creates the VM (disk, OVMF NVRAM, per-VM launcher and
  `.desktop` entry), deploys the helpers and wires the Omarchy menu entry +
  `Super+Alt+O` keybinding + floating window rule. Idempotent.
- `omarchy-vm-tui.sh` — a gum-based manager (create / start / stop / delete /
  inspect, RAM, vCPU, disk growth, boot order, virgl, shared 9p folder, USB and
  PCI/GPU passthrough).
- `launch-omarchy-tui.sh` — terminal-aware launcher for the TUI.
- Launcher `omarchy-vm [NAME]` + application entry **Omarchy VM** (Omarchy icon,
  launches the VM directly), and the Omarchy menu entry **Setup > Omarchy VM**
  (opens the manager; it shows a checkmark once a VM exists).
- The menu action resolves the TUI through a small `omarchy-vm-tui` wrapper
  (no `.sh`) because `omarchy-launch-or-focus-tui`/`xdg-terminal-exec` look the
  command up on PATH by exact name.

## Usage

```bash
setup-customarchy.sh omarchy-vm          # through the orchestrator (setup only)
scripts/omarchy-vm/setup-omarchy-vm.sh   # idempotent; see --help

omarchy-vm                 # start the default VM (QEMU GTK window)
omarchy-vm my-vm           # start a named VM
omarchy-vm-tui             # Super+Alt+O, or the "Omarchy VM" app entry
./setup-omarchy-vm.sh --status            # what is installed, no changes
./setup-omarchy-vm.sh --setup-only        # deploy tools/menu/app only (no ISO, no VM)
./setup-omarchy-vm.sh --vm NAME --create-vm
./setup-omarchy-vm.sh --iso /path/omarchy-4.0.4.iso   # skip the download
./setup-omarchy-vm.sh --remove [--purge]  # remove helpers (--purge: VMs + ISO cache)
```

The **orchestrator/mosquitOmarchy install is setup-only**: it deploys the
manager, the menu entry, the keybinding and the app, but does **not** download
the ISO or create a VM. You then continue in the manager — **Omarchy menu →
Setup → Omarchy VM** (or `Super+Alt+O`) — which creates the VM and downloads
the ISO there.

## ISO

- Version pinned to **Omarchy 4.0.4**.
- URL: `https://iso.omarchy.org/omarchy-4.0.4.iso` (linked from
  <https://omarchy.org/install>) — PGP signature at `…iso.sig`.
- SHA-256: `ddeded2758c48318d201dfdac905ecb28f570441883f0c052ea3cd5d05acf92d`
  (`https://iso.omarchy.org/omarchy-4.0.4.iso.sha256`).
- Cached at `~/.cache/omarchy-vm/omarchy-4.0.4.iso` (override with
  `OMARCHY_VM_ISO_CACHE`). Re-downloaded only if missing or corrupt.
- **Local ISO search**: before downloading, the installer looks for any
  `omarchy-*.iso` in the cache, `~/Downloads`, `~/Documents`, `~` and the
  current directory, keeps the **highest version**, and — when one is found —
  warns and asks whether to use it instead of the pinned download (with `-y`
  it is used automatically). A non-pinned ISO skips the pinned SHA-256 check.
- To bump the version, edit `OMARCHY_VERSION` / `OMARCHY_ISO_URL` /
  `OMARCHY_ISO_SHA256` at the top of `setup-omarchy-vm.sh`.

## VM layout and QEMU invocation

Each VM lives in `~/Omarchy-VM/vms/<name>/` (override with
`OMARCHY_VM_ROOT`) and contains `disk.qcow2`, `OVMF_VARS.fd`, `.vm-config` and
the generated `start-omarchy.sh`. The launcher reads `.vm-config` and runs:

```
qemu-system-x86_64 -name omarchy-<name> -machine q35,accel=kvm:tcg -cpu host
  -smp <cores>,cores=<cores>,sockets=1 -m <RAM_MB>
  -drive if=pflash,...OVMF_CODE.4m.fd -drive if=pflash,...OVMF_VARS.fd
  -device ich9-intel-hda -device hda-duplex
  -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet
  -boot menu=on
  -netdev user,id=net0,hostfwd=tcp::<port>-:22 -device virtio-net-pci,...
  -drive id=disk0,...file=disk.qcow2 -device virtio-blk-pci,...,bootindex=...
  -drive id=cd0,...file=omarchy-4.0.4.iso -device ide-cd,...   # ISO attached
  -device virtio-vga-gl -display gtk,gl=on                     # virgl 3D
  [-virtfs local,path=~/Omarchy-Shared,...]                    # optional 9p
  [-device usb-host,vendorid=0x…,productid=0x…]                # optional USB
  [-device vfio-pci,host=0000:01:00.0]                         # optional GPU
```

- **Boot order**: `BOOT_ORDER="d"` boots the ISO (installer), `"c"` boots the
  installed disk. Toggle it in the TUI or edit `.vm-config`. With `-boot menu=on`
  you can also press `Esc`/`F12` at boot.
- **Disk**: qcow2, 64 GB sparse by default (`DISK_SIZE`). Grow it in the TUI;
  then extend the partition inside the guest.
- **Network**: user-mode (slirp), guest `:22` forwarded to host `localhost:$SSH_PORT`
  (auto-incrementing from 2222). Enable `sshd` in the guest to use it.
- **Display/audio**: `virtio-vga-gl` with virgl 3D (toggle off → software
  `virtio-vga`); Intel HDA duplex audio.
- **Shared folder** (optional): `~/Omarchy-Shared` exposed as a 9p mount. In the
  guest: `sudo mkdir -p /mnt/host && sudo mount -t 9p -o trans=virtio hostshare /mnt/host`.
- **Passthrough** (optional): USB via the TUI picker (`usb-host`), PCI/GPU via
  `vfio-pci` — requires IOMMU + binding the device to `vfio-pci` beforehand.
  Do not pass the host's boot GPU; use a second GPU or integrated graphics.

## First boot (install Omarchy in the VM)

1. Start the VM (`omarchy-vm`, the app entry, or the TUI).
2. The ISO boots (boot order `d`). Run the Omarchy installer and let it reboot.
3. Mark the install as complete so the VM boots the disk: TUI →
   *Mark installation complete (boot disk)* (or *Toggle boot order*), or set
   `BOOT_ORDER="c"` in `.vm-config`.
4. Optional: enable `sshd` in the guest to reach it on `localhost:$SSH_PORT`.

## Requirements

- Omarchy (Arch + Hyprland), KVM (`/dev/kvm`, VT-x/AMD-V in BIOS).
- `qemu-desktop`, `edk2-ovmf`, `gum`, `curl` — `setup-omarchy-vm.sh` offers to
  install whatever is missing.
- ~64 GB free disk per VM, plus ~6 GB for the cached ISO.

## Notes

- This is a full hardware-virtualised VM (not a container): the guest sees a
  virtual disk, UEFI firmware and virtio devices. GPU acceleration is software
  (virgl/llvmpipe) unless you pass a second GPU through.
- Removing the module keeps the VMs and ISO by default; `--purge` deletes both.
