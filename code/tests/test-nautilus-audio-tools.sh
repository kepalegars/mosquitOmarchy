#!/usr/bin/env bash
# The nautilus-audio tweak must install both Nautilus scripts + makesfz, skip
# the package install on a re-run, refuse to overwrite a user's own file, and
# remove only what it owns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/code/modules/Tweaks/tweak-nautilus-audio.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin"

# Stub yay: records the call and creates the package binaries it claims to
# install, so the "already installed" fast path can be exercised too.
cat > "$TMP/bin/yay" <<'EOF'
#!/usr/bin/env bash
echo "yay $*" >> "$YAY_LOG"
for t in pacpl oggenc opusenc sox flac lame wavpack ffmpeg; do
  printf '#!/bin/sh\nexit 0\n' > "$TOOL_BIN/$t"
  chmod +x "$TOOL_BIN/$t"
done
# pacpl's undeclared startup modules, which a real install would provide.
mkdir -p "$TOOL_BIN/perl5/File" "$TOOL_BIN/perl5/Ogg/Vorbis" "$TOOL_BIN/perl5/String"
printf '1;\n' > "$TOOL_BIN/perl5/File/Util.pm"
printf '1;\n' > "$TOOL_BIN/perl5/Ogg/Vorbis/Header.pm"
printf '1;\n' > "$TOOL_BIN/perl5/String/ShellQuote.pm"
EOF
# Stub curl: the last argument is the -o target; write a fake makesfz there.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="${*: -1}"
printf '#!/bin/bash\n# makesfz fixture\n' > "$out"
EOF
# Stub go: "go build -o OUT ." -> create a fixture binary at OUT (no compile).
cat > "$TMP/bin/go" <<'EOF'
#!/usr/bin/env bash
out=""
while (($#)); do
  case $1 in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n $out ]] || exit 1
printf '#!/bin/sh\nexit 0\n' > "$out"
chmod +x "$out"
EOF
chmod +x "$TMP/bin/yay" "$TMP/bin/curl" "$TMP/bin/go"
export PATH="$TMP/bin:$PATH"
# The yay stub drops pacpl's Perl modules here; the tweak checks them with perl.
export PERL5LIB="$TMP/bin/perl5"
export YAY_LOG="$TMP/yay.log" TOOL_BIN="$TMP/bin" GUI_RUN_EXEC=1

SCRIPTS="$HOME/.local/share/nautilus/scripts"
PACPL="$SCRIPTS/Convert Audio (PACPL)"
SFZ="$SCRIPTS/Make SFZ"
MAKESFZ="$HOME/.local/bin/makesfz"
CONVERT="$HOME/.local/bin/mosquitomarchy-audio-convert"

fail(){ echo "FAIL: $*" >&2; exit 1; }

# ── apply ─────────────────────────────────────────────────────────────────────
bash "$SCRIPT" >"$TMP/apply.log" 2>&1 || fail "apply exited non-zero"
[[ -x $PACPL ]] || fail "Convert Audio (PACPL) missing or not executable"
[[ -x $SFZ ]] || fail "Make SFZ missing or not executable"
[[ -x $MAKESFZ ]] || fail "makesfz not installed"
[[ -x $CONVERT ]] || fail "converter TUI not built"
grep -qF 'tweak-nautilus-audio' "$PACPL" || fail "PACPL script lacks the managed marker"
grep -qF 'tweak-nautilus-audio' "$SFZ" || fail "SFZ script lacks the managed marker"
grep -qF 'mosquitomarchy-audio-convert' "$PACPL" || fail "PACPL script does not call the converter TUI"
! grep -qF 'zenity' "$PACPL" || fail "PACPL script still uses zenity"
bash -n "$PACPL" || fail "Convert Audio (PACPL) is not valid bash"
bash -n "$SFZ" || fail "Make SFZ is not valid bash"
# yay is only called when a tool is missing; on a machine that already has the
# packages the "already installed" fast path is what runs.
if ! command -v pacpl >/dev/null 2>&1; then
  grep -q 'yay -S' "$YAY_LOG" || fail "yay was not called on the first apply"
fi

# ── idempotent: same bytes, no extra files, no second package install ────────
cp "$PACPL" "$TMP/pacpl.before"
bash "$SCRIPT" >"$TMP/apply2.log" 2>&1 || fail "second apply exited non-zero"
cmp -s "$PACPL" "$TMP/pacpl.before" || fail "second apply changed the script"
[[ $(find "$SCRIPTS" -type f | wc -l) -eq 2 ]] || fail "unexpected files in the scripts dir"
if [[ -s $YAY_LOG ]]; then
  [[ $(wc -l < "$YAY_LOG") -eq 1 ]] || fail "second apply reinstalled the packages"
fi

# ── status reports the installed pieces ──────────────────────────────────────
bash "$SCRIPT" --status >"$TMP/status.log" 2>&1 || fail "status exited non-zero"
grep -q 'Nautilus script: Convert Audio (PACPL)' "$TMP/status.log" || fail "status misses PACPL"
grep -q 'Nautilus script: Make SFZ' "$TMP/status.log" || fail "status misses Make SFZ"

# ── a same-named file we do not own is refused, not overwritten ──────────────
printf '#!/bin/bash\n# mine\n' > "$SFZ"
cp "$SFZ" "$TMP/foreign.before"
if bash "$SCRIPT" >"$TMP/foreign.log" 2>&1; then
  fail "apply overwrote a foreign Make SFZ"
fi
grep -q 'refusing to overwrite' "$TMP/foreign.log" || fail "missing refusal message"
cmp -s "$SFZ" "$TMP/foreign.before" || fail "foreign Make SFZ was modified"

# ── remove drops ours, then a fresh apply restores them ──────────────────────
rm -f "$SFZ"
bash "$SCRIPT" >/dev/null 2>&1 || fail "apply after cleanup failed"
bash "$SCRIPT" --remove >"$TMP/remove.log" 2>&1 || fail "remove exited non-zero"
[[ ! -e $PACPL && ! -e $SFZ && ! -e $MAKESFZ && ! -e $CONVERT ]] || fail "remove left managed files behind"

echo 'ok: nautilus-audio tweak installs, is idempotent, refuses foreign files and removes its own'
