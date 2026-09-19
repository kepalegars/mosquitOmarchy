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

## Ableton (Windows VM) via RemoteApp — setup-ableton-vm-app.sh

> **Deprecated** : since `setup-ableton.sh`, Ableton runs natively on Linux. Kept for specific VM use.

Adds Ableton (Windows VM) as a menu app via RemoteApp RDP (`xfreerdp3 /app:program:<exe>`), `~/.local/bin/ableton-vm` wrapper (starts the VM, waits for Windows, launches Ableton).

```bash
./setup-ableton-vm-app.sh "C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe"
./setup-ableton-vm-app.sh          # without argument: prompts for path
```

The exe path is stored in `~/.config/windows/ableton.conf`; rerun the script (or edit this file) to change the version. Windows only admits one session per user: launching Ableton while the full desktop is open in another RDP window takes over that session.