#!/usr/bin/env bash
# Persistent key/value state. Sourced, never executed directly.
set -uo pipefail

state_file() {
  echo "${STATE_FILE:-$REPO_ROOT/logs/.state}"
}

state_get() {
  local key="$1" f
  f=$(state_file)
  [ -f "$f" ] || { echo ""; return 0; }
  awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); v=$0} END{print v}' "$f"
}

state_set() {
  local key="$1" value="$2" f tmp
  f=$(state_file)
  mkdir -p "$(dirname "$f")"
  touch "$f"
  tmp=$(mktemp)
  # Filter by exact key (field before the first '='), not by a grep
  # regex built from the key -- keys are derived from filesystem paths,
  # which routinely contain regex metacharacters (e.g. version dirs
  # like "91.0.4472.101"), so a regex-based match risks false positives.
  awk -F= -v k="$key" '$1 != k' "$f" > "$tmp" 2>/dev/null || true
  echo "${key}=${value}" >> "$tmp"
  mv "$tmp" "$f"
}

state_mark_run() {
  state_set "lastrun.$1" "$(date +%s)"
}

# state_is_stale NAME DAYS -> 0 when older than DAYS or never run
state_is_stale() {
  local name="$1" days="$2" last now
  last=$(state_get "lastrun.$name")
  [ -n "$last" ] || return 0
  now=$(date +%s)
  [ $(( now - last )) -ge $(( days * 86400 )) ]
}
