#!/usr/bin/env bash
# The boot update watchdog must not check/download Ableton releases or notify
# about Ableton updates; the manual Ableton updater remains separate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GUI_RUN_EXEC=1
legacy="$HOME/.config/omarchy/hooks/post-boot.d/zzz-mosquitomarchy-update-check"
mkdir -p "$(dirname "$legacy")"
printf '#!/usr/bin/env bash\nnotify-send "Ableton Live update available"\n' > "$legacy"
chmod +x "$legacy"

bash "$ROOT/code/main tui/update/setup-mosquitomarchy-update.sh" -y >/dev/null
hook="$legacy"
[[ -x $hook ]]
! grep -qiE 'ableton-linux|ableton-update|Ableton Live update available|setup-ableton\.sh' "$hook"
grep -q 'ls-remote' "$hook"
grep -q 'pacman -Qu' "$hook"

echo 'ok: generated boot update hook no longer checks or notifies about Ableton'
