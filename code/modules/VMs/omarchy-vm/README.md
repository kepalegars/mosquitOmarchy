# Omarchy VM

Run Omarchy in QEMU/KVM.

## Create a VM (host)

```bash
mosquitomarchy-setup.sh omarchy-vm                  # install the manager
code/modules/VMs/omarchy-vm/setup-omarchy-vm.sh     # create the default VM
omarchy-vm-tui                                      # create or manage VMs
```

The module install only deploys the manager. The setup script downloads and
verifies the latest Omarchy ISO, then creates a sparse 64 GB disk and launcher.
Defaults: half the host RAM (rounded down to GB, min. 4/max. 32 GB), half the
physical CPU cores (min. 2/max. 8), and VirGL 3D enabled. Adjust resources or
toggle VirGL in `omarchy-vm-tui`.

The host shared folder is `~/VMs/<name>/shared folder`; the script exports it to the
guest as `/mnt/host`.

Deleting a stopped VM moves its complete shared folder to
`~/VMs/shared folder backup`. If that backup already exists, files are merged;
same-name files from earlier backups are retained with numbered suffixes.

## First launch: setup inside the VM

Boot the VM from the host. In a terminal **inside the guest**, run once:

```bash
mkdir -p ~/VMs
curl -sf --retry 3 http://10.0.2.2:7789/share -o ~/VMs/omarchy-vm-share
sudo bash ~/VMs/omarchy-vm-share --install
```

This mounts the shared folder, installs the mount and clipboard services for
future boots, then opens the folder in the guest's default file manager. The
guest path is `/mnt/host`; on the host, it is `~/VMs/<name>/shared folder`. The setup
prints the path and reminds you to add it to your bookmarks. The downloaded
helper is copied to `/usr/local/bin`, so you can delete `~/VMs/omarchy-vm-share`
afterwards. Check with `omarchy-vm-share --status`.

On first boot, install Omarchy from the ISO; later boots use the installed disk.
Start or manage VMs with `omarchy-vm [name]` or `omarchy-vm-tui`. Shut down
from inside the guest rather than force-stopping it.

## Remove

```bash
code/modules/VMs/omarchy-vm/setup-omarchy-vm.sh --remove        # keep VMs
code/modules/VMs/omarchy-vm/setup-omarchy-vm.sh --remove --purge # delete VMs too
```
