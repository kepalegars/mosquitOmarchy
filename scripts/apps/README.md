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

`download-assets.sh` reads the `assets.links` inventory at the repo root and reports what is
already on disk: present, absent, or corrupt by sha256. **It downloads nothing.** There is no URL
column and there is not going to be one — Ableton and Bitwig are behind account logins, and a
4 GB zip does not belong in a git clone. Supply a file by dropping it into the folder
`assets.links` names, which is where its module's own installer looks anyway.

```bash
scripts/apps/download-assets.sh                    # one line per file + what to supply by hand
scripts/apps/download-assets.sh --status          # the list only
scripts/apps/download-assets.sh --check           # integrity: exit 1 on corruption, 0 on absence
scripts/apps/download-assets.sh --ready <path>    # silent; 0 = usable, 1 = not
```

A missing installer is not a failure. The module that needs it stays visible in Setup, greyed
out, and Enter on the row names the exact file and folder instead of starting an install that
cannot finish. The decision is made with globs, never with the sha256, because `_setup_tree`
runs on every render of that screen.

DaVinci Resolve **is** inventoried, by presence only: its zip is about 11 GB, so recording a
checksum would mean hashing it on every `--check`.

## The other folders here

`ableton/`, `bitwig/`, `reaper/`, `davinci/`, `zen/` and the rest are **not** catalog entries:
each is its own module with its own `README.md`, installed directly rather than through a
selection. See the module table in the [root README](../../README.md#modules).
