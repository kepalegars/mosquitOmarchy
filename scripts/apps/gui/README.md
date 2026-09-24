# GUI apps module — guis.catalog

Installs the GUI applications listed in `guis.catalog` (type `APP`, AUR/official
packages via `yay`). This is the per-type installer behind `apps/setup-apps.sh`
— see [apps/README.md](../README.md) for the module overview, the catalog
format and the standalone usage:

```bash
./apps/gui/setup-guis.sh --all -y              # install every GUI app
./apps/gui/setup-guis.sh --status              # state, nothing done
```

## KeePassXC — password manager

**Backup is handled by the orchestrator**: when KeePassXC is installed,
`./mosquitomarchy-setup.sh --backup` includes its settings
(`~/.config/keepassxc/keepassxc.ini`) and the password database
(`~/Documents/Passwords.kdbx`) in the dated archive under
`~/omarchy-backups/`. Password files never enter the repository (ultra
safety — `.gitignore` additionally guards `*.kdbx`). `--restore` puts them
back to their original locations. The database is not stored in plaintext
form anywhere other than protected by KeePassXC's own master password.

### Window behavior in Hyprland

KeePassXC does not adapt well when tiled next to other windows. Apply the
window fix to float/center it (idempotent, safe to re-run):

```bash
./scripts/fixes/fix-keepassxc-window.sh
```

It is also registered as the `keepassxc-window` quick fix in
`./mosquitomarchy-setup.sh` (multi-select list at startup, or applied
automatically with `-y`).

### Browser integration (KeePassXC-Browser)

1. KeePassXC → Tools → Settings → KeePassXC-Browser → enable
   "KeePassXC_Browser integration" (and "Connect (Notification)" if you want
   the click-to-connect prompts).
2. Zen Browser → the `zen` module seed already ships the
   `keepassxc-browser@keepassxc.org` extension — install/enable it via
   `./mosquitomarchy-setup.sh --include=zen`, or add it manually from the
   Zen Add-ons page ("KeePassXC-Browser", extension id
   `keepassxc-browser@keepassxc.org`).
3. Open the extension's toolbar popup → Connect. Back in KeePassXC, accept
   the pairing (the app proposes to remember it).

Unlock the database once per session and the browser fills/autosaves
credentials. The proxy binary (`keepassxc-proxy`) is installed with the app
and auto-registered in `~/.mozilla/native-messaging-hosts/`.

## Papers — replace Evince (document viewer, OPTIONAL)

Moved out of the apps module: swapping the system document viewer is a
deliberate system-wide change, so it now ships as an idempotent fix in
`scripts/fixes/`:

```bash
./scripts/fixes/fix-replace-evince-with-papers.sh            # apply the swap
./scripts/fixes/fix-replace-evince-with-papers.sh --status   # current state
./scripts/fixes/fix-replace-evince-with-papers.sh --uninstall  # revert to Evince
```

It installs `papers` (via `yay`), makes it the default handler for every
document MIME type it advertises, hides Evince from the menus while keeping the
package (sushi depends on it), floats Papers in Hyprland, and follows the
current Omarchy theme interface-wide.