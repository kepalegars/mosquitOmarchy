# `scripts/`

Everything except the two root entry points — `bootstrap.sh` (clone + setup) and
`mosquitomarchy-setup.sh` (the orchestrator) — and the repo metadata.

Run modules through the orchestrator or the [TUI](../README.md#the-tui), not by hand. Each
module's own `README.md` is the reference for its commands, options and caveats; nothing is
duplicated here.

## Folders

| Entry | What it is |
|---|---|
| `apps/` | one folder per app, plus the app / TUI / webapp catalogs — [README](apps/README.md) |
| `apps/mosquitomarchy/` | the launcher TUI, its backend and the `SUPER` keybinding primitives — [README](apps/mosquitomarchy/README.md) |
| `plugins/` | Omarchy shell plugins: `live-mode/`, `jamjamjam/`, `power-management/` |
| `fixes/` | small idempotent fixes, proposed at startup — [README](fixes/README.md) |
| `lib/` | shared helpers — `tui-kit/` (the Go component library), `common.bash`, `crash.bash`, `elevate.bash`, `keybindings.bash` |
| `theme/` `LLM/` `deps/` | theme creation, Ollama, and package lists for things with no module folder |
| `windows-vm/` `macos-vm/` `omarchy-vm/` | the three VM modules |
| `mosquitomarchy-update/` | the update watchdog: scripts repo first, then Omarchy |
| `archive-mosquitomarchy.sh` | builds the release tarball — [root README](../README.md#scriptsarchivemosquitomarchy-sh) |

Every script resolves its resources from its own directory, so a whole folder can be moved
without breaking its paths. Right-click a `setup-*.sh` → **Run as a Program** to open it in a
terminal; `gui-run.bash` handles that.

## Elevation — one prompt per run

`lib/elevate.bash` provides `mq_sudo`, and a run asks for the password **once**, not once per
step:

1. `mq_sudo_prime` runs at the start of a module batch, a fix batch and each uninstall. If
   `sudo -n -v` already succeeds it does nothing. Otherwise it starts a persistent root
   helper behind a **single `pkexec`** — the native Omarchy polkit prompt — and every later
   root command of the run goes through that helper.
2. Without polkit, it primes sudo's timestamp once through a GUI askpass (`zenity`, else
   `systemd-ask-password`), which works with no tty; a background keep-alive holds the cache.
3. Last resort, per-call `pkexec` through a `sudo`→`pkexec` shim.

Installing a selection primes once for the whole selection. Read-only queries (`--status`,
and the TUI's read-only screens) never elevate.

## Crash reporting

Scripts source `lib/crash.bash` and call `mq_crash_guard "<tool>"`. On failure they write one
dated log to the repo-local `.local/crash-logs/` — never committed, never archived — and raise
a critical, clickable notification. Clicking it runs `mosquitomarchy-agent-crash`, which opens
the default coding agent on the `mosquitomarchy-crash` skill with that exact log; the agent
diagnoses and **proposes** a fix, applying nothing until confirmed. The skill is symlinked
into `~/.agents/skills/` so any agent that reads skills finds it.

`setup-*.sh` installers are exempt — their failures are reported by the orchestrator's own
summary instead.
