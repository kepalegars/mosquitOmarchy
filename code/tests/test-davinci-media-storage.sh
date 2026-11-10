#!/usr/bin/env bash
# davinci-resolve-storage must add sibling folders without touching the first
# Media Storage root, stay idempotent, respect its "already seeded" marker,
# handle spaces, and refuse nested locations with Resolve's own rule.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/code/modules/Apps/davinci/davinci-resolve-storage.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/data"
export XDG_STATE_HOME="$TMP/state"
export MQ_DAVINCI_STORAGE_FAKE_RUNNING=0
CFG="$XDG_DATA_HOME/DaVinciResolve/configs/config.dat"
MARKER="$XDG_STATE_HOME/mosquitomarchy/davinci-media-storage"

mkdir -p "$HOME/Videos" "$HOME/Projects" "$HOME/Documents"
mkdir -p "$(dirname "$CFG")"

fail(){ echo "FAIL: $*" >&2; exit 1; }
roots(){ grep -cE '^Site\.1\.FS\.[0-9]+\.Root = ' "$CFG" || true; }
has_line(){ grep -qxF -- "$1" "$CFG"; }
has_root(){ grep -qF -- "Root = $1" "$CFG"; }

# Number of defaults this machine will really add (Projects + Documents +
# the removable-drive roots, which exist on a normal desktop but not in CI).
defaults=2
[[ -d /run/media/$USER ]] && defaults=$((defaults + 1))
[[ -d /media/$USER ]] && defaults=$((defaults + 1))
expected=$((2 + defaults))

base_config(){
  cat > "$CFG" <<EOF
Site.Count = 1

Site.1.FS.Count = 2

Site.1.FS.1.Type = IOFileSys
Site.1.FS.1.Root = $HOME/Videos
Site.1.FS.1.MappedRoot = 
Site.1.FS.1.DIO = 0
Site.1.FS.1.BrightClip = 0

Site.1.FS.2.Type = IOFileSys
Site.1.FS.2.Root = ResolveVirtual
Site.1.FS.2.MappedRoot = 
Site.1.FS.2.DIO = 0
Site.1.FS.2.BrightClip = 0

Site.1.CmdRT.Count = 1
EOF
}

# ── ensure: adds the siblings that exist, keeps Videos first ────────────────
base_config
bash "$HELPER" ensure --quiet || fail "ensure exited non-zero"
[[ $(roots) == "$expected" ]] || fail "expected $expected roots, got $(roots)"
has_line "Site.1.FS.1.Root = $HOME/Videos" || fail "the first root was modified"
has_root "$HOME/Projects" || fail "Projects not added"
has_root "$HOME/Documents" || fail "Documents not added"
grep -q "^Site\.1\.FS\.Count = $expected$" "$CFG" || fail "FS.Count not updated to $expected"
compgen -G "$CFG.bak.media-storage.*" >/dev/null || fail "no backup created"
[[ -f $MARKER ]] || fail "seed marker not written"
[[ $(bash "$HELPER" list | wc -l) == $((expected - 1)) ]] || fail "list should hide ResolveVirtual"

# ── idempotent + marker: a second ensure changes nothing ───────────────────
cp -p "$CFG" "$TMP/before-second"
bash "$HELPER" ensure --quiet || fail "second ensure exited non-zero"
cmp -s "$CFG" "$TMP/before-second" || fail "second ensure modified the config"

# A root removed in Resolve must not come back while the marker exists.
sed -i "\|Root = $HOME/Projects$|d" "$CFG"
bash "$HELPER" ensure --quiet || fail "ensure after removal exited non-zero"
! has_root "$HOME/Projects" || fail "marker was ignored: Projects came back"

# --force re-seeds even with the marker.
mkdir -p "$HOME/kDrive"
bash "$HELPER" ensure --force --quiet || fail "ensure --force exited non-zero"
has_root "$HOME/kDrive" || fail "--force did not add kDrive"

# ── add: spaces, duplicate, and nested rules ───────────────────────────────
mkdir -p "$TMP/Media Folder"
bash "$HELPER" add "$TMP/Media Folder" >"$TMP/add.log" 2>&1 || fail "add with spaces failed"
has_root "$TMP/Media Folder" || fail "path with spaces not written verbatim"
grep -q '^added:' "$TMP/add.log" || fail "add did not report the added path"

n=$(roots)
bash "$HELPER" add "$TMP/Media Folder" >"$TMP/dup.log" 2>&1 || fail "duplicate add should be a no-op"
[[ $(roots) == "$n" ]] || fail "duplicate add created another entry"
grep -q 'already a Media Storage location' "$TMP/dup.log" || fail "duplicate message missing"

cp -p "$CFG" "$TMP/before-nested"
if bash "$HELPER" add "$HOME" >"$TMP/nested.log" 2>&1; then
  fail "add $HOME was accepted while $HOME/Videos is a root"
fi
cmp -s "$CFG" "$TMP/before-nested" || fail "refused nested add modified the config"
grep -q 'remove that lower-level directory first' "$TMP/nested.log" || fail "nested message missing"

mkdir -p "$HOME/Videos/sub"
bash "$HELPER" add "$HOME/Videos/sub" >"$TMP/inside.log" 2>&1 || fail "inside-root add should be skipped, not failed"
grep -q 'inside an existing Media Storage location' "$TMP/inside.log" || fail "inside-root message missing"

# ── Resolve running: refuse to touch the config ────────────────────────────
if MQ_DAVINCI_STORAGE_FAKE_RUNNING=1 bash "$HELPER" add "$TMP/Media Folder" >"$TMP/running.log" 2>&1; then
  fail "add was accepted while Resolve is running"
fi
grep -q 'close it before changing' "$TMP/running.log" || fail "running message missing"

# ── no config yet: not an error (the launcher retries) ─────────────────────
rm -f "$CFG"
bash "$HELPER" ensure --quiet || fail "ensure without config.dat should exit 0"
[[ ! -e $CFG ]] || fail "ensure created a config.dat"

echo "ok: davinci-resolve-storage"
