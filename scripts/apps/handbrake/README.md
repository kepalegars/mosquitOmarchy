# HandBrake (GUI + CLI) — Omarchy module

Installs **HandBrake** (Qt GUI, `ghb`) and **HandBrakeCLI** (separate package:
the GUI one drops the CLI at build time), the **H.264/H.265** software encoders
(`x264`/`x265` + `ffmpeg`) and the GStreamer preview plugins, syncs your
**presets**, and adds the **Hyprland** compatibility rules.

Everything is **idempotent**: re-running `setup-handbrake.sh` re-syncs the
presets (no duplicates) and is safe.

## Install

```bash
./apps/handbrake/setup-handbrake.sh          # interactive
./apps/handbrake/setup-handbrake.sh -y       # defaults
./apps/handbrake/setup-handbrake.sh --status # current state
```

## Presets

Export your presets from the HandBrake GUI (**Presets** panel → right-click →
Export…) as `*.json` files and drop them in:

```
apps/handbrake/presets/
```

The install merges them into `~/.config/ghb/presets.json` under an **"Omarchy"**
category (a backup `presets.json.bak-*` is kept). HandBrake must be **closed**
when the script runs — it rewrites that file on exit.

See `presets/README.md` for the expected format.

## Theme

HandBrake is transparently coordinated with the Omarchy theme: Omarchy sets
`QT_QPA_PLATFORMTHEME=gtk3`, so the Qt UI inherits the active GTK theme
(dark/light css). Change the theme with `omarchy theme set <name>` — HandBrake
follows at the next launch.

## Hyprland

The install appends a `Omarchy_Custom_Scripts_Handbrake` block to
`~/.config/hypr/hyprland.lua` that exempts HandBrake from the default opacity
(opaque window). It is removed by `setup-customarchy.sh --uninstall`.

## CLI examples (compression with the provided presets)

The merged presets are usable by the CLI by name. The category is
`Omarchy`, the individual preset is the name exported in the GUI:

```bash
# List the build's video encoders (x264/x265 + hardware encoders)
HandBrakeCLI --encoder-list

# One-file encode using a synced preset
# (--preset "Omarchy/<PresetName>" — e.g. "Omarchy/Omarchy H264 1080p")
HandBrakeCLI -i input.mkv -o output.mp4 --preset "Omarchy/Omarchy H264 1080p"

# Or import a preset straight from the folder without syncing it first
HandBrakeCLI -i input.mkv -o output.mp4 \
  --preset-import-file scripts/apps/handbrake/presets/omarchy-h264-1080p.json \
  --preset "Omarchy H264 1080p"

# Software 2-pass H.264 with the system encoder (no preset):
HandBrakeCLI -i input.mkv -o output.mp4 -e x264 -q 20 -2 -f av_mp4 \
  --keep-display-aspect --all-audio --all-subtitles

# Software H.265, CRF 22, keeping every audio/subtitle track:
HandBrakeCLI -i input.mkv -o output.mkv -e x265 -q 22 -f av_mkv \
  --keep-display-aspect --all-audio --all-subtitles

# Hardware encode (VAAPI on AMD) if supported:
HandBrakeCLI -i input.mkv -o output.mp4 -e qsv_h264 -q 20 -f av_mp4
```

Check a preset's exact name with:

```bash
HandBrakeCLI --help 2>&1 | grep -A3 -i preset
jq -r '.. | .PresetName? // empty' ~/.config/ghb/presets.json
```

## Uninstall

`./setup-customarchy.sh --uninstall` (module `handbrake`): removes the
Hyprland block; with `--purge` it also removes the packages. Your presets and
user data are kept.