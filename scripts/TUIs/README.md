# `TUIs` — terminal tools

One `setup-<name>.sh` per terminal tool. There is no catalog: the files in this
folder are the list the Setup > TUIs tree shows.

Each entry declares its package and row text in two header lines, which the
backend reads:

```bash
#!/usr/bin/env bash
# desc: bagels — terminal expense tracker
# pkg: bagels
```

`setup-<name>.sh` installs the package and runs its optional
`setup-<name>-menu.sh` companion (launcher, icon, Omarchy menu entry). It also
accepts `--uninstall` and `--status`. `lib-tui.sh` is the shared implementation.

```bash
scripts/TUIs/setup-bagels.sh
scripts/TUIs/setup-caligula.sh --uninstall
scripts/TUIs/setup-septabee.sh --status
```
