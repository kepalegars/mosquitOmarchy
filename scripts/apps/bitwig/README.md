# Bitwig Studio 6.0 Beta 6 — Omarchy module

Uninstalls any existing version (AUR, flatpak, deb, orphans) then installs **Bitwig Studio 6.0 Beta 6 pinned**: clones the AUR PKGBUILD, uses the **local `.deb` from `scripts/apps/bitwig/` as source** (required — provided by the release archive), `pacman -U`, blocks updates (`IgnorePkg`).

**The `.deb` must be downloaded manually** (from your Bitwig account). At opening, the script verifies it is present and otherwise warns which file is missing (`bitwig-studio-*.deb`, any version).

## Usage

```bash
./setup-bitwig.sh            # interactive
./setup-bitwig.sh -y         # default choices
./setup-bitwig.sh --dry-run  # simulation, nothing modified
```

> The flatpak is not used (its sandbox cannot see yabridge chainloaders). Disable auto-update in Bitwig (Dashboard > Settings > Misc).