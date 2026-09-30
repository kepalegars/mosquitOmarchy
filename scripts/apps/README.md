# `apps` — the app / TUI / webapp catalogs

One folder, one catalog and one install/uninstall script **per type**. `setup-apps.sh` is the
dispatcher: it shows the combined selection, then calls each type script with its subset. Each
type script also runs standalone.

Adding a type means adding its catalog, its folder and its script.

```bash
scripts/apps/setup-apps.sh                     # interactive
scripts/apps/setup-apps.sh -y                  # everything from the latest backup
scripts/apps/setup-apps.sh --from-backup=FILE  # a dated backup, or an apps.selected
scripts/apps/setup-apps.sh --list-selection    # show the selection, install nothing
scripts/apps/setup-apps.sh --status            # state of each type, changes nothing
scripts/apps/uninstall-apps.sh --all -y
```

## Per type

| Type | Catalog | Install | Uninstall |
|---|---|---|---|
| GUI apps | `gui/guis.catalog` | `gui/setup-guis.sh --all -y` | `gui/uninstall-guis.sh --all -y` |
| TUIs | `tui-tools/tuis.catalog` | `tui-tools/setup-tuis.sh --all -y` | `tui-tools/uninstall-tuis.sh --all -y` |
| Webapps | `webapps/webapps.catalog` | `webapps/setup-webapps.sh --all -y` | `webapps/uninstall-webapps.sh --all -y` |

## Catalog format

One entry per line, the type prefix kept, so `apps.selected` holds the same lines whichever
catalog it came from. `|`-separated, `#` starts a comment.

```
APP betterbird-fr-bin|Betterbird (e-mail)
TUI bat|bat
WEB WhatsApp|https://web.whatsapp.com/|whatsapp
```

## Large installers

`download-assets.sh` reads the `assets.links` catalog at the repo root: it checks each file
(present / absent / corrupt by sha256), downloads what is missing through a `.part` file so an
interrupted run resumes, verifies the checksum, then renames into place. The URLs in
`assets.links` are filled in by whoever hosts the files.

```bash
scripts/apps/download-assets.sh            # select interactively
scripts/apps/download-assets.sh -y         # everything missing or corrupt
scripts/apps/download-assets.sh --status
scripts/apps/download-assets.sh --check    # sha256 only
```

DaVinci Resolve is deliberately **not** in `assets.links` — its zip is about 7 GB, so it is
dropped by hand in `scripts/apps/davinci/`.

## The other folders here

`ableton/`, `bitwig/`, `reaper/`, `davinci/`, `zen/` and the rest are **not** catalog entries:
each is its own module with its own `README.md`, installed directly rather than through a
selection. See the module table in the [root README](../../README.md#modules).
