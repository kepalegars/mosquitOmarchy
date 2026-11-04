# spektrafilm — SpektraFilm OFX + standalone app (film simulation)

Installs **both** halves of SpektraFilm:

1. the standalone **`spektrafilm-git`** app from the AUR (via `yay`), and
2. the free **SpektraFilm OFX plugins** into `/usr/OFX/Plugins` from the
   official zip.

DaVinci Resolve, Blender or any other OFX host on the machine then sees the
plugins, and the standalone film-simulation app is available from the menu. The
module owns both, so `--remove` takes both away.

**Any OFX version is accepted**: the script only needs a `.zip` whose name
contains `spektrafilm` — `spektrafilm-OFX-linux.zip` from the site, or a
versioned archive. It runs the `install.sh` that the archive itself contains,
so the bundles are installed the way their author intended.

## Download

- [Latest SpektraFilm OFX for Linux](https://downloads.spektrafilm.114c.de/latest/spektrafilm-OFX-linux.zip)

Drop the zip in `code/modules/Apps/spektrafilm/`, or in `~/Downloads` and run
`./bootstrap.sh` — it moves the first matching archive into this folder
(never overwriting a file that is already there).

## Usage

```bash
code/modules/Apps/spektrafilm/setup-spektrafilm.sh             # install / update both
code/modules/Apps/spektrafilm/setup-spektrafilm.sh -y          # no prompt
code/modules/Apps/spektrafilm/setup-spektrafilm.sh --status    # read-only
code/modules/Apps/spektrafilm/setup-spektrafilm.sh --remove    # remove OFX + app
```

The script validates the zip, installs `spektrafilm-git` from the AUR, then
extracts the zip to a temporary folder, runs its `install.sh` (system mode,
prewarming skipped), and deletes the extracted copy. **Only the zip stays on
disk**, so a reinstall or a newer version is always one command away.

Replacing an existing installation is safe: the upstream installer backs the
old bundles up into `/usr/OFX/Plugins/spektrafilm-backup-*.tar.gz` before
writing the new ones.

Restart DaVinci Resolve (or the other OFX host) after installing or removing.
In Resolve the plugins appear under **Color → Open FX**.

## Optional prewarm

The upstream installer can precompile its Vulkan pipelines for the current
desktop user. It is skipped here because the installer runs through `sudo`,
where it cannot reliably identify the desktop user. Run it once after a reboot
if the first playback stutters while shaders compile:

```bash
/usr/OFX/Plugins/spektrafilm.ofx.bundle/Contents/Resources/Tools/warm_pipeline_cache.sh
```

## Notes

- The zip is about 30 MB; it is ignored by git and is not part of a source
  archive (`archive-mosquitomarchy.sh`).
- DaVinci Resolve's own module no longer offers SpektraFilm: the plugin and its
  removal belong to this module, so installing or removing Resolve does not
  touch it.
