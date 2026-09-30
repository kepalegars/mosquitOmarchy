# Crunchy Cleaner — mosquitOmarchy integration

`setup-crunchycleaner-menu.sh` adds what the AUR package (`crunchycleaner-bin`)
does not: a launcher that runs the cleaner with the rights it needs, plus a
proper menu entry and icon.

Crunchy Cleaner removes system caches and junk, so most of its useful work needs
**root**. The package ships a bare `Exec=crunchycleaner` desktop entry, which
either fails silently on the system paths or asks nothing. This companion is
auto-run by `setup-tuis.sh` right after the AUR install (a `setup-<base>-menu.sh`
file is invoked for its catalog entry); it is also usable standalone.

## The pkexec launch (and the Esc / skip behaviour)

The menu entry does **not** call `crunchycleaner` directly. It calls a wrapper,
`~/.local/bin/crunchycleaner-root`, which does:

1. `pkexec crunchycleaner` — the normal, authorized launch, through the native
   **polkit** prompt (the same Omarchy elevation dialog the rest of the repo
   uses). `$SHELL` is pinned to a shell listed in `/etc/shells` first, because
   `pkexec` refuses to run otherwise.
2. **If you dismiss the pkexec prompt — press `Esc` / cancel — the wrapper runs
   `crunchycleaner` WITHOUT root** instead of doing nothing. You are never left
   stuck: the tool opens, just with the user's (limited) permissions.

```
launch → pkexec crunchycleaner ──authorized──▶ root run
                              └─dismissed (exit 126)─▶ non-root run
```

Concretely, `pkexec` exits with **126** when the authentication dialog is
dismissed (also 125/127 when it cannot run the command at all); the wrapper
treats those codes as "not elevated" and falls back to a plain, non-root launch
after printing:

```
pkexec cancelled — launching crunchycleaner without root…
```

Any other exit code is the cleaner's own and is returned unchanged (so a real
failure is never mistaken for a cancelled prompt).

## Files it manages

| Path | Role |
|---|---|
| `~/.local/bin/crunchycleaner-root` | the pkexec wrapper (the desktop entry's `Exec`) |
| `~/.local/share/applications/crunchycleaner.desktop` | menu entry, `Terminal=true`, `Exec=…/crunchycleaner-root` |
| `~/.local/share/icons/hicolor/256x256/apps/crunchycleaner.png` | icon (from `crunchycleaner-logo.png`) |

## Usage

```bash
./setup-crunchycleaner-menu.sh            # applies (idempotent)
./setup-crunchycleaner-menu.sh --remove   # removes the launcher + entry
```
