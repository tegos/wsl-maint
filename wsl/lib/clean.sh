#!/usr/bin/env bash
# Applies rules. Sourced, never executed directly.
set -uo pipefail

# clean_run RULES_FILE INCLUDE_MANUAL(0|1)
# Non-zero if the rules file could not be read or any rule failed.
clean_run() {
  local rules_file="$1" include_manual="${2:-0}"
  local path policy arg auto total=0 failures=0 parsed

  # Read the whole rules file first. Under the old `done < <(rules_parse ...)`
  # the parser's exit status was invisible, so a missing rules file printed an
  # error and still exited 0 -- and the Windows side, which throws only on a
  # non-zero exit, took that as a successful clean.
  parsed=$(rules_parse "$rules_file") || return 1

  while IFS='|' read -r path policy arg auto; do
    [ -n "$path" ] || continue
    if [ "$auto" != "yes" ] && [ "$include_manual" != "1" ]; then
      continue
    fi
    # rule_run is tested in an `if`, not left bare: under this process's
    # `set -e` (inherited from maint, which sources this file) one refused
    # target would otherwise abort the whole clean mid-loop, skipping every
    # remaining rule and the freed summary. A bare `|| true` would instead
    # throw the failure away, and `clean` would have no non-zero exit path.
    if ! rule_run "$path" "$policy" "$arg"; then
      failures=$((failures + 1))
    fi
    # The summary counts what was reclaimed (RULE_FREED), never the estimate:
    # a skipped vacuum or a refused target leaves its bytes on disk. A dry run
    # reclaims nothing, so its "would free" line is the sum of estimates.
    if [ "$DRY_RUN" = "1" ]; then
      total=$(( total + RULE_ESTIMATE ))
    else
      total=$(( total + RULE_FREED ))
    fi
  done <<< "$parsed"

  echo
  if [ "$DRY_RUN" = "1" ]; then
    echo "would free: $(human "$total")"
  else
    echo "freed: $(human "$total")"
  fi

  # Reported after the summary so the freed line is always printed, and as a
  # non-zero exit so maint.ps1's Invoke-Wsl (which throws only on a non-zero
  # exit) sees it. A failed clean deliberately does not reach state_mark_run,
  # so --if-stale will not treat it as a run that happened.
  if [ "$failures" -gt 0 ]; then
    log_err "$failures rule(s) failed"
    return 1
  fi
}
