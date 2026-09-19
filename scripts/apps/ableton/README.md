# Ableton Live 12 (native Linux) — Omarchy module

Installs **Ableton Live 12 native Linux** via the [shibco/ableton-linux](https://github.com/shibco/ableton-linux) project: dedicated custom wine (`~/.local/opt/wine-d2d1-nspa`, prefix `~/.wine-ableton`), Max for Live and PipeASIO included. The `install-ableton-latest.run` installer downloads itself via `--check-update`.

The `.run` installer is **not in the repo** — it is provided by the release archive (`archive-customarchy.sh`) or downloaded separately (https://github.com/shibco/ableton-linux/releases).

Steps: checks prerequisites (kernel 6.14+ NTSync, PipeWire 1.4.2+, glibc 2.35+) → runs `install-ableton-latest.run install --live-installer <zip>` (prompts: DPI, buffer, shortcuts, Link) → **links shared plugins** from `~/VST/*`.

**Menu (no duplicates)** : only one Ableton entry per edition in the Omarchy menu. If the installer creates shortcuts that end up under Wine's start menu (`wine/Programs/…`), they are removed automatically at the end of the setup. A single installed edition keeps the generic `ableton-live.desktop` launcher; several editions keep one targeted entry each.

**Nautilus "Open With" (no stale duplicates)**: `winemenubuilder` also registers one `wine-extension-*.desktop`/`wine-protocol-*.desktop` per file type Ableton handles (`.als`, `.abl`, `.ablbundle`, `.alc`, `.adv`, `.adg`, `.alp`, `.auz`, the `ableton://` URL scheme) — these are `NoDisplay=true`, but GNOME Files' "Open With" chooser shows them anyway (under "Other Applications"), and they get regenerated against whatever `WINEPREFIX` was active when Wine last ran, so a machine that ever installed Ableton into the default `~/.wine` prefix before switching to this module's dedicated `~/.wine-ableton` can end up with several identical-looking "Ableton Live" entries, one of them pointing at a now-stale prefix. Every setup run removes all of them: the per-edition entries above already declare the same file associations against the maintained `~/.local/bin/ableton-live` wrapper, so these add nothing but clutter. The native Linux installer's own entries (`io.github.shibco.ableton-linux.*` — the `ableton://` URL handler and the `.auz` license-file association) are a separate app and are left alone.

## Usage

```bash
./setup-ableton.sh                 # menu: Install / Uninstall / VST links / Status
./setup-ableton.sh -y              # everything automatic (default choices)
./setup-ableton.sh --links         # only (re)link shared plugins
./setup-ableton.sh --status        # current state, changes nothing
./setup-ableton.sh -u|--uninstall  # uninstalls one or several editions
./setup-ableton.sh --check-update  # downloads the latest .run from GitHub
```

> If the installer shows graphic corruption under Hyprland, run it from a GNOME/KDE session.

## Windows plugins

| Shared folder | Visible in Ableton as |
|---|---|
| `~/VST/VST3` | `C:\Program Files\Common Files\VST3` (auto) |
| `~/VST/VST2` | `C:\Program Files\Steinberg\VSTPlugins` (point in Settings > Plug-Ins) |
| `~/VST/CLAP` | `C:\Program Files\Common Files\CLAP` |

Same plugins → visible in Bitwig/REAPER too (yabridge). iLok activation must be done **in the Ableton prefix** (`env WINEPREFIX=~/.wine-ableton wine LicenceManager.exe`); runtime update: `sh <run> update`. Launch: `ableton-live`; first config: Settings > Audio > Driver **ASIO** > Device **PipeASIO**.

## Uninstall

```bash
./setup-ableton.sh -u   # interactive
./setup-ableton.sh -y -u  # automatic, uninstall everything
```