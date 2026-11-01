# WhatsApp — Omarchy module (Chromium web app + tray)

Installs WhatsApp Web as a **Chromium web app**, using the same `--app=` mode
Omarchy uses for its own web apps. The window is Chromium; there is no Electron
BrowserWindow, so the old wrapper's blank first paint cannot happen.

A tiny Electron process owns **only the tray icon and lifecycle**:

- **Login starts hidden in the tray.** Chromium is launched on the hidden
  `special:whatsapp` workspace; the tray icon opens it on the normal workspace
  the user is currently on (never a scratchpad/special workspace).
- **The login survives close-to-tray.** The dedicated profile keeps Chromium's
  cookie key in the profile (`--password-store=basic`) instead of the desktop
  keyring. The tray starts at login, often before the keyring/portal is
  unlocked; without a persisted key Chromium treats every saved cookie as
  invalid and WhatsApp asks for the QR code again.
- **Menu launch opens directly.** The *WhatsApp* entry runs `whatsapp %U`, which
  shows/focuses the existing window instead of starting another one.
- **Close-to-tray.** Closing the Chromium window exits the app; the supervisor
  relaunches it hidden, so it stays in the tray.
- **Silent notifications.** A content-script forces `silent: true` on WhatsApp
  Web notifications, and the supervisor mutes WhatsApp's audio stream while the
  window is hidden (so the in-page chime stays quiet). Voice messages you are
  listening to keep their audio.
- **No menu bar, no keybinding/shortcut.** The menu entry is created through
  `omarchy-webapp-install` with a custom `Exec`.
- **Login autostart**:
  `o.launch_on_start("whatsapp --start-in-tray")` in `~/.config/hypr/autostart.lua`.

## Install

```bash
code/modules/Apps/whatsapp-native/setup-whatsapp-native.sh          # install
code/modules/Apps/whatsapp-native/setup-whatsapp-native.sh -y       # non-interactive
code/modules/Apps/whatsapp-native/setup-whatsapp-native.sh --status # current state
```

The install is idempotent. It brings `chromium` and `electron43` through
`pacman` (via `mq_sudo`, a native polkit prompt when not root); everything else
is user-scoped.

## Files

| Path | Purpose |
|---|---|
| `~/.local/share/whatsapp-web/tray/` | the tray supervisor (`tray.js`, `package.json`, `icon.png`) |
| `~/.local/share/whatsapp-web/extension/` | silent-notification content script |
| `~/.local/share/whatsapp-web/profile/` | dedicated Chromium profile (WhatsApp login) |
| `~/.local/bin/whatsapp` | launcher: tray supervisor / show command |
| `~/.local/share/applications/WhatsApp.desktop` | the *WhatsApp* menu entry |
| `~/.config/hypr/autostart.lua` | the hidden-at-login autostart line |

## Uninstall

```bash
code/modules/Apps/whatsapp-native/setup-whatsapp-native.sh --remove
```

or through the manager: `./mosquitomarchy-setup.sh --uninstall` (module
`whatsapp-native`). It removes the launcher, tray supervisor, extension, menu
entry and autostart line. The WhatsApp login in
`~/.local/share/whatsapp-web/profile/` is **kept**.
