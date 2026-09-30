#!/usr/bin/env bash
# =============================================================================
# Omarchy Custom — Hyprland crash recovery
# =============================================================================
# Self-healing fix for the usual "the desktop came up broken" scenarios.
# It DETECTS each failure and only modifies a file that is actually broken:
#
#   • hyprland.lua missing, truncated or reduced to a fragment (the Omarchy
#     bootstrap defaults are gone → every o.* call dies with "attempt to
#     index a nil value (global 'o')") → restored from the NEWEST VALID
#     backup in ~/.config/hypr (hyprland.lua.bak, hyprland.lua.bak.*); the
#     broken file is kept as hyprland.lua.broken.<ts> for forensics.
#   • Fatal Lua escapes (\., any bad \x inside a regex string) → normalized
#     in place: a regex dot must be escaped twice "\." → "\\." in a Lua
#     string, or the whole file fails to parse on reload.
#   • Repeated identical generated blocks (a setup script was re-run several
#     times, e.g. the yabridge plugin-handler rule) → deduplicated.
#   • Personal hypr/<module>.lua files present on disk but no longer
#     require()d in hyprland.lua (an Omarchy refresh rewrote it, or a restore
#     picked an old backup) → re-registered in a removable marker block.
#   • Keyboard layout reset to "us" after a broken boot (input.lua was never
#     loaded by the fragment) → re-applied from /etc/vconsole.conf via the
#     registered input.lua + reload.
#   • Omarchy shell (quickshell) missing after that same boot — its
#     hl.on("hyprland.start") hook never fired → restarted.
#   • Residual config errors → reported with hyprctl configerrors after every
#     reload, and the reload itself is validated.
#
# Idempotent and non-destructive when healthy: a healthy config is only
# checked, never rewritten. Every change is logged to
# ~/.local/state/omarchy-hyprland-fix/recovery.log.
#
# By default it also installs a post-boot hook (omarchy post-boot event) that
# re-runs this recovery at every desktop start, so a bad boot heals itself
# before you even notice it.
#
# Usage:
#   ./fix-hyprland-crash.sh            # check + fix what is broken (safe)
#   ./fix-hyprland-crash.sh -y         # non-interactive (same as default)
#   ./fix-hyprland-crash.sh --status   # read-only report, changes nothing
#   ./fix-hyprland-crash.sh --quiet    # print only on problems, still logs
#   ./fix-hyprland-crash.sh --hook     # (re)install the post-boot hook, exit
#   ./fix-hyprland-crash.sh --no-hook  # this run only, no hook management
#   ./fix-hyprland-crash.sh --remove   # uninstall the hook + state, then exit
#   ./fix-hyprland-crash.sh -h         # this help
#
# Can be registered as a quick fix in mosquitomarchy-setup.sh (id: hyprland-crash)
# and added to $HOME/.config/omarchy/hooks/post-boot.d/ for boot-time healing.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gui-run.bash"  # file-manager launch support — keeps `set -e` unaffected afterwards
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
REAL_HOME="${HOME}"
HYPR_DIR="$REAL_HOME/.config/hypr"
HYPRLAND="$HYPR_DIR/hyprland.lua"
STATE_DIR="$REAL_HOME/.local/state/omarchy-hyprland-fix"
LOG_FILE="$STATE_DIR/recovery.log"
HOOK_NAME="zzz-fix-hyprland-crash"
HOOK_DIR="$REAL_HOME/.config/omarchy/hooks/post-boot.d"
HOOK_PATH="$HOOK_DIR/$HOOK_NAME"
SELF_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

CORE_MARK='require("default.hypr.omarchy")'
BOOTSTRAP_MARK="bootstrap.lua"
REQUIRE_START="-- >>> Omarchy_Custom_Scripts_HyprlandRecovery"
REQUIRE_END="-- <<< Omarchy_Custom_Scripts_HyprlandRecovery"

MODE="fix"
QUIET=false
HOOK_MODE="auto"

for a in "$@"; do case "$a" in
  -y|--yes) : ;;
  --status) MODE="status" ;;
  --quiet) QUIET=true ;;
  --hook) MODE="hook" ;;
  --no-hook) HOOK_MODE="off" ;;
  --remove) MODE="remove-hook" ;;
  -h|--help) sed -n '1,64p' "$0" | sed 's/^# \?//'; exit 0 ;;
  *) echo "Unknown option: $a (supported: -y --status --quiet --hook --no-hook --remove -h)" >&2; exit 1 ;;
esac; done

mkdir -p "$STATE_DIR"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
say() { log "$*"; [[ $QUIET == true ]] || echo -e "\033[1;34m==>\033[0m $*"; }
ok()  { log "$*"; [[ $QUIET == true ]] || echo -e "\033[1;32m ✓\033[0m $*"; }
warn(){ log "WARN $*"; echo -e "\033[1;33m !\033[0m $*" >&2; }
err() { log "ERROR $*"; echo -e "\033[1;31m ✗\033[0m $*" >&2; }
log() { printf '[%(%F %T)T] %s\n' -1 "$*" >>"$LOG_FILE" 2>/dev/null || return 0; }

in_session() { command -v hyprctl >/dev/null 2>&1; }

get_configerrors() { hyprctl configerrors 2>/dev/null | sed '/^[[:space:]]*$/d'; }

# -----------------------------------------------------------------------------
# hyprland.lua structure checks
# -----------------------------------------------------------------------------
# is_fragment: 0 = healthy structure, 1 = missing/truncated/fragment.
is_fragment() {
  [[ -f $HYPRLAND ]] || return 1
  grep -qF -- "$BOOTSTRAP_MARK" "$HYPRLAND" || return 1
  grep -qF -- "$CORE_MARK" "$HYPRLAND" || return 1
  return 0
}

# A valid backup = a real file that still carries the Omarchy bootstrap.
candidate_valid() {
  local f="$1"
  [[ -f $f ]] || return 1
  grep -qF -- "$BOOTSTRAP_MARK" "$f" || return 1
  grep -qF -- "$CORE_MARK" "$f" || return 1
  return 0
}

# Newest VALID automatic or manual backup (hyprland.lua.bak / hyprland.lua.bak.*).
pick_backup() {
  local f best="" best_t=-1 t
  for f in "$HYPR_DIR"/hyprland.lua.bak "$HYPR_DIR"/hyprland.lua.bak.*; do
    [[ -f $f ]] || continue
    case "$f" in
      *.broken.*) continue ;;
    esac
    candidate_valid "$f" || continue
    t="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    if (( t > best_t )); then best_t="$t"; best="$f"; fi
  done
  printf '%s' "$best"
}

restore_from_backup() {
  local backup="$1" ts
  if [[ -f $HYPRLAND ]]; then
    ts="$(date +%s)"
    cp -p "$HYPRLAND" "$HYPR_DIR/hyprland.lua.broken.$ts"
    warn "broken hyprland.lua kept for forensics: hyprland.lua.broken.$ts"
  fi
  cp "$backup" "$HYPRLAND"
  log "restored $HYPRLAND from $backup"
  ok "hyprland.lua restored from $backup"
}

# -----------------------------------------------------------------------------
# Sanitize: fatal Lua escapes + duplicated generated blocks
# -----------------------------------------------------------------------------
sanitize_hyprland() {
  [[ -f $HYPRLAND ]] || return 0
  local now tmp esc dedup
  now="$(<"$HYPRLAND")"
  tmp="$(mktemp)"
  esc="$(mktemp)"
  # (1) A regex dot inside a Lua string must be \\. ; a bare \. is an invalid
  #     Lua escape that makes `hyprctl reload` fail on the whole file.
  cat > "$esc" <<'PL'
if (index($_, "|.*\\.exe|") >= 0 && index($_, "|.*\\\\.exe|") < 0) {
  my $two = chr(92) x 2;
  s/\Q|.*\.exe|\E/|.*$two.exe|/g;
}
PL
  printf '%s' "$now" | perl -p "$esc" > "$tmp"
  rm -f "$esc"
  # (2) Collapse consecutive byte-identical ">>> name" generated blocks (a
  #     setup script was re-run) — keep only the first occurrence.
  dedup="$(mktemp)"
  cat > "$dedup" <<'DEDUP'
my $text = do { local $/; <STDIN> };
exit 0 if $text !~ /^-- >>> /m;

my @L = split /\n/, $text;
my @s;
for (my $i = 0; $i < @L; $i++) { push @s, $i if $L[$i] =~ /^-- >>> /; }

my @out;
my $prev_sig = "";

for (my $i = 0; $i < @s; $i++) {
  my $s = $s[$i];
  my $e = ($i + 1 < @s) ? $s[$i + 1] : @L;
  if ($i == 0 && $s > 0) { push @out, @L[0 .. $s - 1]; }
  my @seg = @L[$s .. ($e - 1)];
  my $sig = join("\x1f", @seg);
  next if $sig eq $prev_sig;
  $prev_sig = $sig;
  push @out, @seg;
}
print join("\n", @out), "\n";
DEDUP
  perl "$dedup" < "$tmp" > "$tmp.dedup" 2>/dev/null || true
  rm -f "$dedup"
  [[ -f $tmp.dedup ]] && mv "$tmp.dedup" "$tmp" || true
  # Safety net: never commit a sanitized file that lost the Omarchy bootstrap
  # or is empty — that would only turn one crash into another.
  if [[ ! -s $tmp ]] || ! grep -qF -- "$BOOTSTRAP_MARK" "$tmp" || ! grep -qF -- "$CORE_MARK" "$tmp"; then
    warn "sanitize produced an invalid config — keeping the previous content"
    printf '%s' "$now" > "$tmp"
  fi
  if [[ "$now" != "$(<"$tmp")" ]]; then
    mv "$tmp" "$HYPRLAND"
    ok "hyprland.lua sanitized (Lua escape normalized, duplicated generated blocks collapsed)"
  else
    rm -f "$tmp"
  fi
}

# -----------------------------------------------------------------------------
# Re-register personal hypr/<module>.lua files that exist but aren't require()d
# -----------------------------------------------------------------------------
personal_modules() {
  local f base
  for f in "$HYPR_DIR"/*.lua; do
    [[ -f $f ]] || continue
    base="$(basename "$f" .lua)"
    case "$base" in
      hyprland|hyprland.*) continue ;;
    esac
    printf '%s\n' "$base"
  done
}

missing_modules() {
  local m
  for m in $(personal_modules); do
    grep -qF "require(\"hypr.$m\")" "$HYPRLAND" || printf '%s\n' "$m"
  done
}

ensure_requires() {
  [[ -f $HYPRLAND ]] || return 1
  local -a missing=()
  local m block tmp s e anchor
  while read -r m; do [[ -n $m ]] && missing+=("$m"); done < <(missing_modules)
  (( ${#missing[@]} == 0 )) && return 0

  block="$(mktemp)"
  {
    echo "$REQUIRE_START"
    for m in "${missing[@]}"; do echo "require(\"hypr.$m\")"; done
    echo "$REQUIRE_END"
  } > "$block"

  tmp="$(mktemp)"
  if grep -qF -- "$REQUIRE_START" "$HYPRLAND"; then
    s="$(grep -nF -- "$REQUIRE_START" "$HYPRLAND" | head -1 | cut -d: -f1)"
    e="$(grep -nF -- "$REQUIRE_END" "$HYPRLAND" | head -1 | cut -d: -f1)"
    if ! { [[ -n $s && -n $e ]] && (( e > s )); }; then
      warn "inconsistent recovery markers in $HYPRLAND, skipping re-registration (fix by hand)"
      rm -f "$block" "$tmp"
      return 1
    fi
    { head -n $((s - 1)) "$HYPRLAND"; cat "$block"; tail -n +$((e + 1)) "$HYPRLAND"; } > "$tmp"
    mv "$tmp" "$HYPRLAND"
  else
    anchor='require("hypr.autostart")'
    grep -qF -- "$anchor" "$HYPRLAND" || anchor='require("default.hypr.omarchy")'
    awk -v bk="$block" -v tok="$anchor" '
      index($0, tok) == 1 && !done {
        print; print ""
        while ((getline l < bk) > 0) print l
        close(bk); done = 1; next
      }
      { print }
      END { if (!done) { print ""; while ((getline l < bk) > 0) print l; close(bk) } }
    ' "$HYPRLAND" > "$tmp"
    mv "$tmp" "$HYPRLAND"
  fi
  rm -f "$block"
  ok "re-registered personal modules in hyprland.lua: ${missing[*]}"
}

# -----------------------------------------------------------------------------
# Reload + validation
# -----------------------------------------------------------------------------
reload_hypr() {
  if ! in_session; then
    warn "hyprctl not found (not a Hyprland session) — config applies at next login."
    return 1
  fi
  if hyprctl reload >/dev/null 2>&1; then
    local errs
    errs="$(get_configerrors)"
    if [[ -n $errs ]]; then
      warn "Hyprland reloaded but still reports config errors:"
      printf '%s\n' "$errs" | sed 's/^/      /'
      return 1
    fi
    ok "Hyprland reloaded, config valid"
    return 0
  fi
  warn "hyprctl reload failed (compositor busy/down?) — try manually: hyprctl reload"
  return 1
}

# -----------------------------------------------------------------------------
# Keyboard layout
# -----------------------------------------------------------------------------
expected_kb_layout() {
  local v
  v="$(sed -n 's/^XKBLAYOUT="\?\([^" ]*\)"\?/\1/p' /etc/vconsole.conf 2>/dev/null | head -1)"
  [[ -n $v ]] && { printf '%s' "$v"; return 0; }
  printf 'us'
}

current_kb_layout() {
  in_session || return 0
  hyprctl getoption input:kb_layout 2>/dev/null | awk -F'str: ' '/^str:/{print $2; exit}'
}

check_keyboard() {
  local expected current after
  expected="$(expected_kb_layout)"
  current="$(current_kb_layout)"
  if [[ -z $current ]]; then
    warn "cannot read Hyprland input:kb_layout (compositor unreachable)"
    return 0
  fi
  if [[ "$current" != "$expected" ]]; then
    warn "keyboard layout is '$current' but /etc/vconsole.conf expects '$expected' — re-applying"
    if [[ -f $HYPR_DIR/input.lua ]] && grep -qF 'require("hypr.input")' "$HYPRLAND"; then
      reload_hypr || true
    fi
    after="$(current_kb_layout)"
    if [[ -n $after && "$after" == "$expected" ]]; then
      ok "keyboard layout restored: $after"
    else
      warn "layout still '$after' — switch manually: hyprctl switchxkblayout <device> 0 (or fix ~/.config/hypr/input.lua)"
    fi
  else
    ok "keyboard layout OK ($current)"
  fi
}

# -----------------------------------------------------------------------------
# Omarchy shell (quickshell)
# -----------------------------------------------------------------------------
shell_running() { pgrep -x quickshell >/dev/null 2>&1; }

restart_shell() {
  if shell_running; then
    ok "Omarchy shell (quickshell) already running"
    return 0
  fi
  warn "Omarchy shell (quickshell) is NOT running — restarting it..."
  if command -v omarchy >/dev/null 2>&1; then
    omarchy restart shell >/dev/null 2>&1 || true
  elif command -v omarchy-launch-shell >/dev/null 2>&1; then
    omarchy-launch-shell >/dev/null 2>&1 || true
  else
    err "Neither 'omarchy' nor 'omarchy-launch-shell' found — cannot start the shell."
    return 1
  fi
  sleep 1
  if shell_running; then
    ok "Omarchy shell restarted"
  else
    warn "quickshell still not running — check manually: omarchy restart shell"
  fi
}

# -----------------------------------------------------------------------------
# Post-boot hook (auto-heal at every desktop start)
# -----------------------------------------------------------------------------
hook_install() {
  local tmp
  mkdir -p "$HOOK_DIR"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
#!/usr/bin/env bash
# Auto-heal common Hyprland crashes (broken hyprland.lua, lost keyboard
# layout, missing Omarchy shell). Installed by fix-hyprland-crash.sh.
export GUI_RUN_EXEC=1
exec bash "$SELF_SCRIPT" -y --quiet --no-hook
EOF
  chmod +x "$tmp"
  if ! mv "$tmp" "$HOOK_PATH"; then
    warn "cannot write $HOOK_PATH"
    rm -f "$tmp"
    return 1
  fi
  ok "post-boot hook installed: $HOOK_PATH"
}

hook_remove() {
  if [[ -f $HOOK_PATH ]]; then
    rm -f "$HOOK_PATH"
    ok "post-boot hook removed: $HOOK_PATH"
  else
    ok "no post-boot hook installed"
  fi
  rmdir "$HOOK_DIR" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# --status (read-only)
# -----------------------------------------------------------------------------
do_status() {
  info_status() { echo -e "\033[1;34m==>\033[0m $*"; }
  info_status "Hyprland crash-recovery status (read-only)"
  if ! in_session; then
    echo "  • Not in a Hyprland session (hyprctl missing) — nothing to check here."
    echo "  • Post-boot hook: $([ -f "$HOOK_PATH" ] && echo installed || echo not installed)"
    echo "  • Recovery log: $LOG_FILE"
    return 0
  fi
  if [[ ! -f $HYPRLAND ]]; then
    echo "  • hyprland.lua: MISSING"
  elif is_fragment; then
    echo "  • hyprland.lua: OK (bootstrap + Omarchy defaults present)"
  else
    echo -e "  • hyprland.lua: \033[1;31mBROKEN/FRAGMENT\033[0m (bootstrap defaults missing)"
  fi
  local backup
  backup="$(pick_backup)"
  echo "  • Newest valid backup: ${backup:-none}"
  local errs
  errs="$(get_configerrors)"
  if [[ -n $errs ]]; then
    echo -e "  • hyprctl configerrors: \033[1;31mPRESENT\033[0m"
    printf '%s\n' "$errs" | sed 's/^/      /'
  else
    echo "  • hyprctl configerrors: none"
  fi
  local miss
  miss="$(missing_modules)"
  if [[ -n $miss ]]; then
    echo -e "  • Unregistered personal modules: \033[1;33m${miss//$'\n'/ }\033[0m"
  else
    echo "  • Personal modules: all registered"
  fi
  local fb
  fb="$(grep -cF '' "$HYPRLAND" 2>/dev/null || echo 0)"
  echo "  • hyprland.lua lines: $fb"
  if [[ -f /etc/vconsole.conf ]]; then
    echo "  • Expected keyboard layout: $(expected_kb_layout) — active: $(current_kb_layout)"
  fi
  echo "  • Omarchy shell: $(shell_running && echo running || echo NOT running)"
  echo "  • Post-boot hook: $([ -f "$HOOK_PATH" ] && echo installed || echo not installed)"
  echo "  • Recovery log: $LOG_FILE"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
if [[ $MODE == "remove-hook" ]]; then
  hook_remove
  rm -rf "$STATE_DIR"
  exit 0
fi
if [[ $MODE == "hook" ]]; then
  hook_install
  exit $?
fi
if [[ $MODE == "status" ]]; then
  do_status
  exit 0
fi

say "Hyprland crash recovery"

if ! in_session; then
  err "Not in a Hyprland session (hyprctl missing) — run this inside the desktop (or with --status)."
  exit 1
fi

# 1. hyprland.lua missing?
if [[ ! -f $HYPRLAND ]]; then
  backup="$(pick_backup)"
  if [[ -n $backup ]]; then
    warn "hyprland.lua is missing — restoring from backup"
    restore_from_backup "$backup"
  else
    err "hyprland.lua is missing and no valid backup found — restore manually."
    exit 1
  fi
fi

# 2. Structural integrity (bootstrap & Omarchy defaults present)?
if ! is_fragment; then
  backup="$(pick_backup)"
  if [[ -n $backup ]]; then
    warn "hyprland.lua is broken/truncated (Omarchy bootstrap missing) — this is what makes every o.* call fail with 'global o' errors"
    restore_from_backup "$backup"
  else
    err "hyprland.lua lacks the Omarchy bootstrap and no valid backup found — restore manually."
    exit 1
  fi
fi

# 3. Sanitize fatal Lua escapes + collapse duplicated generated blocks.
sanitize_hyprland

# 4. Re-register personal hypr/<module>.lua files that exist but aren't require()d.
ensure_requires || true

# 5. Reload + validate.
reload_hypr || true

# 6. Keyboard layout.
check_keyboard

# 7. Omarchy shell.
restart_shell || true

# 8. Post-boot hook (unless this run opted out).
if [[ $HOOK_MODE != "off" ]]; then
  [[ -f $HOOK_PATH ]] && ok "post-boot hook already installed: $HOOK_PATH" || hook_install
fi

say "Done. Every change is logged to $LOG_FILE (run with --status for a read-only report)"