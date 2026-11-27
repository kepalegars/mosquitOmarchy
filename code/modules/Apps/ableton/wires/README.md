# Ableton Live 12 — Wires

This module installs Ableton Live 12 through the [Wires runtime](https://wires.sh/)
(Para-Real Ltd.). Wires is a Wine fork for creative applications: the small
`.run` installer from the wires.sh CDN carries application-specific scripts,
while the Wine runtime (~409 MB, **Wayland** build here) and the Ableton
Windows installer are downloaded once and cached locally.

Nothing downloaded is committed: only the scripts in this folder are on GitHub.

## Layout

```
wires/
├── setup-ableton-wires.sh          # install / update / uninstall / status / links
├── patch-move-wires.sh             # P: Move USB udev step
├── PATCH/patch-ableton-wires.sh    # R2R patch, targets the Wires prefix
├── old/                            # legacy shibco script, reference only
└── wires/                          # gitignored: cached .run, runtime, extracted installer
```

The runtime itself lives in
`${XDG_DATA_HOME:-$HOME/.local/share}/mosquitomarchy/runtime/wires/`
(override with `MOSQUITOMARCHY_WIRES_ROOT`) so it can be shared by other modules.

## Usage

```sh
./setup-ableton-wires.sh             # install / update in place
./setup-ableton-wires.sh -y          # non-interactive defaults
./setup-ableton-wires.sh --status
./setup-ableton-wires.sh --check-update
./setup-ableton-wires.sh --update --runtime-only
./setup-ableton-wires.sh --uninstall [--purge]
./setup-ableton-wires.sh --links     # re-run the APM VST linker
```

The installer uses Work `Music-Production` (`WIRES_WORK` overrides it).
Wires creates its own `wires-ableton-live-12-*.desktop` entries and launcher;
this module does not add competing menu entries. It keeps the shared VST links,
the Hyprland rules and the R2R patch, all pointed at the Wires prefix
`<root>/Works/<work>/environment`.
