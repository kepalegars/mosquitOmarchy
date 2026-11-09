# `Plugins` — the desktop shell layer

Most modules have one folder here with their own installer, and each module id
in `mosquitomarchy-setup.sh` routes to its folder. A few are plain Omarchy shell
plugins installed straight from their upstream repository by
`mosquitomarchy-setup.sh` (`taskq`, `process-killer`): they have no folder.

```bash
code/modules/Plugins/battery-management/setup-battery-management.sh
code/modules/Plugins/omarchy-downloads/setup-omarchy-downloads.sh
code/modules/Plugins/reboot-into-windows/setup-reboot-into-windows.sh
```

Most installers also accept `--status` (read-only) and `--remove`/`--uninstall`.
They are idempotent: re-running is safe.

## Better PiP

**Better PiP** (`mosquito.better-pip`) is a normal module again: Setup row,
backup selection and update zone all include it. It is a fork of
`ricardo-ti.pip-solver`; installing it retires the upstream plugin.

```bash
bash code/modules/Plugins/better-pip/setup-better-pip.sh
bash code/modules/Plugins/better-pip/setup-better-pip.sh --remove
```

## Removed

**Pocket** (`jrmmhm.pocket`) was removed from the project. A machine that still
has the plugin can remove it with:

```bash
omarchy plugin remove jrmmhm.pocket --yes
```
