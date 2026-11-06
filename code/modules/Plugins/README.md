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

## Set aside

Two former Setup rows are no longer modules:

- **Better PiP** (`mosquito.better-pip`) is kept as a standalone installer in
  [`better-pip/setup-better-pip.sh`](better-pip/setup-better-pip.sh). It is not
  offered in Setup, not in the backup selection and not updated by the module
  update zone. Install or remove it by hand:

  ```bash
  bash code/modules/Plugins/better-pip/setup-better-pip.sh
  bash code/modules/Plugins/better-pip/setup-better-pip.sh --remove
  ```

  It is a fork of `ricardo-ti.pip-solver`; installing it retires the upstream
  plugin.

- **Pocket** (`jrmmhm.pocket`) was removed from the project. A machine that
  still has the plugin can remove it with:

  ```bash
  omarchy plugin remove jrmmhm.pocket --yes
  ```
