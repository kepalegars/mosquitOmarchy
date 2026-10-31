# Reboot into Windows

Adds **System → Reboot into Windows** to the Omarchy menu.

Clicking the entry opens a floating terminal that:

1. finds the firmware's **Windows Boot Manager** entry (`efibootmgr`),
2. shows a **15 s countdown** with a yes/no confirmation (timeout and `n`
   cancel; nothing is written),
3. arms **BootNext** for the next boot only, verifies it stuck and that the
   boot order is unchanged,
4. reboots through Omarchy's own reboot path.

The saved boot order, active flags and firmware timeout are never changed. The
firmware consumes BootNext on the next boot, so the boot after that follows
the normal order again.

## Install

```bash
./setup-reboot-into-windows.sh
```

Or from `mosquitOmarchy`: **Setup → Plugins → reboot-into-windows**.

## Usage

The menu entry is the normal path. From a shell:

```bash
reboot-into-windows            # countdown + confirmation
reboot-into-windows --list     # show the Windows entry
reboot-into-windows --dry-run  # print the commands, touch nothing
reboot-into-windows --clear-next
```

`REBOOT_INTO_WINDOWS_COUNTDOWN` changes the 15 s (tests only).

## Remove

```bash
./setup-reboot-into-windows.sh --remove
```

## Requirements

- UEFI firmware with `efibootmgr` installed.
- A Windows Boot Manager entry (Windows installed on the machine).
- `sudo` (passwordless/cached) or `pkexec` for the single `efibootmgr` write.

The reboot itself runs as the logged-in user through
`omarchy-system-reboot`, so the session closes its windows normally.
