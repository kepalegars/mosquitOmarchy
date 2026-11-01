#!/usr/bin/env bash
# marker-strip.bash — remove a managed block from a config file, by markers.
#
#   marker_strip <file> <start-marker> <end-marker> [boundary-prefix]
#
# Why this exists instead of `sed -i "/START/,/END/d"`: sed treats a range as
# running to END OF FILE when END never matches. A block whose closing marker was
# written wrong (a ">>>" where a "<<<" belonged) therefore made every setup run
# delete everything below the block — the Audio Plugin Manager, REAPER and Move
# Manager window rules all vanished from hyprland.lua in one go, and the config
# still parsed, so nothing complained.
#
# Behaviour:
#   * START absent            -> nothing to do, success.
#   * START and END present   -> delete exactly that block, success.
#   * START present, END not  -> delete up to the next block boundary (any line
#                                starting with the boundary prefix, default "-- ")
#                                so a malformed block cannot eat the rest of the
#                                file. If no boundary exists, delete NOTHING and
#                                fail: a loud refusal beats silent data loss.
#
# Markers are matched as fixed strings (grep -F / awk index), not regexes: they
# contain ">>>", "<<<" and other characters that are meaningful to a pattern.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/marker-strip.bash"

# marker_strip FILE START END [BOUNDARY_PREFIX]
marker_strip() {
  local file="${1:-}" start="${2:-}" end="${3:-}" boundary="${4:--- }"
  [[ -n $file && -n $start && -n $end ]] || {
    printf 'marker_strip: file, start and end markers are all required\n' >&2
    return 2
  }
  [[ -f $file ]] || return 0

  if ! grep -qF -- "$start" "$file"; then
    return 0   # not installed yet — appending is the right thing to do
  fi

  if grep -qF -- "$end" "$file"; then
    # Normal case: both markers are present, so the range is bounded.
    # Delete from the first START to the first END at-or-after it. `inside` MUST
    # be cleared when the block closes, otherwise every following line keeps
    # matching it and the whole remainder of the file is swallowed.
    awk -v s="$start" -v e="$end" '
      !done && index($0, s)  { inside = 1; next }
      !done && inside && index($0, e) { inside = 0; done = 1; next }
      !done && inside        { next }
      { print }
    ' "$file" > "$file.marker-strip.tmp" && mv "$file.marker-strip.tmp" "$file"
    return 0
  fi

  # START without END: the block is malformed. Cut to the next block boundary so
  # the rest of the file survives.
  local tmp
  tmp=$(mktemp)
  if awk -v s="$start" -v b="$boundary" '
        !done && index($0, s) { inside = 1; hit = 0; next }
        !done && inside {
          if (index($0, b) == 1) { inside = 0; done = 1; print; next }
          hit = 1; next
        }
        { print }
        END { if (!done && hit) exit 3 }
      ' "$file" > "$tmp"; then
    mv "$tmp" "$file"
    printf 'marker_strip: %s had an unterminated block; cut it back to the next block boundary\n' "$file" >&2
    return 0
  fi
  rm -f "$tmp"
  printf 'marker_strip: %s has an unterminated block and no following boundary — left untouched\n' "$file" >&2
  return 1
}
