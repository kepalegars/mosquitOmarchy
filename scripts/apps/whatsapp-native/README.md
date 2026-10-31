# WhatsApp — Omarchy module

Installs WhatsApp Web as a **native desktop app** built on Electron: a small
wrapper we own end-to-end (source committed next to this script), not a patched
AUR build. It covers everything a real chat client needs on Hyprland/Wayland:

- **Notifications that actually show up.** WhatsApp Web only uses desktop
  notifications once `Notification.permission` is `granted`; otherwise it falls
  back to its own in-page chime with **no popup** — the classic "it rings but nothing shows up". `main.js` grants the permission (request + check handlers)
  and `preload.js` forces `Notification.permission` to read `granted` in the
  page, so WhatsApp stops showing its *"Autoriser les notifications"* banner.
- **Silent notifications.** WhatsApp's in-page chime only fires while the window
  is unfocused, so the renderer is muted on blur/hide and unmuted on focus:
  notification pings are silent, voice messages you are listening to keep their
  audio.
- **Tray + close-to-tray.** Closing the window hides it to the tray; the tray
  menu reopens it or really quits.
- **No white tray-start window.** Login startup waits for Electron's first rendered
  frame, flashes it without stealing focus, then hides it. A normal menu launch
  waits for that rendered frame and stays visible; after Quit, launching again
  creates a visible window.
- **No menu bar.** `Menu.setApplicationMenu(null)` + the window menu removed.
- A **"WhatsApp"** applications-menu entry, its icon in the hicolor theme, and
  **login autostart** (`o.launch_on_start("whatsapp --start-in-tray")` in `~/.config/hypr/autostart.lua`).

## Install

```bash
scripts/apps/whatsapp-native/setup-whatsapp-native.sh          # interactive
scripts/apps/whatsapp-native/setup-whatsapp-native.sh -y       # non-interactive
scripts/apps/whatsapp-native/setup-whatsapp-native.sh --status # current state
```

The install is idempotent. It brings the `electron43` runtime through `pacman`
(via `mq_sudo`, a native polkit prompt when not root); everything else is
user-scoped.

## Files

| Path | Purpose |
|---|---|
| `~/.local/share/whatsapp-native/app/` | the Electron app (`main.js`, `preload.js`, `package.json`, `icon.png`) |
| `~/.local/bin/whatsapp` | launcher (Wayland flags + electron runtime) |
| `~/.local/share/applications/whatsapp.desktop` | the "WhatsApp" menu entry |
| `~/.local/share/icons/hicolor/256x256/apps/whatsapp.png` | the icon |
| `~/.config/hypr/autostart.lua` | the `o.launch_on_start("whatsapp --start-in-tray")` line |
| `~/.config/WhatsApp/` | WhatsApp Web login data (kept on uninstall) |

## Uninstall

```bash
scripts/apps/whatsapp-native/setup-whatsapp-native.sh --remove
```

or through the manager: `./mosquitomarchy-setup.sh --uninstall` (module
`whatsapp-native`). It removes the app, launcher, menu entry, icon and autostart
line. Your WhatsApp Web login data in `~/.config/WhatsApp/` is **kept**.
