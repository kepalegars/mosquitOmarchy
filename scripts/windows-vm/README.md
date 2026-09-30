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

> iLok-type licenses must be activated separately per prefix/VM.

### It installs the VM when there is none

The script no longer just warns and stop. If no compose is found, it offers to run
**`omarchy-windows-vm install`** and, on success, carries straight on to the
launcher, the manager, the menu entries and the debloat **in the same run**.

The install is *delegated*, not reimplemented, and that is deliberate: Omarchy
keeps the compose in a root-owned directory precisely so that a root-invoked
`docker compose up` can never consume a file the user could have rewritten.
Writing our own compose would reinstate the privilege-escalation path that
Omarchy closed. `omarchy-windows-vm install` is fully interactive (RAM, cores,
disk, account), so the prompts are Omarchy's and the answers are yours; from a
menu action with no terminal, the script refuses to escalate unattended and tells
you what to run.

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

## Using the Linux VST plugins inside the Windows VM

**Not implemented, and read this before assuming it works.** The obstacle is not
the mounting, it is where plugin state lives.

### What would work

A read-only bind of the shared plugin folder would not disturb the Linux setup at
all (`:ro`), and most of the plugins there are directly loadable. On the machine
this was measured on: **16 of 17 VST3 entries are plain PE32+ files** that
Windows loads as-is.

### The one that is not

`Serum2.vst3` is a **macOS-style bundle directory** — `Contents/`, `PlugIn.ico`,
`desktop.ini` — whose payload is a genuine native Windows binary at
`Contents/x86_64-win/Serum2.vst3` (PE32+ DLL). The envelope is not the payload.
Windows expects a *file* named `Serum2.vst3` and finds a *directory*, so it
cannot be loaded from the shared path as-is; `Contents/x86_64-win/Serum2.vst3`
has to be exposed instead. A conversion pass would be needed for those.

### Why the settings cannot be shared — the blocking caveat

Plugin state under wine lives in **two** places:

- files under the prefix, e.g. `~/.wine-vst/drive_c/users/<user>/AppData/…` —
  mountable read-only, so these *could* be shared;
- **the prefix's Windows registry** — `user.reg`, `system.reg` (~4 MB of `.reg`
  files in `~/.wine-vst/`).

A VM is a real Windows install with **its own registry**, and a wine `.reg` is
not a reliable import. So any plugin that keeps its settings in the registry
**will not carry them over**, and there is no way around it while keeping the
Linux setup untouched — which is the requirement. Expect to re-set preferences
once inside the VM, for those plugins.

32-bit VST2/VST3 additionally need a 32-bit host (or a bridge) inside the VM;
nothing about the mount provides that.

Finally, the compose is root-owned, so adding a plugin mount to it needs a
supported extension point in Omarchy. Injecting a line is what the `/oem` volume
already proved gets wiped on the next install.

## Future: Windows "K2"

Microsoft's **Windows 11 "K2"** is a real, separate, still-beta operating system
(currently in the Insider program). It is *not* Windows 11 and not a feature of
it, and it is not a general release.

Nothing here supports it today, and this module does not pretend otherwise. It is
recorded as a **future possibility** only, because the shape of a K2 guest would
differ in ways that matter for this module: the docking/compose stack, the OEM
first-boot payload, and the shared-folder conventions this script relies on are
all dockurr/Windows-11-shaped. Any real support is upstream work in dockurr, not
a change that can be made from here.
