#!/usr/bin/env bash
# davinci-resolve-storage.sh — manage DaVinci Resolve's Media Storage locations.
#
# Resolve draws its own file browser (the "Locate", "Deliver" and media pool
# dialogs); it is not the system file dialog and cannot be replaced by Flea,
# Nautilus or Strata. The only folders that browser can see are the Media
# Storage locations listed in config.dat. This helper edits that list safely.
#
# Resolve refuses nested locations: a root that contains another root is
# rejected ("remove the lower level directory"). So $HOME is never added while
# ~/Videos is a root — this helper adds sibling folders and removable drives.
#
# Usage:
#   davinci-resolve-storage list
#   davinci-resolve-storage ensure [--force] [--quiet]
#   davinci-resolve-storage add PATH...
#
# ensure  adds the default candidates (~/Projects, ~/Documents, ~/Downloads,
#         ~/Pictures, ~/Music, "~/DaVinci Resolve Media", ~/kDrive,
#         /run/media/$USER, /media/$USER) once. A state marker records that the
#         defaults were seeded, so a root the user removes in Resolve does not
#         come back on every launch. --force ignores the marker.
# add     adds explicit folders (no marker change).
#
# config.dat is backed up before every change and rewritten atomically.
# Nothing is written while Resolve is running (it would overwrite the change).
set -euo pipefail

CFG="${XDG_DATA_HOME:-$HOME/.local/share}/DaVinciResolve/configs/config.dat"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/mosquitomarchy/davinci-media-storage"

die(){ printf '%s\n' "$*" >&2; exit 1; }

resolve_running(){
  case "${MQ_DAVINCI_STORAGE_FAKE_RUNNING:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  pgrep -f '/opt/resolve/bin/resolve' >/dev/null 2>&1
}

usage(){ sed -n '2,30p' "$0"; }

cmd="${1:-}"; shift || true
[[ -n "$cmd" ]] || { usage; exit 1; }

quiet=0 force=0
paths=()
for a in "$@"; do
  case "$a" in
    --quiet)  quiet=1 ;;
    --force)  force=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "Unknown option: $a" ;;
    *) paths+=("$a") ;;
  esac
done

# Print the roots Resolve currently knows about.
list_roots(){
  [[ -r "$CFG" ]] || return 0
  python3 - "$CFG" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="surrogateescape").read()
for m in re.finditer(r'(?m)^Site\.1\.FS\.(\d+)\.Root\s*=\s*(.*)$', text):
    root = m.group(2).strip()
    if root and root != "ResolveVirtual":
        print(root)
PY
}

case "$cmd" in
  list)
    list_roots
    exit 0
    ;;
  ensure|add)
    ;;
  *)
    die "Unknown command: $cmd (list|ensure|add)"
    ;;
esac

if [[ ! -f "$CFG" ]]; then
  # First launch: Resolve has not written its config yet. The launcher retries.
  (( quiet )) || printf '%s\n' "config.dat not found yet — launch DaVinci Resolve once, then retry."
  exit 0
fi

if resolve_running; then
  (( quiet )) || printf '%s\n' "DaVinci Resolve is running — close it before changing Media Storage locations." >&2
  exit 1
fi

candidates=()
if [[ "$cmd" == add ]]; then
  (( ${#paths[@]} )) || die "add needs at least one path"
  candidates=("${paths[@]}")
else
  # Defaults: siblings of ~/Videos (never $HOME, which would contain Videos and
  # be rejected). /mnt is deliberately excluded.
  (( force )) || [[ ! -e "$STATE" ]] || exit 0
  u="${USER:-$(id -un)}"
  for p in "$HOME/Videos" "$HOME/Projects" "$HOME/Documents" "$HOME/Downloads" \
           "$HOME/Pictures" "$HOME/Music" "$HOME/DaVinci Resolve Media" \
           "$HOME/kDrive" "/run/media/$u" "/media/$u"; do
    [[ -d "$p" ]] && candidates+=("$p")
  done
fi

(( ${#candidates[@]} )) || { (( quiet )) || printf '%s\n' "No default folder found to add."; exit 0; }

strict=0
[[ "$cmd" == add ]] && strict=1

# The Python helper validates nesting and writes atomically. Its stderr is the
# user-facing explanation (same wording as Resolve for the nested case).
if python3 - "$CFG" "$strict" "${candidates[@]}" <<'PY'
import os, re, shutil, sys, tempfile, time

cfg = sys.argv[1]
strict = sys.argv[2] == "1"
wanted = sys.argv[3:]

def norm(p):
    p = os.path.expanduser(p.strip())
    p = os.path.abspath(p)
    if p != "/":
        p = p.rstrip("/")
    return p

text = open(cfg, encoding="utf-8", errors="surrogateescape", newline="").read()

entries = []  # (index, root as written)
for m in re.finditer(r'(?m)^Site\.1\.FS\.(\d+)\.Root\s*=\s*(.*)$', text):
    entries.append((int(m.group(1)), m.group(2).strip()))

real = [norm(r) for _, r in entries if r and r != "ResolveVirtual"]
next_i = max((i for i, _ in entries), default=0) + 1
added = []
hard = False

def conflict(np):
    """Return a message when np cannot coexist with the current roots."""
    for r in real:
        if np == r:
            return "already a Media Storage location"
        if np.startswith(r + os.sep):
            return f"inside an existing Media Storage location ({r}); browse it from there"
        if r.startswith(np + os.sep):
            return (f"contains an existing Media Storage location ({r}); "
                    "remove that lower-level directory first")
    return None

blocks = []
for raw in wanted:
    np = norm(raw)
    if not os.path.isdir(np):
        print(f"skip (not a directory): {raw}", file=sys.stderr)
        continue
    why = conflict(np)
    if why:
        if why.startswith("contains an existing"):
            hard = True
        print(f"skip {np}: {why}", file=sys.stderr)
        continue
    real.append(np)
    added.append(np)
    i = next_i
    next_i += 1
    blocks.append("\n".join([
        f"Site.1.FS.{i}.Type = IOFileSys",
        f"Site.1.FS.{i}.Root = {np}",
        f"Site.1.FS.{i}.MappedRoot = ",
        f"Site.1.FS.{i}.DIO = 0",
        f"Site.1.FS.{i}.BrightClip = 0",
    ]) + "\n")
    print(f"added: {np}")

if not blocks:
    sys.exit(1 if hard and strict else 0)

block = "\n".join(blocks)
pos = text.find("Site.1.CmdRT.Count")
if pos != -1:
    text = text[:pos] + block + "\n" + text[pos:]
else:
    if not text.endswith("\n"):
        text += "\n"
    text += "\n" + block

new_count = next_i - 1
count_re = re.compile(r'(?m)^Site\.1\.FS\.Count\s*=.*$')
if count_re.search(text):
    text = count_re.sub(f"Site.1.FS.Count = {new_count}", text, count=1)
else:
    sys.exit("config.dat has no Site.1.FS.Count line — refusing to guess.")

backup = f"{cfg}.bak.media-storage.{time.time_ns()}"
shutil.copy2(cfg, backup)

d = os.path.dirname(cfg)
fd, tmp = tempfile.mkstemp(prefix=".config.dat.", dir=d)
try:
    with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(text)
    shutil.copymode(cfg, tmp)
    os.replace(tmp, cfg)
except Exception:
    os.unlink(tmp)
    raise

sys.exit(1 if hard and strict else 0)
PY
then
  if [[ "$cmd" == ensure ]]; then
    mkdir -p "$(dirname "$STATE")"
    : > "$STATE"
    (( quiet )) || printf '%s\n' "Media Storage locations seeded (Resolve must be closed)."
  fi
else
  rc=$?
  (( rc == 1 )) && exit 1
  die "Could not update $CFG"
fi
