#!/usr/bin/env bash
# Playwright chromium revision reconciliation. Sourced, never executed directly.
set -uo pipefail

# Built-in roots searched for installed playwright packages. ~/.npm/_npx and
# ~/.nvm matter: npx-cached and globally installed playwright pin their own
# chromium revisions, and omitting them makes live revisions look orphaned. A
# missing one is normal (see _pw_missing_default_root_ok).
pw_scan_roots() {
  cat <<EOF
$HOME/tools
$HOME/.local
$HOME/.nvm
$HOME/.npm/_npx
$HOME/.cache/ms-playwright-mcp
EOF
}

# Project directories differ per box, so they come from maint.conf
# (pw_scan_roots_extra, ':'-separated), one per line. The user named each of
# them, so unlike a built-in root a missing one is never skipped: it fails the
# scan closed, like a root listed in PW_ROOTS_FILE.
pw_scan_roots_extra() {
  [ -n "${CFG_PW_SCAN_ROOTS_EXTRA:-}" ] || return 0
  printf '%s\n' "${CFG_PW_SCAN_ROOTS_EXTRA//:/$'\n'}"
}

# A missing DEFAULT root is normal (nothing installed there, or another box),
# except when it lives on a drive that is not mounted: then the root is not
# absent, it is unscanned, and whatever it pins would look orphaned. So a
# missing root under $PW_MNT_BASE/<x>/ is only fatal when $PW_MNT_BASE/<x> is
# not a mountpoint or is empty (mountpoint(1) may be missing; the emptiness
# check alone then decides). PW_MNT_BASE / PW_MOUNTPOINT_CMD are test seams.
# Returns 0 when the missing root may be skipped, 1 when the scan must fail
# closed; on 1 it prints the drive path it blamed.
_pw_missing_default_root_ok() {
  local root="$1" base="${PW_MNT_BASE:-/mnt}" mp_cmd="${PW_MOUNTPOINT_CMD:-mountpoint}" rest drive
  case "$root" in
    "$base"/*) ;;
    *) return 0 ;;
  esac
  rest="${root#"$base"/}"
  drive="$base/${rest%%/*}"
  if [ ! -d "$drive" ] || [ -z "$(ls -A "$drive" 2>/dev/null)" ]; then
    printf '%s\n' "$drive"
    return 1
  fi
  if command -v "$mp_cmd" >/dev/null 2>&1 && ! "$mp_cmd" -q "$drive" 2>/dev/null; then
    printf '%s\n' "$drive"
    return 1
  fi
  return 0
}

# Deepest observed browsers.json under any scan root, on the box it was
# measured on, was 10
# (~/.nvm/versions/node/.../node_modules/@playwright/mcp/node_modules/playwright-core).
# +5 headroom over that measured max. Missing a real browsers.json here would
# drop a live chromium revision out of the wanted set and get it deleted as an
# "orphan", so this bound is deliberately generous rather than tight: measured,
# going shallower than 9 (the deepest venv-nested install under a projects
# scan root) already starts losing real results (see task-3 fix report), and
# even at the minimum safe depth the scan time is statistically
# indistinguishable from unbounded on that box -- the cost there is
# breadth (thousands of node_modules dirs), not depth. The cap exists as a
# guard against a future, genuinely pathological tree, not as the fix for
# today's slowness; scanning once per run (see pw_wanted_revisions) is the actual fix.
PW_SCAN_MAXDEPTH="${PW_SCAN_MAXDEPTH:-15}"

# Walks each root read from stdin and appends the browsers.json paths it finds
# to the CALLER's bjs, setting the caller's incomplete=1 on any failure (bash
# locals are dynamically scoped, and this runs in the caller's shell, not a
# subshell). MODE builtin: a missing root may be skipped (see
# _pw_missing_default_root_ok). MODE strict: a missing root fails closed.
# ORIGIN is appended to the warnings, to say where the root came from.
_pw_scan_roots_into_bjs() {
  local mode="$1" origin="$2" root found drive
  while IFS= read -r root; do
    [ -n "${root//[[:space:]]/}" ] || continue
    if [ ! -e "$root" ] && [ "$mode" = "builtin" ]; then
      if drive=$(_pw_missing_default_root_ok "$root"); then
        continue
      fi
      log_warn "playwright scan root $root is missing and drive $drive looks unmounted or empty"
      incomplete=1
      continue
    fi
    if [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; then
      log_warn "playwright scan root missing or unreadable: $root$origin"
      incomplete=1
      continue
    fi
    if ! found=$(find "$root" -maxdepth "$PW_SCAN_MAXDEPTH" -name browsers.json -path '*playwright*' 2>/dev/null); then
      log_warn "playwright scan of $root hit errors (unreadable dir or I/O); results incomplete$origin"
      incomplete=1
    fi
    [ -n "$found" ] && bjs+="$found"$'\n'
  done
  return 0
}

# Every chromium revision any installed playwright asks for. Returns 1 when
# the scan was incomplete; see the fail-closed note below.
#
# Not memoized: rule_run plans each rule once per process, so the one
# pw-orphan rule asks for this once. It used to be asked two or three times
# per run, which needed a cache file named per (pid, start-time) and an EXIT
# trap to remove it.
pw_wanted_revisions() {
  local roots_file="${1:-}" result

  if [ -z "$roots_file" ] || [ ! -f "$roots_file" ]; then
    roots_file=""
    if [ -n "${PW_ROOTS_FILE:-}" ] && [ -f "${PW_ROOTS_FILE:-}" ]; then
      roots_file="$PW_ROOTS_FILE"
    fi
  fi

  # Fail CLOSED: the wanted set is only trustworthy if every root was walked
  # and every browsers.json parsed. A missing root (/mnt/d not mounted), a find
  # error inside a drvfs walk, or one unparseable browsers.json leaves a set
  # that is partial but non-empty, and the "empty set" valve in pw_orphan_dirs
  # cannot see that -- it would delete revisions the unscanned part still pins.
  # So any such failure makes this return 1. The loops read here-strings, not
  # pipes, so the `incomplete` flag set inside them survives into this shell.
  local roots bj revs bjs="" incomplete=0
  if [ -n "$roots_file" ]; then
    roots=$(cat "$roots_file" 2>/dev/null) || {
      log_warn "cannot read scan roots file $roots_file"
      incomplete=1
    }
    _pw_scan_roots_into_bjs strict " (listed in roots file $roots_file; a root that legitimately does not exist must be removed from that file)" <<< "$roots"
  else
    _pw_scan_roots_into_bjs builtin "" <<< "$(pw_scan_roots)"
    _pw_scan_roots_into_bjs strict " (listed in pw_scan_roots_extra in ${CFG_CONFIG_FILE:-maint.conf}; remove it there if it is gone for good)" <<< "$(pw_scan_roots_extra)"
  fi

  while IFS= read -r bj; do
    [ -n "$bj" ] || continue
    if ! revs=$(jq -r '.browsers[] | select(.name | startswith("chromium")) | .revision' "$bj" 2>/dev/null); then
      log_warn "cannot parse playwright browsers.json: $bj"
      incomplete=1
      continue
    fi
    [ -n "$revs" ] && result+="$revs"$'\n'
  done <<< "$bjs"

  result=$(printf '%s' "${result:-}" | sort -un)
  printf '%s\n' "$result"
  [ "$incomplete" -eq 0 ]
}

# Cache subdirectories no installed playwright references.
pw_orphan_dirs() {
  local cache="$1" wanted d rev
  [ -d "$cache" ] || return 0
  if ! wanted=$(pw_wanted_revisions); then
    log_warn "playwright scan incomplete; skipping orphan prune for safety (nothing deleted this run)"
    return 0
  fi
  if [ -z "$wanted" ]; then
    log_warn "no installed playwright found; skipping orphan prune for safety"
    return 0
  fi
  for d in "$cache"/chromium-* "$cache"/chromium_headless_shell-*; do
    [ -d "$d" ] || continue
    # Targets go out one per line, so a newline in a name forges extra lines:
    # $'chromium-1217\nchromium-1234' would print the pinned ROOT/chromium-1217
    # and a cwd-relative chromium-1234. Kept, like the other policies do.
    case "$d" in
      *$'\n'*)
        log_warn "pw-orphan: name with a newline in $cache kept: $(printf '%q' "${d##*/}")"
        continue ;;
    esac
    rev="${d##*-}"
    case "$rev" in
      ''|*[!0-9]*) continue ;;
    esac
    if ! printf '%s\n' "$wanted" | grep -qx "$rev"; then
      echo "$d"
    fi
  done
}
