# Apps / TUIs / Webapps — Omarchy module

Modular installer: one folder, one catalog and one install/uninstall script **per type** under `apps/` (`gui/guis.catalog`, `tui-tools/tuis.catalog`, `webapps/webapps.catalog`, shared helpers in `../lib/common.bash`).

`setup-apps.sh` is the **dispatch entry** that keeps the historical backup flow: it presents the combined selection then calls each type script with its subset. Each type script also runs standalone — add a type by adding its catalog + its folder + its script.

This folder also holds `download-assets.sh` (large installer files catalog).

## Install / uninstall

```bash
./apps/setup-apps.sh                  # interactive: choose backup then select
./apps/setup-apps.sh -y               # most recent backup, everything installed
./apps/setup-apps.sh --from-backup=F  # dated backup F (or an apps.selected file)
./apps/setup-apps.sh --list-selection # show selection, no install
./apps/setup-apps.sh --status         # state of apps/tuis/webapps, changes nothing
./apps/uninstall-apps.sh --all -y       # remove all catalog entries
```

Installs the apps/tuis/webapps of a **backup selection** (`apps.selected`), everything checked by default.

### Per-type standalone

```bash
./apps/gui/setup-guis.sh       --all -y             # GUI apps (guis.catalog)
./apps/tui-tools/setup-tuis.sh       --from-backup=B -y   # TUIs (tuis.catalog)
./apps/webapps/setup-webapps.sh --all -y            # webapps (webapps.catalog)
./apps/gui/uninstall-guis.sh     --status             # state, nothing done
./apps/webapps/uninstall-webapps.sh --all -y          # remove webapps
```

## Catalog format

One entry per line, type prefix kept — so `apps.selected` keeps the same lines whatever the catalog:

```
APP betterbird-fr-bin|Betterbird (e-mail)      # AUR/official package
TUI bat|bat                                    # terminal tool
WEB WhatsApp|https://web.whatsapp.com/|whatsapp # Omarchy webapp
```

## Large installer files — download-assets.sh

Checks each large file in the `assets.links` catalog (present/absent/corrupt via sha256), downloads what is missing using a `.part` file (resume with `-C -`), verifies the checksum, and finalizes atomically. URLs must be filled in `assets.links` by the person hosting the files.

```bash
./apps/download-assets.sh               # interactive (gum): select to download
./apps/download-assets.sh -y            # download all missing/corrupt files
./apps/download-assets.sh --status      # status of each file
./apps/download-assets.sh --check       # verify sha256 integrity
```

> **DaVinci Resolve is deliberately NOT in `assets.links`** — its zip (~7 GB) is dropped by hand in `scripts/apps/davinci/` (downloaded outside the script).