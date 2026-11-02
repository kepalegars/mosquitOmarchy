# keepassxc — password manager + browser integration (Omarchy keyring stays intact)

`setup-keepassxc-integration.sh` keeps **KeePassXC** as your personal password
manager and wires the **KeePassXC-Browser** extension to it. It does **not**
touch Omarchy's system keyring: gnome-keyring keeps serving the
freedesktop.org Secret Service (`org.freedesktop.secrets`) for apps.

What it sets up:

- **Browser integration** — writes the native-messaging manifests for Firefox/Zen
  (`~/.mozilla/native-messaging-hosts/`) and Chromium/Brave/Vivaldi
  (`~/.config/<browser>/NativeMessagingHosts/`), pointing at
  `/usr/bin/keepassxc-proxy`, and sets `keepassxc.ini` → `[Browser] Enabled=true`.
  (KeePassXC normally writes these from its Settings UI; the Chromium one was
  missing here, which is why the link "never worked".)
- **Omarchy keyring left intact** — `[FdoSecrets] Enabled=false`, no D-Bus
  override, gnome-keyring not masked. LibreSecret apps (Chromium "Safe Storage",
  kDrive tokens, …) keep using the passwordless **Default keyring**, so you are
  never asked to grant KeePassXC access and apps do not lose their login.
- **Tray on close** — `[GUI] ShowTrayIcon/MinimizeToTray/MinimizeOnClose = true`:
  closing the window hides KeePassXC to the tray instead of quitting.
- **Default database pin** — see below.
- **Launch at login** — the selected KeePassXC settings include the app's
  `~/.config/autostart/org.keepassxc.KeePassXC.desktop` entry when enabled.

> **Known limitation:** KeePassXC-Browser integration is not working yet in
> this setup. The module writes native-messaging manifests and enables the
> browser setting, but that has not produced a working browser connection.
> This integration is explicitly not fixed by the current module.

> **Why not the takeover?** An earlier version of this module *replaced*
> gnome-keyring with KeePassXC (D-Bus override + gnome-keyring masked +
> `[FdoSecrets] Enabled=true`). That makes KeePassXC answer every web app's
> secret request, showing the *"chromium is requesting access to Chromium Safe
> Storage"* prompt on **every** launch (even after "allow all & future"), and it
> cannot read secrets already stored by gnome-keyring — so apps like kDrive
> asked to log in again on every boot. KeePassXC FdoSecrets and gnome-keyring do
> not mix for app secrets. The `gnome-keyring` package is never removed by this
> module. If you really want KeePassXC to take over the Secret Service, opt in
> manually with `setup-keepassxc-integration.sh --secret-service` (existing
> gnome-keyring secrets must then be migrated manually).

## Default database — pin yours

`keepassxc-default-database.sh` (this folder, idempotent) opens YOUR .kdbx on
every KeePassXC launch:

- auto-detects the newest `*.kdbx` in `$HOME` (pass a path to override)
- writes `RememberLastDatabases/RememberLastKeyFiles`, and
  `LastOpenedDatabases` / `LastActiveDatabase` = that database
- that kills the "create a new database?" dialog that kept popping.

`--status` shows what is pinned, `--clear` restores the stock behaviour.

## Browser integration — not working yet

The steps to connect the extension are intentionally omitted until the
browser-to-KeePassXC integration is fixed and verified.

## What stays manual by design

- **The secrets transfer** (only with `--secret-service`): every gnome-keyring
  secret must be ported to the KeePassXC database MANUALLY — this module never
  deletes or duplicates keyring data.
- **Which database/group is exposed** (only with `--secret-service`) lives
  inside the ENCRYPTED database: KeePassXC → Tools → Settings → Secret Service
  Integration, then Database → Database Settings → expose a group.
- **Restart KeePassXC once** after applying if it was already running as the
  Secret Service, so it releases `org.freedesktop.secrets`.

## Uninstall

`uninstall` (the Uninstall tree, or `--remove`) removes the browser manifests,
clears the database pin, and — if a takeover was active — restores the Omarchy
default (removes the D-Bus override, restores the shadowed autostart, unmasks
gnome-keyring, sets `FdoSecrets/Enabled=false`, starts gnome-keyring again). It
does NOT touch the KeePassXC database or settings.
