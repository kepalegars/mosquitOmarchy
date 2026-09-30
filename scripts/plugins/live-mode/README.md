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

## Settings

`~/.config/live-mode/settings`, one `KEY=value` per line. Every key is optional and
absent means "off", except `THERMAL_LIMIT_C` which keeps its default.

| Key | Effect |
|---|---|
| `THERMAL_LIMIT_C` | temperature the watcher starts reacting at |
| `CLOSE_APPS` | ask to close the apps below when the session starts |
| `CLOSE_APPS_LIST` | which ones, e.g. `"kDrive qBittorrent Steam Discord Slack Spotify"` |
| `ROUTING_TOOL` | patch the audio routing for the session |
| `NO_GAPS` | remove the Hyprland gaps for the session |
| `SILENCE_NOTIFICATIONS` | suppress notifications for the session |
| `FENCE_PACKAGES` | **opt-in** — block package installation for the session |
| `SWITCH_THEME` | swap the theme for the session |

The TUI edits these same keys, so the file and the TUI never disagree: `live-mode manage`
writes the file, and the file is what `on` reads.

## Activation prompt

`live-mode on` prints what it is *about to do*, built from the settings that are actually
in effect — never a generic list. If `CLOSE_APPS_LIST` names four apps, it says four apps,
and settings you never set are not mentioned.

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

`live-mode-root` reads the fence setting without sourcing the settings file, so a
malformed file cannot turn a value into code on the privileged path.

## The TUI

`live-mode manage` is a Go/Bubble Tea screen built on the shared
[`tui-kit`](../../lib/tui-kit): `tab` moves between rows, `←/→` or `space` toggles,
`enter` opens a row, `i` explains the highlighted setting, `?` lists every shortcut,
`esc` goes back. It is laid out for 74 columns and up; below that the list rows wrap.

## Troubleshooting

`live-mode status` reports what the session currently has applied. If `off` did not put
something back, the usual reason is that the snapshot was taken from a session that was
never finished — remove the stale flag under `~/.local/state/live-mode/` and run `off`
again.
