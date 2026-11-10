# `code/modules/Tweaks`

Small, idempotent **preferences**. They do not repair anything: the desktop already works,
these only make it behave the way the user wants (appearance, window behaviour,
de-cluttering). Re-running one re-applies it, which is the point.

They are the entries of the orchestrator's `TWEAKS` array — offered at setup and under
**Setup → Tweaks** in the TUI, and runnable directly with `bash code/modules/Tweaks/<script>.sh`.
They are **opt-in**: unlike `FIXES`, the unattended `-y` pass never applies them.

They were split out of `code/modules/Fixes/` so the two families read apart: a *fix* restores a
broken state, a *tweak* is a taste. See `../Fixes/README.md` for the repairs.

| id | Script | What it changes |
|---|---|---|
| `keepassxc-window` | `tweak-keepassxc-window.sh` | Floats/centers KeePassXC in Hyprland instead of tiling it (its fixed-size templates/dialogs expect a floating window). Idempotent marked block in `hyprland.lua`, matching both the native app-id and the XWayland class. `--remove` drops the block. |
| `tui-theme` | `tweak-tui-theme.sh` | Regenerates the Omarchy palette and rebuilds every Go TUI so their colours follow the **active** theme. The dynamic palette re-read already ships in `tui-kit`; this forces it. |
| `terminal-padding` | `tweak-terminal-padding.sh` | Omarchy pads every terminal by 14px and paints that padding with the theme background, so on a dark theme the text block reads as a dark slab inside a light window. Keeps the padding but makes it take the terminal's own background. `--remove` reverts. |
| `wine-menu` | `tweak-wine-menu.sh` | `Uninstall` / `Manual` entries cluttering the launcher: a Windows installer wrote Start-Menu shortcuts into its prefix and Wine republished each as an app entry. Removes the ones belonging to prefixes mosquitOmarchy manages, plus the empty publisher folders, and refreshes the desktop database. `--all-prefixes` widens it; the `NoDisplay` file associations are never touched. Also applied at the end of the audio plugin manager, the audio stack and the Guitar Pro setup. |
| `wine-theme` | `tweak-wine-theme.sh` | Makes every native Wine window (the small "Configuration in progress / Updating…" dialogs, uninstallers, stock controls) follow the desktop's dark/light palette, by writing `[Control Panel\Colors]` in every prefix's `user.reg`. Installs a `theme-set` hook so the palette is re-applied on every theme change. `--remove` restores the saved `user.reg` files. |
| `colors-unifier` | `tweak-colors-unifier.sh` | Makes GTK4/GTK3 (and Qt via qgtk3) apps follow the active Omarchy theme, with every foreground checked against the surface it is drawn on (WCAG contrast), so a theme cannot produce light-on-light text. A hardened fork of Accord; it disables Accord and strips its block, installs a `theme-set` hook, and never closes Nautilus on its own — a centred prompt offers that and warns that in-progress copies are cancelled. `--remove` restores the CSS/gsettings and re-enables Accord if it was disabled. |
| `amdgpu-compute-timeout` | `tweak-amdgpu-compute-timeout.sh` | Raises the AMDGPU **compute-ring** watchdog from 2 s to 90 s so a slow-but-valid Vulkan/OpenCL job on an integrated GPU (SpektraFilm OFX in DaVinci Resolve, Blender, …) is not killed with `VK_ERROR_DEVICE_LOST`. Adds one marked `amdgpu.lockup_timeout=2000,90000,2000,2000` line to `/etc/default/limine` (GFX, Compute, SDMA, Video) and runs `limine-update`. **GPU-wide, not per-app**: every compute job on this AMD GPU gets the longer watchdog, so a genuinely hung job can freeze the desktop or that app for up to 90 s before the queue is reset; graphics/DMA/video stay at 2 s. It is a workaround for a too-short watchdog, not a fix for a driver/shader hang. The first apply keeps `/etc/default/limine.bak.mosquitomarchy-amdgpu`; `--remove` only removes the managed block. **A full reboot is required to apply or revert** — logging out or restarting the session does not reload `amdgpu`. |
| `nautilus-audio` | `tweak-nautilus-audio.sh` | Two right-click tools in Nautilus (**Scripts** submenu, picked up live). **PACPL** (Perl Audio Converter, AUR) converts the selected files to MP3/FLAC/OGG/OPUS/WAV/M4A/AIFF/WV through a zenity picker, tags kept; an existing output is skipped unless the overwrite question is answered yes. Installed with the common encoders (vorbis-tools, opus-tools, sox, flac, lame, wavpack, ffmpeg, zenity). **makesfz** (single public-domain bash script, downloaded to `~/.local/bin`) generates `.sfz` sampler instruments from a selection of WAV/FLAC/OGG samples: one `.sfz` per sample spanning the keyboard, a single multi-sample map (`-s`), key ranges, layers grouped by name prefix/suffix or sub-directory, and an interactive mode opened in foot (xterm fallback). **The first run compiles pacpl's AUR Perl dependencies (several minutes)** and runs through the TUI's streamed runner so the build is visible and cancellable. `--remove` deletes only the two managed Nautilus scripts and `~/.local/bin/makesfz`; pacpl and the encoders are left installed. |

## Opt-in only

`tweak-replace-evince-with-papers.sh` swaps the system document viewer for Papers. It is
deliberately **not** a quick tweak and never offered automatically: changing the default PDF
handler is a system-wide decision. `--status` and `--uninstall` are supported, and Evince
stays installed as an invisible backend so previews keep working.

## Notes

- A tweak absent from the `TWEAKS` array is opt-in by design, and stays out of the automatic pass.
