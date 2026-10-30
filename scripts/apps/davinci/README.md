# DaVinci Resolve — Omarchy module

Installs **DaVinci Resolve** (Studio or free) from the official Blackmagic installer. **ANY version is accepted** — whatever Blackmagic calls it (18, 19, 20…), and regardless of case. The **filename** placed in `scripts/apps/davinci/` selects the edition (if both are present, it prompts); at opening, the script warns which file is missing when none is found:

| File to place | Edition |
|---|---|
| `DaVinci_Resolve_Studio_*_Linux.zip` | Resolve Studio |
| `DaVinci_Resolve_*_Linux.zip` | Resolve free |

## Download (Blackmagic — account required)

- [All DaVinci Resolve versions (family page)](https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion)
- [DaVinci Resolve (free) — direct Linux download](https://www.blackmagicdesign.com/support/download/59dd4eef1f4941c29fb8dc48b33f5c87/Linux)
- [DaVinci Resolve Studio — direct Linux download](https://www.blackmagicdesign.com/support/download/baf7c071c0524fbf8ccc961925c9f443/Linux)

Drop the zip in `scripts/apps/davinci/` (exact file name = edition chosen automatically). When the zip is missing, the script itself displays these three links as clickable hyperlinks (Ctrl+click to open).

Steps: dependencies + OpenCL runtime depending on GPU → copy to `/opt/resolve` → XWayland launcher (`QT_QPA_PLATFORM=xcb`) → **codecs** (Studio = native H.264/H.265, optional FFmpeg plugin and optional AAC decode via `resolve-aacfix`; free = transcode to DNxHR/PCM) → **DRwrap** → optional OFX **SpectraFilm**. Data (projects, preferences) is never touched.

## AAC audio (important)

**Resolve on Linux does not decode AAC — in the free edition *and* in Studio.** It ships `libavcodec` with the AAC decoder compiled out, and the binary never requests AAC, so any `.mp4`/`.mov` with AAC imports with silent audio (`Failed to decode the audio samples` in the logs). This is a licensing restriction, not a 48/96 kHz problem.

- **Studio 21.x:** the script offers [`resolve-aacfix`](https://github.com/josephg/resolve-aacfix) (MIT, additive binary patch + drop-in libav with the same sonames, reversible with `aac-fix uninstall`). A Resolve update replaces `/opt/resolve` and wipes it; `mosquitOmarchy update` detects the version change and re-applies it automatically when it was enabled (see [Updates](#updates)).
- **No patch / free edition:** transcode the audio to PCM (video stream copied, no re-encode):
  ```bash
  ffmpeg -i input.mp4 -c:v copy -c:a pcm_s16le -ar 48000 output.mov
  ```
- **Automatic:** DRwrap (below) converts unsupported-codec drops in `~/Videos/ResolveDrop`.

The old `libav` symlink patch is gone: it pointed Resolve at the system `libavcodec.so.63` while Resolve loads `.so.60`, so it could not enable AAC (and was ABI-incompatible anyway).

## DRwrap

[DRwrap](https://github.com/fedsfarm/drwrap) (GPL-3.0, external package) is installed and configured silently:

- AUR package `drwrap` (via `yay`/`paru`) and the `drwrap.service` user service.
- `drwrap setup --no-adopt`: the existing `davinci-resolve` launcher and menu entry stay authoritative; DRwrap does **not** replace them. Its own *DaVinci Resolve (wrapped)* menu entry is removed so there is a single, complete **DaVinci Resolve** entry.
- Desktop notifications and progress bubbles are turned off in `~/.config/drwrap/config.toml`; conversion failures are still logged.
- It fixes drag-and-drop, clipboard paste (`Ctrl+V`) and unsupported-codec imports. Its watch folder is `~/Videos/ResolveDrop`; converted files land in `~/Videos/ResolveIngest` (keep that folder — projects point at it).

Check it later with `drwrap doctor`, or remove just the integration with `drwrap setup --remove` (the package and converted files stay).

> The optional nosignal `omarchy-resolve` panel is **not** installed by this script. If it is already on the machine, it can still inspect the install; its XWayland check uses `/usr/local/bin/resolve-omarchy`, which this script creates as a symlink to the launcher.

> Launchable from the file manager too: started without a terminal, the script reopens itself inside a terminal emulator (foot/xterm) and the window stays open with a *"Press Enter to close this terminal."* prompt once it finishes (success or crash) — same for all `setup-*.sh` / `uninstall-*.sh` (`gui-run.bash`).

## Window (Hyprland)

On Omarchy, the setup appends a user rule to `~/.config/hypr/hyprland.lua` (marker `mosquito-davinci-tiling`) so the Resolve project window opens **tiled** instead of Omarchy's default floating/fullscreen. The Project Manager stays floating. `uninstall-davinci.sh` removes the block.

## Updates

When Resolve is updated by the user (new Blackmagic release installed over `/opt/resolve`), `mosquitOmarchy update` compares the installed version with `~/.local/state/mosquitomarchy/davinci-state` and proposes the **DaVinci Resolve** module in the update screen. Selecting it re-applies only what was enabled before — license patch, AAC fix, FFmpeg plugin, launcher/wrapper, Hyprland tiling rule and audio backend — without asking for the Blackmagic zip or reinstalling Resolve.

If the AAC fix/license patch/FFmpeg plugin were present before the update, they are re-applied automatically; nothing is added that was not already there.

## Usage

```bash
scripts/apps/davinci/setup-davinci.sh                     # interactive
scripts/apps/davinci/setup-davinci.sh -y                  # default choices
scripts/apps/davinci/setup-davinci.sh --studio|--free     # force the edition if ambiguous
scripts/apps/davinci/setup-davinci.sh --with-spektrafilm  # also installs SpectraFilm OFX
scripts/apps/davinci/setup-davinci.sh --no-codecs         # leave codec setup alone
scripts/apps/davinci/setup-davinci.sh --keep-mesa         # do not remove opencl-mesa (AMD)
scripts/apps/davinci/setup-davinci.sh --status            # current state, changes nothing
scripts/apps/davinci/uninstall-davinci.sh                  # uninstalls (data preserved)
```

UI scaling is left to Resolve's own preferences (Preferences > User > UI Settings); the launcher sets no `QT_*` or `DisplayScale` override.