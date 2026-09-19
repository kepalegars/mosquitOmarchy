# Zen Browser config module

Deploys the user's Zen browser configuration (plugins + settings + chrome
theme) into the **active** Zen profile.

## What

- **Extensions (XPI)** — `seed/extensions/` → `<profile>/extensions/`
  - `{91aa3897-2634-4a8a-9092-279db23a7689}.xpi` — Zen Internet (browser-UI mods)
  - `addon@darkreader.org.xpi` — Dark Reader
  - `uBlock0@raymondhill.net.xpi` — uBlock Origin
  - `keepassxc-browser@keepassxc.org.xpi` — KeePassXC-Browser (password autofill)
- **Extension settings** — `seed/extension-preferences.json`,
  `seed/extension-settings.json` → `<profile>/`
- **Chrome / userChrome** — `seed/chrome/` (zen-themes.css + zen-themes/) → `<profile>/chrome/`

The active profile is detected from `~/.config/zen/profiles.ini`:

1. the `[Install...]` block (`Default=<profile>`) — what `zen-bin` actually runs,
2. fallback: the `[Profile...]` block marked `Default=1`,
3. fallback: the profile with the most recently modified `places.sqlite`.

## Dependency

- `zen-browser-bin` (AUR / the "apps" module `APP zen-browser-bin`). The
  restore-time deps mechanism uses this module's `deps` file.

## Usage

```bash
./setup-zen.sh          # deploy the seed config into the active profile
./setup-zen.sh -y       # non-interactive (overwrites differing files)
./setup-zen.sh --status # report the active profile + applied state
./setup-zen.sh --remove # remove what this module deployed (extensions + settings + chrome)
```

Only files exactly matching the seed are overwritten silently; hand-tweaked
copies are preserved unless you confirm (or pass `-y`).

## Re-sync the seed

The seed is the canonical copy of your Zen config. To refresh it from the
live profile after changing extensions/themes, re-copy from:

```bash
ZP="$HOME/.config/zen/$(grep -A2 '^\[Install' ~/.config/zen/profiles.ini | grep '^Default=' | cut -d= -f2)"
cp -a "$ZP/extensions/." scripts/apps/zen/seed/extensions/
cp -a "$ZP/extension-preferences.json" "$ZP/extension-settings.json" scripts/apps/zen/seed/
cp -a "$ZP/chrome/." scripts/apps/zen/seed/chrome/
```

## Orphan cleaning

Extensions you removed from the browser outlive this module's seed copies in
`<profile>/extensions/`. It's safe to delete orphans manually while Zen is
closed; installed extensions you *want* are all re-deployable from the seed.

## KeePassXC-Browser setup (enabled browser integration)

The `keepassxc-browser` XPI deployed from the seed only **adds** the extension.
To make autofill actually work, enable the native-messaging bridge on the
KeePassXC side:

1. *KeePassXC → Settings → Browser Integration* — tick **Firefox and
   variants** (this writes the bridge file
   `~/.mozilla/native-messaging-hosts/org.keepassxc.keepassxc_browser.json`,
   which the native Zen build reads exactly like Firefox; the Flatpak caveat in
   [zen-browser/desktop#11084](https://github.com/zen-browser/desktop/issues/11084)
   does not apply here),
2. *Settings → Browser Integration → Advanced* — tick **Connect to database on
   startup** (optional, autofill convenience),
3. restart Zen, click the KeePassXC-Browser toolbar icon in Zen → **Connect**,
   and grant access in KeePassXC's confirm popup.

Only the XPI is versioned in the seed; the bridge file lives only on this
machine (personal path, not backed up — it's recreated by KeePassXC itself).