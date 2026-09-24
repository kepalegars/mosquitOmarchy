# KeePassXC — system Secret Service (replaces gnome-keyring)

`setup-keepassxc-integration.sh` makes **KeePassXC** the desktop's system-wide
Secret Service provider (the D-Bus `org.freedesktop.secrets` name) in place of
gnome-keyring — the upstream-documented way:

- **D-Bus activation override** — `~/.local/share/dbus-1/services/org.freedesktop.secrets.service`
  with `Exec=/usr/bin/keepassxc` (wins over the system gnome-keyring file;
  the system file itself is untouched and backed up next to ours).
- **Session shadowing of gnome-keyring**: `~/.config/autostart/gnome-keyring-secrets.desktop`
  marked `Hidden=true` (user autostart wins over `/etc/xdg/autostart`) plus
  `systemctl --user mask gnome-keyring-daemon.service`.
- **`keepassxc.ini`** → `[FdoSecrets] Enabled=true` — the exact flag
  KeePassXC writes when the integration is ticked (verified against
  `src/core/Config.cpp`, 2.7.12: `FdoSecrets/Enabled`).


## Default database — pin yours

`keepassxc-default-database.sh` (this folder, idempotent) opens YOUR .kdbx on
every KeePassXC launch:

- auto-detects the newest `*.kdbx` in `$HOME` (pass a path to override)
- writes `RememberLastDatabases/RememberLastKeyFiles`, and
  `LastOpenedDatabases` / `LastActiveDatabase` = that database
- that kills the "create a new database?" dialog that kept popping when a web
  app's browser extension asked KeePassXC through the FdoSecrets channel.

`--status` shows what is pinned, `--clear` restores the stock behaviour.


## What stays manual by design

- **The secrets transfer**: every gnome-keyring secret must be ported to the
  KeePassXC database MANUALLY — the automated transfer is planned LATER; this
  module never deletes or duplicates keyring data.
- **Which database/group is exposed** to apps lives inside the ENCRYPTED
  database, so it stays interactive: KeePassXC → Tools → Settings → Secret
  Service Integration (confirm the enable), then Database → Database Settings
  → Secret Service Integration → expose a group.
- **Removing the gnome-keyring package is optional and ASKED** during setup:
  its settings stay on the disk, so a plain reinstall of gnome-keyring
  recovers them.

## Uninstall

`uninstall` (the Uninstall tree) restores the Omarchy default: removes our
D-Bus override, restores the shadowed autostart, unmasks the service, sets
`FdoSecrets/Enabled=false` and starts the gnome-keyring secret service again.
It does NOT reinstall the gnome-keyring package if it was removed (`sudo
pacman -S gnome-keyring` brings it back, settings intact) and it does NOT
touch the KeePassXC database or settings.
