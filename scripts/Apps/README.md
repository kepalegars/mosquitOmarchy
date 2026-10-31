# `Apps` — the desktop applications

One folder per application, each with its own installer. There is no catalog and
no shared dispatcher: the folder listing **is** the list the Setup > Apps tree
shows, and each module id in `mosquitomarchy-setup.sh` routes to its folder.

```bash
scripts/Apps/reaper/setup-reaper.sh
scripts/Apps/bitwig/setup-bitwig.sh -y
scripts/Apps/flea/setup-flea.sh --uninstall
```

Most installers also accept `--status` (read-only) and `--uninstall`/`--remove`.
They are idempotent: re-running is safe.

## Large installers

Nothing here is downloaded: Ableton and Bitwig are behind account logins, and a
multi-GB zip does not belong in a git clone. Drop every installer you want into
`~/Downloads`, then run `./bootstrap.sh` — it moves each recognised file into
its module folder (never overwriting an existing file) and reports which Setup
rows stay greyed out. You can also drop a file straight into its module folder
(`scripts/Apps/ableton/`, `scripts/Apps/guitarpro/`, `scripts/Apps/bitwig/`,
`scripts/Apps/davinci/`).

A missing installer is not a failure. The module that needs it stays visible in
Setup, greyed out, and Enter on the row names the exact file and folder instead
of starting an install that cannot finish.

DaVinci Resolve **is** inventoried, by presence only: its zip is about 11 GB, so
recording a checksum would mean hashing it on every `--check`.

## TUIs and VMs

- Terminal tools live in [`../TUIs/`](../TUIs/).
- Virtual machines live in [`../VMs/`](../VMs/).
- Desktop plugins, fixes, tweaks, themes and mosquito tools keep their own
  top-level folders, matching the Setup tree.
