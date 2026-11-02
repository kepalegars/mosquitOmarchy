#!/usr/bin/env bash
# Regression tests for the uninstall paths that failed on a restored machine:
# a non-executable module script, a VM remover that died on missing OVMF, and
# a caller that ran a helper directly instead of through bash.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# A module script is RUN WITH bash everywhere; testing -x made every 0644 script
# look absent ("setup-zen.sh not found").
if grep -qE '\[\[ -x "[^"]*_DIR/setup-[^"]*\.sh" \]\]' mosquitomarchy-setup.sh; then
  echo 'fail: an uninstall guard still tests -x on a setup script' >&2
  exit 1
fi

# Called directly by the KeePassXC module and documented for users.
[[ -x code/modules/Apps/keepassxc/keepassxc-default-database.sh ]]
[[ -x code/modules/Apps/zen/setup-zen.sh ]]
grep -q 'bash "$(dirname "${BASH_SOURCE\[0\]}")/keepassxc-default-database.sh" --clear' \
  code/modules/Apps/keepassxc/setup-keepassxc-integration.sh

# `--remove` must not need Omarchy or edk2-ovmf: detect_ovmf used to return the
# false status of its last `[[ -f ]]` test, which aborted the script under
# `set -e` before it removed anything.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.config/omarchy/extensions" "$tmp/home/.config/hypr" \
  "$tmp/home/.local/bin" "$tmp/home/.local/share/applications"
out="$(HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" \
  GUI_RUN_EXEC=1 MOSQUITOMARCHY_NO_GUI=1 \
  bash code/modules/VMs/omarchy-vm/setup-omarchy-vm.sh --remove 2>&1)" || {
  printf '%s\n' "$out" >&2
  echo 'fail: Omarchy VM --remove exited non-zero' >&2
  exit 1
}
grep -q 'setup-omarchy-vm: removed' <<<"$out"

echo 'ok: uninstall paths are executable and do not need VM dependencies'
