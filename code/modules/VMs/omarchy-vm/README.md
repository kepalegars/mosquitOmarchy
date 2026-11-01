# Omarchy VM

Run Omarchy in QEMU/KVM. Install the module on the host, then create a VM from
**Omarchy menu → Setup → Omarchy VM** (or run `omarchy-vm-tui`). New VMs use
VirGL 3D acceleration by default; toggle it in the manager if needed.

## Setup inside the VM (once)

After the VM boots, open a terminal **inside the guest** and run:

```bash
mkdir -p ~/VMs
curl -sf --retry 3 http://10.0.2.2:7789/share -o ~/VMs/omarchy-vm-share
sudo bash ~/VMs/omarchy-vm-share --install
```

This creates `~/VMs`, downloads the helper there, mounts the host folder at
`/mnt/host`, and installs the mount and clipboard services for future boots.
The helper is copied to `/usr/local/bin`; delete `~/VMs/omarchy-vm-share`
after setup. Verify with `omarchy-vm-share --status`.

Each VM has its own host folder: `~/VMs/<name>/shared`. The clipboard bridge
works while the VM is running.

## Host commands

```bash
mosquitomarchy-setup.sh omarchy-vm  # install/update the manager
omarchy-vm-tui                      # create, start, stop or configure VMs
omarchy-vm [name]                   # start the default or named VM
```

The module install does not create a VM. On first boot, install Omarchy from
the ISO; the VM boots from its disk automatically after installation.
Shut down from inside the guest rather than force-stopping it.

VM disks, config and shared folders live under `~/VMs/<name>`; the ISO cache is
`~/.cache/omarchy-vm/`. Use `MOSQUITO_VM_ROOT` to change the VM root.

## Remove

```bash
code/modules/VMs/omarchy-vm/setup-omarchy-vm.sh --remove        # keep VMs
code/modules/VMs/omarchy-vm/setup-omarchy-vm.sh --remove --purge # delete VMs too
```
