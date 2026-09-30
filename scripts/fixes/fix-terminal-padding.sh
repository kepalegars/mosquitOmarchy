#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom - terminal padding: kill the thick frame around the text
# =============================================================================
# Omarchy's four terminal configs all ship a 14px inner padding, painted with
# the theme background (Omarchy's dark themes are near-black, #0d0d0b), so the
# text floats in the middle of what reads as a heavy black border. That padding
# is what draws the margin, not the window decoration, which is why the frame
# survives any terminal switch: this fix edits the padding value itself.
#
# What this script does (idempotent):
#   1. Rewrites the padding key of every terminal that HAS a user config under
#      ~/.config (foot `pad`, kitty `window_padding_width`, ghostty
#      `window-padding-x`/`-y`, alacritty `padding.x`/`-y`) to the requested
#      value, 0 by default.
#   2. Remembers the previous value inline, in a trailing marker, so `--remove`
#      restores that exact original instead of guessing. Re-applying with another
#      value (apply, then `--set 6`, then remove) still restores the original.
#   3. Triggers `omarchy restart terminal` — reload signals only, no window is
#      killed — and says which terminals need a NEW window to pick it up.
#
# Only ~/.config is ever written: never /usr/share/omarchy (overwritten by
# `omarchy update`) and never /etc/xdg (system-wide, would need sudo). A config
# file that does not exist is reported and skipped: the fix never invents one,
# because a partial config silently drops settings the terminal needs (foot would
# lose its theme include, kitty its `listen_on` socket). A terminal whose
# config has no padding key is reported, not written to.
#
# The fix owns the whole padding line: a comment already sitting on that one line
# is replaced by the marker (commented-out examples like `# window_padding_width
# 14` are a different line and are never touched). `--remove` puts the original
# value back, marker and all gone.
#
# Re-running after an `omarchy update` or `omarchy refresh config <terminal>`
# re-applies the fix: those overwrite the file, the marker goes with it.
#
# Usage:
#   ./fix-terminal-padding.sh              # apply, padding = 0
#   ./fix-terminal-padding.sh --set 6      # apply, padding = 6px
#   ./fix-terminal-padding.sh --status     # one line per terminal, no changes
#   ./fix-terminal-padding.sh --remove     # restore every remembered value
#   ./fix-terminal-padding.sh -y           # non-interactive (accepted, no prompt)
# =============================================================================
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
MARK="mosquitomarchy-terminal-padding"

info() { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m !\033[0m $*"; }
err()  { echo -e "\033[1;31m ✗\033[0m $*" >&2; }

# One spec per patched key: "<terminal>|<config file>|<key regexp>|<unit>".
# The regexp matches the key AND its separator (`pad=` vs `window_padding_width `
# vs `window-padding-x = `), so the line is rebuilt with the style it already had.
# `unit` is how the value is spelled for that key: ghostty/kitty/alacritty take a
# bare number, foot REJECTS a bare `pad=0` ("invalid padding, must be in the form
# RIGHTxTOPxLEFTxBOTTOM or XxY") so it needs the explicit NxN form.
SPECS=(
  "foot|$CONFIG_DIR/foot/foot.ini|^[[:space:]]*pad[[:space:]]*=[[:space:]]*|nx"
  "kitty|$CONFIG_DIR/kitty/kitty.conf|^[[:space:]]*window_padding_width[[:space:]]+|n"
  "ghostty|$CONFIG_DIR/ghostty/config|^[[:space:]]*window-padding-x[[:space:]]*=[[:space:]]*|n"
  "ghostty|$CONFIG_DIR/ghostty/config|^[[:space:]]*window-padding-y[[:space:]]*=[[:space:]]*|n"
  "alacritty|$CONFIG_DIR/alacritty/alacritty.toml|^[[:space:]]*padding[.]x[[:space:]]*=[[:space:]]*|n"
  "alacritty|$CONFIG_DIR/alacritty/alacritty.toml|^[[:space:]]*padding[.]y[[:space:]]*=[[:space:]]*|n"
)

fmt_value(){ # <unit> <n> -> the literal value for that key
  case $1 in
    nx) echo "${2}x${2}" ;;
    *)  echo "${2}" ;;
  esac
}

# ── the one awk that does all the line work ───────────────────────────────────
# Emits the rewritten file on stdout. `mode` is "apply" or "remove".
awk_program(){ cat <<'AWK'
function trim(s){ sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# Value the marker remembers: "was 14x14" -> "14x14".
function remembered(rest,   s){ s = rest; sub(".*" mark " \\(was ", "", s); sub("\\).*$", "", s); return trim(s) }
!match($0, re) { print; next }
{
  prefix = substr($0, 1, RLENGTH)          # the key + its separator, verbatim
  rest   = substr($0, RLENGTH + 1)         # the value, then any comment
  marked = (index(rest, mark) != 0)

  if (mode == "remove") {
    if (!marked) { print; next }           # never ours: hands off
    if (remembered(rest) == "") { next }   # "(added)": the key was not there
    print prefix remembered(rest)
    next
  }

  # apply: keep the FIRST value we ever saw, so a later --set cannot become
  # the thing --remove restores.
  was = marked ? remembered(rest) : ""
  if (was == "") {                         # unmarked, or marked "(added)"
    v = rest
    if (match(v, /#/)) v = substr(v, 1, RSTART - 1)   # a comment is never the value
    was = trim(v)
  }
  print prefix newval "  # " mark (was == "" ? " (added)" : " (was " was ")")
}
AWK
}

# Rewrite the key line in place. 0 = written, 1 = awk failed, 3 = no such line.
_patch_key(){ # <file> <key-regex> <new-value> <mode>
  local file="$1" re="$2" newval="$3" mode="$4" tmp rc
  grep -qE "$re" "$file" || return 3          # nothing matched: file untouched
  tmp="$(mktemp "${file}.XXXXXX")"
  if awk -v re="$re" -v newval="$newval" -v mark="$MARK" -v mode="$mode" \
        "$(awk_program)" "$file" > "$tmp"; then
    # Keep the file's own mode: mktemp creates 600, a user config is usually 644.
    chmod --reference="$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
    return 0
  fi
  rm -f "$tmp"; return 1
}

# "default (14)" | "applied (14)" | "applied (added)" | "no-key" | "no-config"
_key_status(){ # <file> <key-regex>
  local file="$1" re="$2"
  [[ -f $file ]] || { echo "no-config"; return; }
  awk -v re="$re" -v mark="$MARK" '
    function trim(s){ sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    match($0, re) {
      prefix = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
      was = rest
      if (index(was, mark " (was ") != 0) {
        sub(".*" mark " \\(was ", "", was); sub("\\).*$", "", was)
        print "applied (" trim(was) ")"; found = 1
      } else if (index(rest, mark) != 0) {
        print "applied (added)"; found = 1
      } else {
        v = rest
        if (match(v, /#/)) v = substr(v, 1, RSTART - 1)
        print "default (" trim(v) ")"; found = 1
      }
      exit
    }
    END { if (!found) print "no-key" }
  ' "$file" 2>/dev/null || echo "unreadable"
}

report(){
  local e term file re st pt="" pf="" ps="" rows=()
  for e in "${SPECS[@]}"; do
    IFS='|' read -r term file re _ <<< "$e"
    st="$(_key_status "$file" "$re")"
    # ghostty/alacritty carry two keys (x and y) in ONE file: they are written
    # together, so the second row would only ever repeat the first. Deduped per
    # (file, status), NOT per status: every terminal reads "applied (14)" and
    # must still get its own row.
    if [[ $term == "$pt" && $st == "$ps" && $file == "$pf" ]]; then continue; fi
    pt="$term"; ps="$st"; pf="$file"
    rows+=("$(printf '  %-10s %-18s %s' "$term" "$st" "$file")")
  done
  printf '%s\n' "${rows[@]}"
}

# Shared body of apply/remove: 0 = something changed, 1 = a write failed.
walk(){ # <mode> <new-value>
  local mode="$1" want="$2" e term file re unit rc val done="" first
  for e in "${SPECS[@]}"; do
    IFS='|' read -r term file re unit <<< "$e"
    # ghostty/alacritty carry two keys in ONE file: both are written, but only
    # the first of them reports, so the output is one line per terminal.
    case " $done " in *" $file "*) first=0 ;; *) first=1; done+=" $file" ;; esac
    if [[ ! -f $file ]]; then
      ((first)) && warn "$term — no user config at $file (skipped, nothing created)"
      continue
    fi
    if [[ $mode == remove ]]; then
      grep -q -- "$MARK" "$file" || continue
      val=""
    else
      val="$(fmt_value "$unit" "$want")"   # foot takes 0x0, the others a bare 0
    fi
    set +e
    _patch_key "$file" "$re" "$val" "$mode"
    rc=$?
    set -e
    case $rc in
      0) changed=1
         if ((first)) && [[ $mode == apply ]]; then
           ok "$term — padding set to $val in $file"
         elif ((first)); then
           ok "$term — original padding restored in $file"
         fi ;;
      1) err "$term — could not rewrite $file"; return 1 ;;
      3) if ((first)) && [[ $mode == apply ]]; then
            warn "$term — no padding key in $file (left as is)"
          fi ;;
    esac
  done
  return 0
}

reload(){
  command -v omarchy-restart-terminal >/dev/null 2>&1 &&
    omarchy-restart-terminal >/dev/null 2>&1 || true
  info "Alacritty, kitty and ghostty reload on the fly. foot (and any other"
  info "terminal) reads the padding at startup: open a NEW window to see it."
}

n=0
action=apply
while (($#)); do
  case $1 in
    --status)              action=status ;;
    --remove|--uninstall)  action=remove ;;
    --set)
      shift || { err "--set needs a value"; exit 1; }
      [[ $1 =~ ^[0-9]+$ ]] || { err "--set takes a number of pixels (got '$1')"; exit 1; }
      n=$1 ;;
    --set=*)
      n="${1#--set=}"
      [[ $n =~ ^[0-9]+$ ]] || { err "--set takes a number of pixels"; exit 1; } ;;
    -y|--yes) : ;;   # accepted for the orchestrator; nothing here prompts
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

case $action in
  status)
    info "Terminal padding status:"
    report
    exit 0 ;;
  remove)
    info "Restoring the padding each terminal had before the fix…"
    changed=0
    walk remove "" || exit 1
    if ((changed)); then reload; else ok "Nothing to restore — no marked line found."; fi
    exit 0 ;;
  apply)
    if ((n == 0)); then
      info "Removing the terminal inner padding (the thick frame around the text)…"
    else
      info "Setting the terminal inner padding to ${n}px…"
    fi
    changed=0
    walk apply "$n" || exit 1
    if ((changed)); then reload; else ok "Already applied — nothing to do."; fi
    exit 0 ;;
esac
