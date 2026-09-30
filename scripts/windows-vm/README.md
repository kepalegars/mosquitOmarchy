# Windows VM — Omarchy module

Merges launch + management + debloat for the Windows VM (Docker/dockurr), a single run **auto-detects** and applies: `windows-vm-usb` launcher (USB redirect + DPI), menu entry, `winvm` manager (RAM/CPU/disk, gum menu, host validation), "Setup > Windows VM" entry, OEM debloat (payload `/oem` if the VM is present). QEMU does not change RAM/CPU on the fly → Windows reboots (data preserved in `~/.windows`).

## Usage

```bash
./setup-windows-vm.sh            # applies everything (idempotent)
./setup-windows-vm.sh --fresh    # debloat via Windows REINSTALL (overwrites data.img)
./setup-windows-vm.sh --remove   # removes helpers + menu entries (keeps the config)

windows-vm-usb        # VM + redirected disks (-k : keeps the VM running)
winvm status|ram 16G|cpu 6|disk 128G|start|stop
```

> Prerequisites: Omarchy + (ideally) VM installed via `omarchy-windows-vm install`. If the VM is not there yet, the script offers it; `winvm` remains usable. iLok-type licenses must be activated separately per prefix/VM.

## Compatibility with the current Omarchy manager

Omarchy moved the compose to a **root-owned** `/var/lib/omarchy/windows/docker-compose.yml` and only rewrites it through `omarchy-windows-vm` (a user-writable compose under `~/.config/windows` was a privilege-escalation path). This module follows it:

- **Compose path** — every helper (`setup-windows-vm.sh`, the `windows-vm-usb` launcher, `winvm`, `setup-ableton-vm-app.sh`) prefers `/var/lib/omarchy/windows/docker-compose.yml` and falls back to `~/.config/windows/docker-compose.yml` (pre-migration installs).
- **No `/oem` volume** — Omarchy's writer only emits `/storage` and `/shared`, so an injected `/oem` line was wiped on every install and could wedge Omarchy's migration. The debloat payload is now served from the **shared folder** (`$HOME/Windows`, seen in the VM as `\\host.lan\Data`); a stale `/oem` line is removed when the legacy compose is writable.
- **`winvm` on the managed compose** — `status`/`start`/`stop` delegate to `omarchy-windows-vm` (which prepares the root-owned bind anchors); RAM/CPU/disk changes are refused with a pointer to `omarchy-windows-vm install` (the config is no longer user-editable).
- **`~/Windows` hardened to 0700** — Omarchy requires exactly `700` on `~/.windows` and `~/Windows`. A **setgid bit or a default ACL** makes `chmod 0700` leave the mode at `2700`, which silently blocks `omarchy-windows-vm remove|launch` with *"Could not safely migrate the VM"*. The script strips both (`setfacl -b/-k`, `chmod g-s`) on every run.

## Ableton (Windows VM) via RemoteApp — setup-ableton-vm-app.sh

> **Deprecated** : since `setup-ableton.sh`, Ableton runs natively on Linux. Kept for specific VM use.

Adds Ableton (Windows VM) as a menu app via RemoteApp RDP (`xfreerdp3 /app:program:<exe>`), `~/.local/bin/ableton-vm` wrapper (starts the VM, waits for Windows, launches Ableton).

```bash
./setup-ableton-vm-app.sh "C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe"
./setup-ableton-vm-app.sh          # without argument: prompts for path
```

The exe path is stored in `~/.config/windows/ableton.conf`; rerun the script (or edit this file) to change the version. Windows only admits one session per user: launching Ableton while the full desktop is open in another RDP window takes over that session.