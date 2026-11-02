#!/usr/bin/env bash
# The AUR install path must provide setuptools before yay builds a Python
# package: python-plotext (a bagels dependency) declares no makedepends, so
# the update died with "ModuleNotFoundError: No module named 'setuptools'".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
export GUI_RUN_EXEC=1
# shellcheck source=../modules/TUIs/lib-tui.sh
source "$ROOT/code/modules/TUIs/lib-tui.sh"

# Setuptools missing: it is installed once, through the shared elevation helper.
installs=0
mq_sudo(){ installs=$((installs + 1)); }
python(){ return 1; }
aur_build_deps
[[ $installs == 1 ]]

# Setuptools present: nothing is installed.
installs=0
python(){ return 0; }
aur_build_deps
[[ $installs == 0 ]]

# The helper has to run BEFORE yay, or the build fails before it can matter.
grep -q 'aur_build_deps || return 1' "$ROOT/code/modules/TUIs/lib-tui.sh"
awk '/aur_build_deps \|\| return 1/{dep=NR} /yay -S --needed/{if (dep && NR > dep) ok=1} END{exit !ok}' \
  "$ROOT/code/modules/TUIs/lib-tui.sh"

echo 'ok: AUR builds install python-setuptools first'
