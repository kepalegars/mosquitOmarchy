# Ableton Live 12 (native Linux) — Omarchy module

Installs **Ableton Live 12 native Linux** via the [shibco/ableton-linux](https://github.com/shibco/ableton-linux) project: dedicated custom wine (`~/.local/opt/wine-d2d1-nspa`, prefix `~/.wine-ableton`), Max for Live and PipeASIO included. The `install-ableton-latest.run` installer downloads itself via `--check-update`.

The `.run` installer is **not in the repo** — it is one of the two files the release archive
carries (`archive-mosquitomarchy.sh` at the repo root), or downloaded separately
(https://github.com/shibco/ableton-linux/releases). The `PATCH/` folder is **not** in any
release: it is a private extra and stays on the machine that has it.

**The Live edition zip must be downloaded manually** (from your ableton.com account) and dropped in `code/modules/Apps/ableton/`. At opening, the script verifies it is present and otherwise warns which file is missing (`Ableton_Live_<edition>_<version>_64.zip`) before offering rescan / a typed path.

**Hyprland focus.** Les fenêtres Ableton, y compris la fenêtre principale au lancement, ne prennent jamais le focus d'elles-mêmes (`no_initial_focus` + `focus_on_activate = false`) : un clic est nécessaire pour les activer. Les dialogues et éditeurs de plugins sont donc aussi ouverts sans focus.

**Nom de fenêtre / projet actif.** Avec Ableton focalisé, `SUPER + G` affiche le nom de la fenêtre et permet de voir le projet actif.

**One archive per run.** When several zips are present (Suite/Intro), setup asks which single archive to install now. Several editions can coexist in the prefix; each gets its own launcher entry. Uninstall still removes one edition at a time.

Steps: checks prerequisites (kernel 6.14+ NTSync, PipeWire 1.4.2+, glibc 2.35+) → **disk-space preflight** → runs `install-ableton-latest.run install --live-installer <zip>` (prompts: DPI, buffer, shortcuts, Link) → **links shared plugins** from `~/VST/*`.

**Disk-space preflight.** Just before installation, the script reads the edition zip's *uncompressed* size, adds 1.5 GiB for the runtime/staging/installer workspace, and enforces the upstream 10 GiB minimum. The free and required values are shown **inside the Install/Cancel confirmation**:

```
Install ableton_live_intro_12.4.5_64.zip now?

Free space    : 13.8 GB
Required space: ~10.0 GB
```

If there is not enough room it aborts before the installer starts (there is no interactive override; `ABLETON_ALLOW_LOW_SPACE=1` is the explicit escape hatch). This prevents a failed Live installation followed by a rollback after several minutes. Moving unused edition archives to another disk is the quickest fix.

**Existing prefix / step 4 (`vcrun2022`).** The upstream `.run` runs `winetricks -f`, so on an existing prefix `vcrun2022` re-runs `vc_redist.x64.exe /q`; it returns **102** (already installed / reboot pending) and winetricks treats that as fatal. When the prefix already records `vcrun2022` in `~/.wine-ableton/winetricks.log` and the VC DLLs are present, `setup-ableton.sh` installs from a **temporary copy** of the `.run`: only the copy's wrapper header is patched so the extracted `setup-prefix.sh` is run without `-f`. The embedded payload (and its SHA-256) is untouched, the original `.run` stays byte-identical, and the official transaction/rollback still runs. The installer log from that copy is saved next to the `.run` and shown in the TUI log frame.

**Module update.** During a mosquitOmarchy update, `MOSQUITOMARCHY_UPDATE=1` makes this module refresh the runtime/prefix/integration with the official `.run update` and **keep the installed editions**. It never adds an archive (e.g. Suite) that happens to be lying in the folder; adding an edition is always an explicit install action.

**Menu (no duplicates)** : one Ableton entry in the Omarchy menu. If the installer creates shortcuts that end up under Wine's start menu (`wine/Programs/…`), they are removed automatically at the end of the setup.

**Nautilus "Open With" (no stale duplicates)**: `winemenubuilder` also registers one `wine-extension-*.desktop`/`wine-protocol-*.desktop` per file type Ableton handles (`.als`, `.abl`, `.ablbundle`, `.alc`, `.adv`, `.adg`, `.alp`, `.auz`, the `ableton://` URL scheme) — these are `NoDisplay=true`, but GNOME Files' "Open With" chooser shows them anyway (under "Other Applications"), and they get regenerated against whatever `WINEPREFIX` was active when Wine last ran, so a machine that ever installed Ableton into the default `~/.wine` prefix before switching to this module's dedicated `~/.wine-ableton` can end up with several identical-looking "Ableton Live" entries, one of them pointing at a now-stale prefix. Every setup run removes all of them: the per-edition entries above already declare the same file associations against the maintained `~/.local/bin/ableton-live` wrapper, so these add nothing but clutter. The native Linux installer's own entries (`io.github.shibco.ableton-linux.*` — the `ableton://` URL handler and the `.auz` license-file association) are a separate app and are left alone.

## Usage

```bash
code/modules/Apps/ableton/setup-ableton.sh                 # menu: Install / Uninstall / VST links / Status
code/modules/Apps/ableton/setup-ableton.sh -y              # everything automatic (default choices)
code/modules/Apps/ableton/setup-ableton.sh -i|--install    # install flow only, prompts kept
code/modules/Apps/ableton/setup-ableton.sh --links         # only (re)link shared plugins
code/modules/Apps/ableton/setup-ableton.sh --status        # current state, changes nothing
code/modules/Apps/ableton/setup-ableton.sh -u|--uninstall  # uninstalls editions one by one
code/modules/Apps/ableton/setup-ableton.sh --check-update  # downloads the latest .run from GitHub
```

> If the installer shows graphic corruption under Hyprland, run it from a GNOME/KDE session.

## Windows plugins

| Shared folder | Visible in Ableton as |
|---|---|
| `~/VST/VST3` | `C:\Program Files\Common Files\VST3` (auto) |
| `~/VST/VST2` | `C:\Program Files\Steinberg\VSTPlugins` (point in Settings > Plug-Ins) |
| `~/VST/CLAP` | `C:\Program Files\Common Files\CLAP` |

Same plugins → visible in Bitwig/REAPER too (yabridge). iLok activation must be done **in the Ableton prefix** (`env WINEPREFIX=~/.wine-ableton wine LicenceManager.exe`); runtime update: `sh <run> update`. Launch: `ableton-live`; first config: Settings > Audio > Driver **ASIO** > Device **PipeASIO**.

## Ableton Move

**Audio interface → Mixbay, not this module.** The Move is class-compliant but its interface is
**fixed at 44.1 kHz**. Mixbay owns it through its **Move profile** (`move-audio`, installed from
Mixbay's own connection notice, or by hand with
`mosquito-mixbay-compat --apply move`): plugging the Move gets one Mixbay notification —
*Use its audio interface? (Pins the sample rate to 44.1kHz)* — and only that answer switches the
default in/out and pins the graph. Unplugging offers the way back to the previous devices and
rate. The audio panel works too: picking the Move there pins 44.1 kHz; picking another device
never reverts the rate, only the unplug does. Live mode releases the Move when a session starts
(Live Manager row, on by default) and never re-selects it afterwards.

**Live Control is not covered.** Live 12 ships a `Move` remote script and this prefix has it
(`…/Live 12 Suite/Resources/MIDI Remote Scripts/Move`), but the Move's control mode needs the
Windows-only `move_display` driver to drive its screen — it is installed in `~/.wine-ableton`
(`Redist/move-display-driver-installer.exe`) and the driver itself does not run under wine. That is
why the Move stays on *Connect Live via USB-C* while Live runs, and why input that does arrive looks
mis-mapped: it is arriving as plain MIDI, not through Ableton's Move protocol. A clean Linux path is
a Live remote script speaking a community firmware protocol over sysex (the pattern `move-bitwig`
uses on the Move), which is a separate project and has to be validated on the hardware. The
wine-side option below does not need that driver: it gives Live's in-process libusb access to the
display interface through the runtime's host bridge.

For the Move as a **Bitwig** controller and for set transfer, see the `move-manager` module.

### Move in wine — optional patch (in `PATCH/`, local only)

**Decision gate: the bridge is generic, so no wine change is needed.** The runtime's `dlls/libusb-1.0`
comes from upstream patches `0032` (Push 2) and `0106` (Push 3): `libusb_get_device_list` passes the
host list through unfiltered — there is no VID/PID allowlist — and the DLL exports exactly what Live
imports (`get_device_list`, `open`, `claim_interface`, `bulk_transfer`, `strerror`, interface numbers
0–255, hotplug stubs). The Move's display is `VID_2982&PID_1958&MI_00`; the same bridge reaches it.

**What the patch does** (`PATCH/move-wine/patch-move-wine.sh`, private like the rest of `PATCH/`):

- installs `/etc/udev/rules.d/99-ableton-move-live.rules` (vendor `0x2982`, `TAG+="uaccess"`) —
  `/dev/bus/usb/*` is root-only otherwise, so libusb cannot open the display interface;
- sets the prefix-wide `HKCU\Software\Wine\DllOverrides` value `libusb-1.0=builtin` in
  `~/.wine-ableton`, so Live loads wine's bridge instead of the native `libusb-1.0.dll` shipped in
  its Program folder (that DLL expects a Windows WinUSB driver);
- records the runtime, the udev rule hash and the previous override value in
  `~/.local/state/mosquitomarchy/ableton-move-wine`.

`--check` prints `move-wine: applied` / `move-wine: not applied`; it verifies the marker, the runtime
release, the rule hash and the current override, so a partial state reads as not applied. `--apply`
(default) refuses to run while that prefix's wine is up. `--revert` restores the previous override
value, removes the rule (only if this patch added it) and deletes the marker; with no marker it is a
no-op. `--reapply` is the update hook.

**`P` row action.** With the cursor on the Ableton row, **P** applies this step
and **P in Uninstall** restores the previous state — the same per-row key as
DaVinci's drivers and REAPER's config. `_manual_patch_spec` still maps the
synthetic `ableton-move` key to the script and `_installed_state` maps it back
to `ableton`, so `cmd_run_patch`/`cmd_remove_patch` dispatch it directly; the
tree marks the row with `move_patch` only when the script is present, so `P`
stays silent otherwise. The hidden lowercase `p` remains the R2R activation
patch and never lists the Move step.

**`.run` updates.** `sh install-ableton-latest.run update` replaces the wine runtime and refreshes
`system32/libusb-1.0.dll`; `PATCH/`, the udev rule and `user.reg` survive. `setup-ableton.sh` calls
`patch-move-wine.sh --reapply` after every `.run` install/update (normal and
`MOSQUITOMARCHY_UPDATE=1`), so the state is re-checked instead of silently drifting.

**Acceptance.** `--check` flips only after a complete apply; Live shows the Move display and the
transport works; `--revert` restores the previous override and removes the rule; a runtime update
followed by `setup-ableton.sh` leaves `--check` applied; unplugging the Move mid-session does not
crash Live.

## Uninstall

```bash
code/modules/Apps/ableton/setup-ableton.sh -u     # interactive: one edition at a time
code/modules/Apps/ableton/setup-ableton.sh -y -u  # automatic: every edition + the prefix
```

From the mosquitOmarchy TUI, the Ableton **install** runs non-interactively in the TUI's own **framed runner** (no terminal takeover, no separate window), so the live log stays visible while the installer works: `-y` picks the single archive/default options, and the frame streams both the module output and the native `ableton-linux-installer-*.log` written by the `.run` (the precise failing step). The full log opens automatically when the run ends — press `c` to copy it. To choose the archive or answer the installer prompts by hand, run `setup-ableton.sh -i` in a terminal. Uninstall still runs inline with its edition prompts and then shows the same log frame.

The interactive uninstall asks which edition to remove, then whether to remove
another one. The confirmation is an Uninstall/Cancel dialog and shows the space
that will be freed. Removing the **last** edition also removes the entire
Ableton runtime/prefix through the official `install-ableton-*.run uninstall
--delete-prefix`.