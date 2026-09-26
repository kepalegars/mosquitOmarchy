#!/usr/bin/env bash
# fix-daw-wine-runtime.sh — REAPER + Bitwig use the ableton wine runtime.
#
# ableton-linux's wine fork (wine-d2d1-nspa) implements Windows
# DirectComposition properly. Stock wine-staging 11.17 crashes VST3 editors
# whose GUI uses DComp (Serum 2 verified: unhandled exception c0000409 inside
# dcomp during editor init → libyabridge throws → REAPER SIGABRT, coredumps
# 2026-09-25 11:03/11:46/2026-09-26 19:42). The same plugins load perfectly
# inside Ableton — which uses THIS runtime.
#
# The fix: two thin wrappers in ~/.local/bin (PATH precedes /usr/bin there)
# that prepend the runtime's bin to PATH, so yabridge's host runs through
# the patched wine for windows plugins. Idempotent; reversible (--remove).
#
# Usage:
#   fix-daw-wine-runtime.sh        # install both wrappers (idempotent)
#   fix-daw-wine-runtime.sh        # status
#   fix-daw-wine-runtime.sh --remove   # delete the wrappers (stock wine)
set -euo pipefail

BIN="$HOME/.local/bin"
AWINE="$HOME/.local/opt/wine-d2d1-nspa-11.13/bin"

ok()  { echo -e "\033[32m ●\033[0m $*"; }
info(){ echo -e "\033[34m==>\033[0m $*"; }
warn(){ echo -e "\033[1;33m !\033[0m $*"; }

wrapper_body() { # $1 = upstream binary path
cat <<WRAP
#!/usr/bin/env bash
# REAPER/Bitwig through the ableton-linux wine (wine-d2d1-nspa-11.13) — its
# DirectComposition implementation fixes wine VST3 editor crashes
# (STATUS_STACK_BUFFER_OVERRUN / c0000409 inside dcomp, e.g. Serum 2).
AWINEBIN="\$HOME/.local/opt/wine-d2d1-nspa-11.13/bin"
if [[ -x "\$AWINEBIN/wine" ]]; then
  export PATH="\$AWINEBIN:\$PATH"
fi
exec $1 "\$@"
WRAP
}

case "${1:-apply}" in
  --remove|--remove)
    rm -f "$BIN/reaper" "$BIN/bitwig-studio"
    ok "wrappers removed — REAPER/Bitwig use the stock wine again"
    ;;
  status)
    echo "ableton wine:   $([[ -x $AWINE/wine ]] && echo present || echo ABSENT)"
    echo "reaper wrapper: $([[ -f $BIN/reaper ]] && echo installed || echo absent)"
    echo "bitwig wrapper: $([[ -f $BIN/bitwig-studio ]] && echo installed || echo absent)"
    ;;
  apply)
    [[ -x $AWINE/wine ]] || { warn "ableton wine runtime missing at $AWINE — nothing to point at"; exit 1; }
    mkdir -p "$BIN"
    wrapper_body /usr/lib/REAPER/reaper > "$BIN/reaper"
    chmod +x "$BIN/reaper"
    wrapper_body /usr/bin/bitwig-studio > "$BIN/bitwig-studio"
    chmod +x "$BIN/bitwig-studio"
    ok "REAPER + Bitwig now launch through the ableton wine runtime (dcomp fix)"
    ;;
  -h|--help) sed -n '2,24p' "$0" ;;
  *) usage="$0 <apply|--status|--remove>"; echo "$usage"; exit 1 ;;
esac
