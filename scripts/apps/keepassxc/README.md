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

> **Why not the takeover?** An earlier version of this module *replaced*
> gnome-keyring with KeePassXC (D-Bus override + gnome-keyring masked +
> `[FdoSecrets] Enabled=true`). That makes KeePassXC answer every web app's
> secret request, showing the *"chromium is requesting access to Chromium Safe
> Storage"* prompt on **every** launch (even after "allow all & future"), and it
> cannot read secrets already stored by gnome-keyring — so apps like kDrive
> asked to log in again on every boot. KeePassXC FdoSecrets and gnome-keyring do
> not mix for app secrets. If you really want the takeover, opt in with
> `setup-keepassxc-integration.sh --secret-service` (existing gnome-keyring
> secrets must then be migrated manually).

## Default database — pin yours

`keepassxc-default-database.sh` (this folder, idempotent) opens YOUR .kdbx on
every KeePassXC launch:

- auto-detects the newest `*.kdbx` in `$HOME` (pass a path to override)
- writes `RememberLastDatabases/RememberLastKeyFiles`, and
  `LastOpenedDatabases` / `LastActiveDatabase` = that database
- that kills the "create a new database?" dialog that kept popping.

`--status` shows what is pinned, `--clear` restores the stock behaviour.

## Browser extension — the first connect is a handshake

The transport (native-messaging manifest + keepassxc-proxy) works as soon as the
extension is installed. But `"database not connected"` on a greyed in-field icon
is NOT a setup defect: no database is associated with that site yet, and the
association lives INSIDE the encrypted database, so only you can make it:

1. KeePassXC → Settings → Browser Integration: tick the browsers you use and
   *Connect to database on startup*.
2. Unlock the database in KeePassXC.
3. On the site, click the KeePassXC TOOLBAR icon (not the in-field one) →
   Connect, then approve the KeePassXC desktop popup for that URL.
4. From then on the in-field icon fills. One handshake per site.

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
