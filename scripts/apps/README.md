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
APP vlc|VLC — media player
TUI bat|bat
WEB WhatsApp|https://web.whatsapp.com/|whatsapp
WEB TIDAL Hi-Fi (TidaLuna)|native:tidal-hifi-tidaluna|tidal-hifi
```

A `native:<pkg>` webapp is a desktop package kept in the webapps catalog because
it is conceptually a web app (it is installed with `yay`, not
`omarchy webapp install`). If `webapps/native-<pkg>.sh` exists, it runs with
`--install` after the package and `--remove` before removal; TIDAL Hi-Fi uses it
to hide the Electron menu bar (`menuBar: false`, `disableAltMenuBar: true`).

## Large installers

Nothing here is downloaded: Ableton and Bitwig are behind account logins, and a
multi-GB zip does not belong in a git clone. The clean technique is to drop
every installer you want into `~/Downloads`, then run `./bootstrap.sh` — it
moves each recognised file into its module folder (never overwriting an
existing file) and reports which Setup rows stay greyed out. You can also drop
a file straight into its module folder (`scripts/apps/ableton/`,
`scripts/apps/guitarpro/`, `scripts/apps/bitwig/`, `scripts/apps/davinci/`),
which is where each module's own installer looks anyway.

A missing installer is not a failure. The module that needs it stays visible in Setup, greyed
out, and Enter on the row names the exact file and folder instead of starting an install that
cannot finish. The decision is made with globs, never with the sha256, because `_setup_tree`
runs on every render of that screen.

DaVinci Resolve **is** inventoried, by presence only: its zip is about 11 GB, so recording a
checksum would mean hashing it on every `--check`.

## The other folders here

each is its own module with its own `README.md`, installed directly rather than through a
selection. See the module table in the [root README](../../README.md#modules).
