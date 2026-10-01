# mosquitomarchy — the launcher TUI

The Go/Bubble Tea interface to the setup launcher. Every decision is made here and every
action shells out to the engine, so no business logic is reimplemented in Go.

```bash
mosquitomarchy          # dispatcher: execs the TUI (foot -e if not on a tty)
mosquitomarchy-tui      # the compiled program, built by the installer
mosquitomarchy-actions  # non-interactive backend
```

`mosquitomarchy-setup.sh` stays the engine and still works by hand; this is the recommended
interface.

## Screens

| Screen | What it does |
|---|---|
| **Status** | Every module with a state dot — ● ok, ◐ partial, ○ missing, · n/a — and an "(uninstalled by you)" tag. Scrollable. |
| **Update** | Whether the scripts repo moved, and which installed modules changed; offers the pull then re-applying the selection. |
| **Setup** | The category tree, then each category's items. |
| **Uninstall** | The same tree, showing only what is actually installed. |
| **Health check** | What drifted from your install: modules that went partially missing, and missing mosquitOmarchy pieces (TUI, float rule, menu entry, shortcut, update hook, crash skill). Offers to re-apply. |
| **Backup / Restore** | A dated archive, plain or encrypted, or restoring one. |
| **Close** | Confirm, then leave. |

The **Keybindings** row and, right after it, **Create a theme from an image** are both main-menu
rows rather than Setup categories: they configure the desktop instead of installing a module, so
burying either under Setup would only add a hop. The theme creator is a four-step flow — folder,
image, name, create — and never applies the theme on its own; see
[scripts/theme/README.md](../../theme/README.md).

## Setup

Two levels. The first lists the categories as plain options plus **Menu entry**, **Add
shortcut for mosquitOmarchy** and **Install selection**; entering a category opens its
**folder tree**. Categories and the items inside them are always **alphabetical** — the counts
come from the backend, so the shape is:

```
Apps  (n)
mosquito  (n)  ■
Quick fixes  (checked/total)  ■
Menu entry
Add shortcut for mosquitOmarchy
Install selection
Back
```

A category with checked items shows **■** and the count. **Install selection** — greyed out
and skipped when nothing is checked — installs everything ticked across all submenus at once,
after a confirmation that lists them.

```
▾ ●  mosquito
    ├─ ●  Move Manager
    └─ ●  mosquito-live-mode
```

| Key | Effect |
|---|---|
| `tab` | toggles the highlighted row; on a **folder** head it selects or deselects every child at once, so one keystroke always lands on an extreme |
| `←` `→` | collapse / expand the folder under the cursor, or change a row that cycles a short list |
| `i` | info popup with the entry's full description — never shown inline |
| `enter` | install the current category's selection, after a confirmation listing it |
| `?` | every shortcut |
| `esc` | back |

`Back` returns one level up, and level 1 then shows the per-category counts. The **mosquito**
title is highlighted in the theme accent.

**Missing installers.** Ableton, Bitwig, Guitar Pro and DaVinci need a file downloaded by
hand. Before running a selection the TUI asks the backend which of them is missing, and shows
a dialog naming the file and its download link **instead of running** — so the failure is never
buried in the run log. The same check aborts, naming the file, when a `setup-*.sh` is run
non-interactively.

**Menu entry** adds or refreshes the launcher in `~/.config/omarchy/extensions/omarchy-menu.jsonc`
(**Omarchy menu → Install → mosquitOmarchy**). It is idempotent.

## Uninstall

The mirror of Setup: same categories, same order, but each folder lists only what is
**installed** and not already marked removed by you. `enter` removes the checked items, or the
highlighted row when nothing is checked, after a confirmation. **Uninstall selection** at level
1 removes everything ticked across all folders at once, and a global run removes the ticked
bindings too. The list refreshes after each removal, so entries disappear as they go.

Three folders exist only here: **Patches** (shown only when an installed app has an applied
patch — removing one runs its `--revert`), **Quick fixes** (run with their `--remove`), and
**Menu & shortcuts** (the menu entry and/or `SUPER + ALT + M`).

## Keybindings

There is no external keybindings script: this TUI owns the `SUPER` bindings of the package
(Setup ▸ keybindings). It edits `~/.config/hypr/bindings.lua` directly, inside one reversible
marked block, so removing the block restores Omarchy's defaults.

Rows are the managed bindings, plus categories to add one — package app, quick function,
Ableton Move, custom command. `enter` binds and proposes a Hyprland reload to validate the
config. Choosing a key that is an Omarchy **default** unbinds it first, with a comment saying
what it replaced. The Uninstall flavor adds a **Reset** row that wipes every binding this
package manages, behind a precise confirmation.

The primitives are `kb-list`, `kb-add`, `kb-remove`, `kb-reset`, `kb-reload` and `kb-free`
subcommands of `mosquitomarchy-actions`, in `scripts/lib/keybindings.bash`.

## Backup encryption

The backup writes dated archives of `~/.config` — hypr, terminal, Omarchy extensions and
plugins, app preferences — to `~/omarchy-backups`, and asks the content questions before
building: a checkbox tree of installed catalog entries (pre-checked from the last backup, saved
as `apps.selected`), VST plugins as *list only* / *full files* / *skip*, KeePassXC passwords
include/skip, and encryption. The passphrase is asked twice, passed through
`OMARCHY_BACKUP_PASSPHRASE` rather than argv, and asked again on restore. See the
[root README](../../../README.md#mosquitomarchy-setupsh) for what the plugin-folder option
does and why it is never automatic.

## Crash reporting

A failed run stores **one dated log per session** in `.local/crash-logs/` (repo-local: never
committed, never archived) and raises a critical, clickable notification. Clicking it opens the
default coding agent on the **mosquitomarchy-crash** skill, pointed at that log; the agent
diagnoses and **proposes** a fix without applying anything.

```bash
mosquitomarchy-crash <logfile> [tool]   # what the notification clicks
```

Every non-install script sources `scripts/lib/crash.bash` and calls `mq_crash_guard "<tool>"`;
`setup-*.sh` installers are exempt because the orchestrator reports their failures itself. The
skill is symlinked into `~/.agents/skills/`, so any agent that reads skills finds it.

## Backend

`mosquitomarchy-actions` prints JSON-Lines for queries and prose for actions, which the TUI
streams live. It sources the orchestrator with `MOSQUITOMARCHY_LIB_ONLY=1` and `GUI_RUN_EXEC=1`
so `gui-run.bash` never re-opens a terminal underneath it.

```
queries   status · setup · health · fixes · categories · candidates <c>
          backup-options · backups · update-check · shortcut
actions   install <cat> <keys…> · apply <group>… · fixes-run <ids…> · update <ids…>
          update-repo · uninstall <ids…> · menu-entry · backup · restore <file>
```

`apply` takes one TAB-separated argument per folder: `folder<TAB>key<TAB>key…`. Root operations
go through the native pkexec prompt (`mq_sudo`), with a `sudo`→`pkexec` shim for the per-module
scripts since the runner has no tty.

## Build and files

`ensure_mosquitomarchy_tui` in `mosquitomarchy-setup.sh` builds `tui-go/` with `go build` into
`~/.local/bin/mosquitomarchy-tui`, symlinks the backend beside it (a symlink, not a copy, so it
keeps finding the repo), copies the dispatcher, and adds a Hyprland rule so the TUI opens
floating and centered. It runs from the menu category and from every normal install.

| File | Role |
|---|---|
| `tui-go/` | the program: `model.go`, the screens, `view.go`, `actions.go` |
| `mosquitomarchy` | dispatcher: a tty execs the TUI, otherwise `foot -e`, falling back to `xterm` |
| `mosquitomarchy-actions` | the non-interactive backend |
| `mosquitomarchy-agent-crash` | opens the agent on one crash log |
| `skills/mosquitomarchy-crash/SKILL.md` | the diagnosis skill |
