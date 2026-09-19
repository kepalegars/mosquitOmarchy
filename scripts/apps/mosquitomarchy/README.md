# mosquitOmarchy (the launcher TUI)

The Go/Bubble Tea interface for the mosquitOmarchy setup launcher. It replaced
the old `gum`-based `launcher_menu` of `setup-customarchy.sh`: every decision
(which module, which items, confirm/cancel) is made here, and every action
shells out to the engine — no business logic is reimplemented in Go.

```
mosquitomarchy              # dispatcher: opens the TUI (in a terminal, or in foot if detached)
mosquitomarchy-tui          # the compiled Bubble Tea program (built by the installer)
mosquitomarchy-actions      # non-interactive backend, sources setup-customarchy.sh in LIB_ONLY mode
```

`setup-customarchy.sh` is still the engine and remains usable by hand; the TUI
is the recommended interface.

## Screens

| Screen | What it does |
|---|---|
| **Status** | Every module with a state dot (● ok, ◐ partial, ○ missing, · n/a) and an "(uninstalled by you)" tag. Scrollable. |
| **Update** | Checks the scripts repo for a newer version and the changed installed modules; offers `Update the repo` and re-applying the selected modules. |
| **Setup** | One expandable tree of every category (folders) and its installable items — see below. |
| **Uninstall** | The SAME category/folder tree as Setup, but only the **installed** entries; `enter` uninstalls the checked items (or the highlighted row). |
| **Health check** | Lists what drifted from your chosen install — partially-installed modules (files went missing) and missing mosquitOmarchy pieces (TUI, float rule, menu entry, shortcut, update hook, crash skill) — then offers to **re-apply** them cleanly. |
| **Backup / Restore** | Create a dated archive (plain `.tar.gz` or encrypted AES-256 `.gpg`), or restore one. |
| **Close** | Asks for confirmation, then leaves. |

## Setup

Setup is two levels. The first screen lists the **categories** as plain
options, plus **Menu entry**, **Add shortcut for mosquitOmarchy** and
**Install selection**; entering a category opens its **folder tree** — the same
folder lists the Audio Plugin Manager uses. Categories and the scripts inside
them are always listed in **alphabetical order**:

```
Apps  (9)
mosquito  (5)  ■
Quick fixes  (2/6)  ■
Menu entry
Add shortcut for mosquitOmarchy
Install selection
Back
```

A category that has checked items shows a **■** and the **selected count**
(`(2/6)`), and **Install selection** (greyed out and skipped when nothing is
checked) installs every selection from all submenus at once, after a
confirmation that lists them. `Menu entry` registers the launcher in the
Omarchy menu; `Add shortcut for mosquitOmarchy` binds **SUPER + ALT + M** to
open the TUI (offered once on the very first launch, then available here).

```
▾ ●  mosquito
    ├─ ●  mosquito-live-mode
    └─ ●  mosquito-jamjamjam
```

- `tab` toggles the highlighted row. On a **folder** head it selects/deselects
  every child at once (one keystroke always flips to an extreme).
- `←` / `→` collapse / expand the folder under the cursor.
- `i` opens an **info** popup with the highlighted entry's full description —
  row descriptions are never shown inline (this includes the Setup **Menu
  entry** option).
- `enter` **installs only what is checked in the current category**, after a
  confirmation listing those items; the shortcut bar always reads
  `enter install selection`. `Back` returns one level up (level 1 then shows
  the per-category selected counts).
- The **mosquito** title is highlighted in the theme accent and blinks (the
  count next to it stays static).

**Missing installer prompt** — some apps (Ableton, Bitwig, Guitar Pro, DaVinci)
need a file you download by hand. Before running a selection, the TUI asks the
backend which of the selected apps is missing its installer and, if any, shows
a dialog naming the exact file and download link **instead of running** — so the
failure is never buried in the run log. The same check aborts (with the file
name) when a `setup-*.sh` is run non-interactively.

**Menu entry** (a first-level Setup option) adds/refreshes the mosquitOmarchy
entry in **Omarchy menu → Install → mosquitOmarchy**
(`~/.config/omarchy/extensions/omarchy-menu.jsonc`); it is idempotent.

Option rows that cycle a short list (VST mode, KeePass include/skip, encrypt
yes/no) are changed with **←/→**.

## Uninstall

**Uninstall** is the mirror of Setup: the same categories, in the same
alphabetical order, but each folder lists only the entries that are actually
**installed** (and not already marked uninstalled by you). `tab` selects,
`enter` uninstalls the checked items — or the highlighted row when nothing is
checked — after a confirmation. Like Setup, level 1 also offers **Uninstall
selection** (greyed out when nothing is checked), which removes everything
ticked across all folders at once. Module entries call the module's own
uninstall; catalog entries (TUIs/webapps) are routed to the apps module's
uninstaller. The list refreshes after each removal, so entries disappear as they
go.

Three extra folders only exist here:

- **Patches** — shown only when an installed app has an **applied** patch
  (DaVinci, Ableton, Bitwig, Guitar Pro); uninstalling one runs the patch's
  `--revert` (e.g. restores the stock `resolve` binary).
- **Quick fixes** — the quick fixes that can be removed, run with their
  `--remove`/`--uninstall` mode.
- **Menu & shortcuts** — removes the mosquitOmarchy Omarchy-menu entry and/or
  the `SUPER + ALT + M` shortcut.

## Backup encryption

Backups are dated archives of `~/.config` (hypr, terminal, Omarchy extensions
and plugins, keymaps, app preferences…) written to `~/omarchy-backups`.
**Backup options** asks the same content questions as the old flow before
building the archive:

- **Apps / TUIs / webapps** — a checkbox tree of the installed catalog entries
  (pre-checked from the previous backup), written to `apps.selected`.
- **VST plugins** — `list only` / `full files` / `skip`.
- **KeePassXC passwords** — include / skip (only offered when installed).
- **Encrypt** — `no`, or `yes` (AES-256 `.gpg`), with the passphrase asked
  twice; it is passed through `OMARCHY_BACKUP_PASSPHRASE` (never argv) and
  asked again on restore.

## Crash reporting & AI diagnosis

When a mosquitOmarchy run fails, the TUI stores **one dated log per session**
in `.local/crash-logs/` (repo-local: **never committed, never archived**) and
raises a **critical, clickable Omarchy notification**. Clicking it opens the
default coding agent on the **mosquitomarchy-crash** skill, pointed at that
exact log: the agent diagnoses the failure and **proposes** fixes (a diff or
exact commands) without applying anything, then waits for confirmation.

```bash
mosquitomarchy-crash <logfile> [tool]     # what the notification clicks
scripts/lib/crash.bash                    # mq_crash_guard / mq_crash helpers
scripts/apps/mosquitomarchy/skills/mosquitomarchy-crash/SKILL.md
```

Every **non-install** script sources `scripts/lib/crash.bash` and calls
`mq_crash_guard "<tool>"`, so a failure anywhere routes to the same flow
(install scripts `setup-*.sh` are deliberately exempt). The skill is symlinked
into `~/.agents/skills/mosquitomarchy-crash`, so any AI harness that reads
skills (OpenCode first) discovers it automatically.

## Backend (`mosquitomarchy-actions`)

Read-only queries print JSON-Lines to stdout; actions print prose that the TUI
streams live. It sources `setup-customarchy.sh` with
`MOSQUITOMARCHY_LIB_ONLY=1` and `GUI_RUN_EXEC=1` (so `gui-run.bash` never
re-opens a terminal under the Runner).

```
status | setup | backup-options | backups | update-check | categories | candidates <c> | fixes   # queries
install <cat> <keys…> | apply <group>… | fixes-run <ids…> | update <ids…> | update-repo
uninstall <ids…> | menu-entry | backup [--vst=… --keepass=… --selection=FILE] | restore <file>
```

`apply` takes one argument per folder, TAB-separated: `folder<TAB>key<TAB>key…`.

Root operations run through the native **pkexec** prompt (`mq_sudo`, plus a
`sudo`→`pkexec` shim for the per-module scripts, since the Runner has no tty).

## Build / deploy

`ensure_mosquitomarchy_tui` in `setup-customarchy.sh` builds `tui-go/` with
`go build` into `~/.local/bin/mosquitomarchy-tui`, symlinks
`mosquitomarchy-actions` beside it (a symlink, not a copy, so the backend keeps
finding the repo), copies the `mosquitomarchy` dispatcher, and adds a Hyprland
window rule so the TUI opens floating + centered instead of tiled. It runs from
the `menu` category and from every normal install.

## Files

- `tui-go/` — the Bubble Tea program (model/screens/view, `actions.go` backend glue).
- `mosquitomarchy` — dispatcher (tty → exec the TUI; else `foot -e`, falling back to `xterm`).
- `mosquitomarchy-actions` — the non-interactive backend.
- `mosquitomarchy-agent-crash` — opens the default agent on one crash log (clicked from the notification).
- `skills/mosquitomarchy-crash/SKILL.md` — the diagnosis skill (any AI; symlinked into `~/.agents/skills`).
