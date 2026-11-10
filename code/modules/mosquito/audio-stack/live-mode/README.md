# live-mode

A session profile for focused work: it changes a handful of desktop settings when you
start a session and puts them back when you stop. Everything it touches is listed below,
and `off` restores what it found rather than assuming a default.

```bash
live-mode on       # apply the profile
live-mode off      # restore
live-mode toggle
live-mode status
live-mode manage   # the TUI
```

The bar's stay-awake icon is owned by `mosquito.mega-caffeine`, which reads the
live-mode state files: while a session runs, the icon blinks red. Live mode
does not install that indicator — without mega-caffeine it works the same, only
the coffee icon is missing. The module's own prompts (the red frame and the
Yes/No card) live inside `mosquito.livemode`, so there is no separate confirm
plugin.

## Settings

`~/.config/live-mode/settings`, one `KEY=value` per line. Every key is optional and
absent means "off", except `THERMAL_LIMIT_C` which keeps its default.

| Key | Effect |
|---|---|
| `THERMAL_LIMIT_C` | temperature the watcher starts reacting at |
| `CLOSE_APPS` | close the apps below when the session starts |
| `CLOSE_APPS_LIST` | which ones, `\|`-separated so names with spaces work. Default: `Superwhisper` |
| `RELAUNCH_APPS` | **opt-in** — start the apps the session closed again on deactivation (default `no`) |
| `DISABLE_PASSWORDLESS_SUDO` | **on by default** — at activation, install the scoped `live-mode-root` grant and delete every broad `NOPASSWD: ALL` drop-in. One way: nothing restores them. |
| `PIPEWIRE_AUTOLOCK` | **on by default** — start the PipeWire Settings widget locked during live mode. `no` leaves the values editable; `L` locks/unlocks either way. || `ROUTING_TOOL` | park the audio mixer/patchbay in the scratchpad for the session |
| `PATCHBAY_APP` | which scratchpad audio app(s): `mixbay+qpwgraph` (both, the default, opened tiled side by side), `mixbay`, `qpwgraph` or `mosquito-patchbay` |
| `POWER_PROFILE_PROMPT` | ask before the session takes the performance profile back after a hand change (default yes; no = silent forcing) |
| `NO_GAPS` | remove the Hyprland gaps for the session |
| `SILENCE_NOTIFICATIONS` | suppress notifications for the session (the pre-session DND state is restored) |
| `FENCE_PACKAGES` | **opt-in** — block package installation for the session |
| `SWITCH_THEME` | swap the theme for the session |

The TUI edits these same keys, so the file and the TUI never disagree: `live-mode manage`
writes the file, and the file is what `on` reads.

The manager lists **installed** apps only. The background-apps page shows the selected
ones plus **+ Add an app to close**; that opens the full app list (Tab toggles, Enter
saves and returns). Enter on the selected page removes one and stays there. Apps that are
uninstalled disappear from both lists but keep their name in `CLOSE_APPS_LIST`, so they come
back ticked if reinstalled.

## Scratchpad audio apps

The session parks **mosquito mixbay** (the desk tool) **plus qpwgraph** (the
PipeWire graph) in the scratchpad by default, **both tiled** side by side —
mixbay has a float/center window rule for its login autostart, and live mode
clears it when parking. The same applies when the watchdog puts them back after
a close attempt. The installer **always installs qpwgraph when it is missing**
(via the usual one-question password prompt), so the slot is never half empty.

For the full live-mode desk, installing **mosquito mixbay** (mosquitomarchy
Setup › mosquito) is strongly recommended: qpwgraph alone only shows the graph,
while mixbay is the actual mixer surface.

If **neither** app is on the machine, the two scratchpad rows in the manager
(*Audio mixer/patchbay in the scratchpad* and *Scratchpad app*) are greyed out
and cannot be used. They become available again automatically as soon as
mixbay or qpwgraph is installed — no setting to flip, just install one of them
and reopen the manager.

## Theme and default shortcuts

The **Live theme** (branded black wallpaper, all accents red) is installed by
the setup in `~/.local/state/live-mode/theme`, outside
`~/.config/omarchy/themes`. Omarchy only resolves theme names from that scanned
directory, so live mode links it in for the duration of each `theme set` call
and removes the link immediately after: **Live never appears in the Omarchy
theme picker**. The theme in use before activation is restored on deactivation.

While a session runs, Omarchy's **default theme/background keybindings**
(`SUPER+CTRL+T`, `SUPER+CTRL+W`, `SUPER+CTRL+SPACE`, `SUPER+SHIFT+CTRL+SPACE`)
are unbound so a stray key cannot throw the desktop (and every terminal) into
another theme mid-session. A shortcut **you** bound to the theme/background
menu keeps working: only the system defaults are blocked. `off` reloads the
Hyprland config, which restores them.

## Notifications DND

The pre-session do-not-disturb state is saved at activation and put back on
deactivation: if DND was off, it is turned back off. The state is read from
`~/.local/state/omarchy/notifications/quiet.json` through
`omarchy-shell notifications isDnd`, and set with `setDnd` (idempotent — no
more blinking icon from a toggle loop).

## PipeWire settings

If the `pipewire-settings` module is installed, live mode puts its widget in
live mode: the current rate/quantum are forced, remember-on-restart is set
aside, and the widget locks its two values (greyed, arrows hidden, nothing
selectable) when `PIPEWIRE_AUTOLOCK` is on (the default). With it off, the
values start editable.

**L** locks the values immediately, and when locked it asks before unlocking:
the confirmation replaces the widget's interface inside the same panel (no
resize). `off` restores the pre-live force/pin state and the persisted config.

## Passwordless sudo

`DISABLE_PASSWORDLESS_SUDO=yes` (the default) runs one hardening step at the
end of activation: it installs the scoped `live-mode-root` sudoers grant (so
`off` and the thermal guard keep working) and deletes every broad
`NOPASSWD: ALL` drop-in, such as Omarchy's temporary
`99-omarchy-nopasswd-<uid>`. **Nothing restores them**; re-running the setup is
the only way to get a broad grant back.

## Power profile

While a session is active, live mode pins the `performance` profile (the
watchdog reasserts it). Activation sets it **directly**, before the watchdog's
first pass, so starting a session never asks a confirmation question; the
question is only for a hand change mid-session. Change the profile with live
mode **off**.

`POWER_PROFILE_PROMPT=yes` (the default) still lets you try: the watchdog
asks once per hand-picked value whether to switch back — accept and the
session takes performance back, refuse and that value is left alone until it
changes again. Set it to `no` for the old silent forcing.

## Activation prompt

`live-mode on` prints what it is *about to do*, built from the settings that are actually
in effect — never a generic list. The background-apps line names the **running**
apps that will be closed, not the stored list: the old line announced six apps the
machine did not even have. If `RELAUNCH_APPS=yes`, the card also says the closed
apps will be started again on exit.

## The package fence

`FENCE_PACKAGES=yes` creates `/var/lib/pacman/db.lck` for the session, so **every** package
operation on the machine fails rather than upgrading something underneath you. It is
**off by default** and only ever active while a session is on.

Two properties matter, and both are tested:

- The lock is removed only if nothing holds it. `fuser` is checked first, so a `pacman`
  that legitimately owns the file is never deleted out from under itself.
- A lock that was not this module's is never touched. The fence is keyed to the flag
  written here, not to the mere existence of the path.

## Files

| Path | Role |
|---|---|
| `~/.local/bin/live-mode` | the front end: reads settings, prints the prompt, calls the root helper |
| `~/.local/bin/live-mode-root` | the privileged part: applies and restores, the only part that needs root |
| `~/.local/bin/live-mode-watch` | watches the temperature against `THERMAL_LIMIT_C` |
| `~/.config/live-mode/settings` | the settings above |
| `~/.local/state/live-mode/` | flags and the pre-session snapshot the restore reads |
| `~/.local/state/live-mode/theme/` | the installed Live theme (branded wallpaper) |

`live-mode-root` reads the fence setting without sourcing the settings file, so a
malformed file cannot turn a value into code on the privileged path.

## The TUI

`live-mode manage` is a Go/Bubble Tea screen built on the shared
[`tui-kit`](../../../../lib/tui-kit): `tab` moves between rows, `←/→` or `space` toggles,
`enter` opens a row, `i` explains the highlighted setting, `?` lists every shortcut,
`esc` goes back. It is laid out for 74 columns and up; below that the list rows wrap.

## Troubleshooting

`live-mode status` reports what the session currently has applied. If `off` did not put
something back, the usual reason is that the snapshot was taken from a session that was
never finished — remove the stale flag under `~/.local/state/live-mode/` and run `off`
again.
