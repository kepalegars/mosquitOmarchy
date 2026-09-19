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

Steps: dependencies + OpenCL runtime depending on GPU → copy to `/opt/resolve` → XWayland launcher (`QT_QPA_PLATFORM=xcb`), adjustable zoom → **H.264/H.265** (Studio = native codecs, optional FFmpeg plugin; free = experimental and reversible system-codec enablement — reliable alternative: transcode to DNxHR) → optional OFX **SpectraFilm**. Data (projects, preferences) is never touched.

> Launchable from the file manager too: started without a terminal, the script reopens itself inside a terminal emulator (foot/xterm) and the window stays open with a *"Press Enter to close this terminal."* prompt once it finishes (success or crash) — same for all `setup-*.sh` / `uninstall-*.sh` (`gui-run.bash`).

## Usage

```bash
./setup-davinci.sh                     # interactive
./setup-davinci.sh -y                  # default choices
./setup-davinci.sh --studio|--free     # force the edition if ambiguous
./setup-davinci.sh --with-spektrafilm  # also installs SpectraFilm OFX
./setup-davinci.sh --scale 1.5         # UI zoom (default 1.0)
./setup-davinci.sh --no-codecs         # leave H.264/H.265 codecs alone
./setup-davinci.sh --keep-mesa         # do not remove opencl-mesa (AMD)
./setup-davinci.sh --status            # current state, changes nothing
./uninstall-davinci.sh                   # uninstalls (data preserved)
```

Adjust the zoom at launch: `DAVINCI_SCALE=1.5 davinci-resolve`.