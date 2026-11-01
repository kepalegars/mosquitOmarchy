# addons

Lightweight, user-facing extensions that are re-applied automatically. An addon
is only two files — no framework, no patching mosquitOmarchy:

```text
my-addon/
├── addon.conf   # NAME="my-addon"
│                # DESCRIPTION="one line"
│                # ENABLED="yes"
└── install.sh   # idempotent; uses $MQ_REPO, $MQ_ADDON_DIR, $MQ_ADDON_NAME
```

`install.sh` runs as the normal user. Keep it small and idempotent: it will run
again after every mosquitOmarchy update. It may ask for sudo itself if it really
needs root, but an addon that only writes under `$HOME` needs no elevation.

## Discovery

Addons are read from:

1. this folder (`code/modules/addons/`) — shipped addons;
2. `~/.config/mosquitomarchy/addons/` — your own, same format, never committed.
   A user addon with the same `NAME` overrides the shipped one.

Installed addon names are recorded in
`~/.local/state/mosquitomarchy/addons-installed`. `setup-addons.sh --reinstall`
re-applies exactly those names at the end of a mosquitOmarchy update; an addon
whose folder has disappeared is skipped and quietly pruned from the record.

```bash
code/modules/addons/setup-addons.sh              # all enabled addons (bootstrap)
code/modules/addons/setup-addons.sh --reinstall  # after an update
code/modules/addons/setup-addons.sh --list
code/modules/addons/setup-addons.sh --status
```

## emoticon

Builds one Omarchy theme from a folder of wallpapers. The pictures are copied
into `~/.local/share/mosquitomarchy/addons/emoticon/wallpapers` first (so the
theme keeps them after the source disk is unplugged), then into the theme's
`backgrounds/` folder. The first image drives the palette; all images become
backgrounds.

Default source: `/run/media/mosquito/Crucial X9/BACKUP/Wallpaper`
Default theme: `Emoticon`

```bash
EMOTICON_SRC=/path/to/images EMOTICON_THEME_NAME=MyTheme \
  code/modules/addons/emoticon/install.sh
```

The theme is built but **not applied**; use `omarchy theme set Emoticon` when
ready. Plymouth/unlock styling is skipped (it needs sudo and is unrelated to
the desktop theme).
