# emoticon — example addon

This is the reference example for the addon format used by **Extras → Addons**
in mosquitOmarchy. It is tracked in the repo; other addon folders are gitignored.

```text
emoticon/
├── addon.conf   # NAME, CATEGORY, DESCRIPTION, ENABLED
├── install.sh   # idempotent installer (re-run after updates)
├── remove.sh    # optional; unticking + Enter runs this
└── images/      # the addon's own wallpapers (tracked here)
```

`install.sh` receives `MQ_REPO`, `MQ_ADDON_DIR` and `MQ_ADDON_NAME`. It builds
one Omarchy theme (`Emoticon` by default) from `images/`: the first image drives
the palette and every image becomes a background. It never applies the theme,
so the desktop is left alone until you run:

```bash
omarchy theme set Emoticon
```

To import another folder once, run the addon from the terminal with
`EMOTICON_SRC=/path/to/wallpapers`; the pictures are copied into `images/`.
`remove.sh` deletes the generated theme but keeps the pictures.
