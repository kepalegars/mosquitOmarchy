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
| **Backup / Restore** | Create a dated archive (plain `.tar.gz` or encrypted AES-256 `.gpg`), or restore one. |
| **Close** | Asks for confirmation, then leaves. |

## Setup

Setup is two levels. The first screen lists the **categories** as plain
options, plus **Menu entry** and **Install selection**; entering a category
opens its **folder tree** — the same folder lists the Audio Plugin Manager
uses:

```
Apps  (9)
mosquito  (5)  ■
Quick fixes  (2/6)  ■
Menu entry
Install selection
Back
```

A category that has checked items shows a **■** and the **selected count**
(`(2/6)`), and **Install selection** (greyed out and skipped when nothing is
checked) installs every selection from all submenus at once, after a
confirmation that lists them. `Menu entry` registers the launcher in the
Omarchy menu.

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

**Menu entry** (a first-level Setup option) adds/refreshes the mosquitOmarchy
entry in **Omarchy menu → Install → mosquitOmarchy**
(`~/.config/omarchy/extensions/omarchy-menu.jsonc`); it is idempotent.

Option rows that cycle a short list (VST mode, KeePass include/skip, encrypt
yes/no) are changed with **←/→**.

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
