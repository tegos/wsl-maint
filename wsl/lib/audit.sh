#!/usr/bin/env bash
# Usage table across all configured rules. Sourced, never executed directly.
set -uo pipefail

# audit_run RULES_FILE -- non-zero if the rules file could not be read.
audit_run() {
  local rules_file="$1"
  local path policy arg auto size freed prev delta_s diff total_size=0 total_freed=0 parsed

  # Read the file before printing a header. `done < <(rules_parse ...)` hid the
  # parser's exit status, so `audit --rules /typo` printed an empty table and
  # exited 0.
  parsed=$(rules_parse "$rules_file") || return 1

  printf '%-42s %-12s %8s %10s %10s %5s\n' \
    PATH POLICY SIZE "WOULD-FREE" "delta" AUTO
  printf '%.0s-' {1..92}; echo

  while IFS='|' read -r path policy arg auto; do
    [ -n "$path" ] || continue
    size=$(dir_bytes "$path")
    # A failed walk has already warned and leaves RULE_ESTIMATE at 0.
    rule_estimate "$path" "$policy" "$arg" || true
    freed="$RULE_ESTIMATE"
    prev=$(state_get "size.$path")
    if [ -n "$prev" ]; then
      diff=$(( size - prev ))
      # human() shells out to `numfmt --to=iec`, which reads a leading
      # "-<digit>" as an unrecognised option rather than a negative
      # number. Never hand it a negative value: format the magnitude and
      # attach the sign ourselves.
      if [ "$diff" -lt 0 ]; then
        delta_s="-$(human $(( -diff )))"
      else
        delta_s="+$(human "$diff")"
      fi
    else
      delta_s="-"
    fi
    state_set "size.$path" "$size"
    total_size=$(( total_size + size ))
    total_freed=$(( total_freed + freed ))
    printf '%-42s %-12s %8s %10s %10s %5s\n' \
      "${path/#$HOME/\~}" "$policy" "$(human "$size")" "$(human "$freed")" "$delta_s" "$auto"
  done <<< "$parsed"

  printf '%.0s-' {1..92}; echo
  printf '%-42s %-12s %8s %10s\n' TOTAL "" "$(human "$total_size")" "$(human "$total_freed")"
  echo
  echo "disk: $(df -h / | tail -1 | awk '{print $3" used, "$4" free"}')"
}
