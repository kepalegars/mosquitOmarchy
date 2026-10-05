# Bitwig Studio 6.0 Beta 6 — Omarchy module

Uninstalls any existing version (AUR, flatpak, deb, orphans) then installs **Bitwig Studio 6.0 Beta 6 pinned**: clones the AUR PKGBUILD, uses the **local `.deb` from `scripts/apps/bitwig/` as source** (required — one of the two files the release archive carries), `pacman -U`, blocks updates (`IgnorePkg`).

**The `.deb` must be downloaded manually** (from your Bitwig account). At opening, the script verifies it is present and otherwise warns which file is missing (`bitwig-studio-*.deb`, any version).

This is **its own module**, listed separately in Setup. It used to be installed by the
`audio` module, which made "Bitwig" and "the audio stack" one indivisible row: the `.deb`
cannot be fetched by the repo, so that row had to be either offered and broken, or hidden
along with yabridge and VST sharing — which work perfectly well without a DAW. With no
`.deb` in `scripts/apps/bitwig/`, the Setup row is **greyed out** and Enter on it names the
file and the folder; drop the file in and the row comes back on its own.

## Usage

```bash
scripts/apps/bitwig/setup-bitwig.sh            # interactive
scripts/apps/bitwig/setup-bitwig.sh -y         # default choices
scripts/apps/bitwig/setup-bitwig.sh --dry-run  # simulation, nothing modified
```

> The flatpak is not used (its sandbox cannot see yabridge chainloaders). Disable auto-update in Bitwig (Dashboard > Settings > Misc).