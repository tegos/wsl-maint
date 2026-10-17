#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./assert.sh
. ../wsl/lib/common.sh
. ../wsl/lib/rules.sh
. ../wsl/lib/clean.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

freed_line() { echo "$1" | grep -E '^(freed|would free): ' | tail -1; }

# --- the summary counts what was actually reclaimed, not what was estimated ---
# Every rule's byte count is measured BEFORE the rule runs, so anything that
# announces "frees N" and then does not happen -- a journal vacuum without
# passwordless sudo, a target safe_rm refuses -- used to be added to the total
# anyway. That reports disk space that is still occupied.

# Case 1: journal vacuum skipped for lack of passwordless sudo.
# Both stubs live inside the command substitution's own subshell so they
# cannot leak into any later assertion.
printf '/var/log/journal vacuum 100M yes\n' > "$TMP/vac.conf"

DRY_RUN=0
out=$(
  sudo() { return 1; }
  journalctl() { echo 'Archived and active journals take up 514.2M in the file system.'; }
  clean_run "$TMP/vac.conf" 0 2>/dev/null
)
assert_eq "freed: 0.0" "$(freed_line "$out")" \
  "skipped vacuum contributes nothing to the freed total"

# Negative control for case 1: when the vacuum DOES run, its bytes must count.
# journalctl reports the pre-vacuum size on the first call and the post-vacuum
# size after, which is what a real successful vacuum looks like.
out=$(
  sudo() { [ "${1:-}" = "-n" ] && shift; [ "${1:-}" = "true" ] && return 0; return 0; }
  journalctl() {
    if [ -e "$TMP/vacuumed" ]; then
      echo 'Archived and active journals take up 100M in the file system.'
    else
      echo 'Archived and active journals take up 514.2M in the file system.'
    fi
  }
  # The vacuum itself is the sudo call that is not `true`; mark it as done.
  sudo() {
    [ "${1:-}" = "-n" ] && shift
    [ "${1:-}" = "true" ] && return 0
    : > "$TMP/vacuumed"
    return 0
  }
  clean_run "$TMP/vac.conf" 0 2>/dev/null
)
assert_eq "freed: 414.3M" "$(freed_line "$out")" \
  "successful vacuum contributes its reclaimed bytes"
rm -f "$TMP/vacuumed"

# Case 2: a protected target inside a rule is refused, so its bytes are not free.
mkdir -p "$TMP/pr/a" "$TMP/pr/b"
head -c 1048576 /dev/zero > "$TMP/pr/a/blob"
head -c 3145728 /dev/zero > "$TMP/pr/b/blob"
printf '%s purge - yes\n' "$TMP/pr" > "$TMP/pr.conf"

# Save the real protected list once; every fixture override below restores it.
REAL_PATTERNS=("${PROTECTED_PATTERNS[@]}")
PROTECTED_PATTERNS=("$TMP/pr/b")
DRY_RUN=1
out=$(clean_run "$TMP/pr.conf" 0 2>/dev/null)
assert_eq "would free: 4.0M" "$(freed_line "$out")" \
  "dry-run still reports the estimate for the whole rule"

DRY_RUN=0
out=$(clean_run "$TMP/pr.conf" 0 2>/dev/null)
assert_eq "freed: 1.0M" "$(freed_line "$out")" \
  "refused target's bytes are excluded from the freed total"
assert_ok "[ -d \"$TMP/pr/b\" ]" "protected target survived"
assert_fails "[ -d \"$TMP/pr/a\" ]" "unprotected target removed"
PROTECTED_PATTERNS=("${REAL_PATTERNS[@]}")
assert_contains "${PROTECTED_PATTERNS[*]}" "$HOME/.ssh" "real protected list restored after the pr fixture"

# Positive control: nothing refused, so the whole estimate is reclaimed.
mkdir -p "$TMP/ok/a" "$TMP/ok/b"
head -c 1048576 /dev/zero > "$TMP/ok/a/blob"
head -c 3145728 /dev/zero > "$TMP/ok/b/blob"
printf '%s purge - yes\n' "$TMP/ok" > "$TMP/ok.conf"
out=$(clean_run "$TMP/ok.conf" 0 2>/dev/null)
assert_eq "freed: 4.0M" "$(freed_line "$out")" \
  "an unobstructed rule reclaims its full estimate"

# --- auto=no rules stay out unless manual mode is asked for ---
mkdir -p "$TMP/man/x"
head -c 1048576 /dev/zero > "$TMP/man/x/blob"
printf '%s purge - no\n' "$TMP/man" > "$TMP/man.conf"
DRY_RUN=1
out=$(clean_run "$TMP/man.conf" 0 2>/dev/null)
assert_eq "would free: 0.0" "$(freed_line "$out")" "auto=no skipped by default"
out=$(clean_run "$TMP/man.conf" 1 2>/dev/null)
assert_eq "would free: 1.0M" "$(freed_line "$out")" "auto=no included with manual mode"

# --- an unreadable rules file is a failure, not an empty clean ---
# Regression: clean_run read the parser through `done < <(rules_parse ...)`,
# where the exit status is invisible, so a typo'd --rules path printed an error,
# printed "freed: 0.0" and exited 0. On the Windows side Invoke-Wsl throws only
# on a non-zero exit, so backup's [1/6] became a silent no-op that reported
# success -- and Confirm-LargeDeletion read the 0.0 as "safely below the
# threshold" and waved the run through.
DRY_RUN=1
assert_fails "clean_run \"$TMP/no-such-rules.conf\" 0 >/dev/null 2>&1" \
  "a missing rules file makes clean_run fail"

printf '%s frobnicate - yes\n' "$TMP/ok" > "$TMP/badpolicy.conf"
assert_fails "clean_run \"$TMP/badpolicy.conf\" 0 >/dev/null 2>&1" \
  "an unknown policy makes clean_run fail"

# A bad policy arg fails the run before anything is deleted, the valid rule
# beside it included. Regression: `age 1w` read as text and deleted fresh
# entries; `keep-newest -1` deleted all of them.
mkdir -p "$TMP/badarg/fresh" "$TMP/badarg2/keep"
head -c 65536 /dev/urandom > "$TMP/badarg/fresh/blob"
head -c 65536 /dev/urandom > "$TMP/badarg2/keep/blob"
touch -d "5 days ago" "$TMP/badarg/fresh/blob" "$TMP/badarg/fresh"
printf '%s age 1w yes\n%s keep-newest -1 yes\n%s purge - yes\n' \
  "$TMP/badarg" "$TMP/badarg" "$TMP/badarg2" > "$TMP/badarg.conf"
DRY_RUN=0
assert_fails "clean_run \"$TMP/badarg.conf\" 0 >/dev/null 2>&1" \
  "a bad policy arg makes clean_run fail"
assert_ok "[ -d \"$TMP/badarg/fresh\" ]" "bad arg: the rule's own entries are kept"
assert_ok "[ -d \"$TMP/badarg2/keep\" ]" "bad arg: no other rule runs either"
DRY_RUN=1

# --- a refused target makes the run fail, but the summary still prints ---
# Regression: `rule_apply ... | sed ... || true` discarded the rule's status, so
# `clean` had no non-zero exit path at all. The `|| true` was there to stop one
# refusal aborting the loop under set -e; that still holds -- the failure is
# recorded and reported after the summary instead of thrown away.
mkdir -p "$TMP/fail/a" "$TMP/fail/b"
head -c 1048576 /dev/zero > "$TMP/fail/a/blob"
head -c 1048576 /dev/zero > "$TMP/fail/b/blob"
printf '%s purge - yes\n' "$TMP/fail" > "$TMP/fail.conf"
PROTECTED_PATTERNS=("$TMP/fail/b")
DRY_RUN=0
out=$(clean_run "$TMP/fail.conf" 0 2>/dev/null)
rc=$?
assert_eq "1" "$rc" "a refused target makes clean_run exit non-zero"
assert_eq "freed: 1.0M" "$(freed_line "$out")" "the freed summary is still printed on failure"
PROTECTED_PATTERNS=("${REAL_PATTERNS[@]}")
assert_contains "${PROTECTED_PATTERNS[*]}" "$HOME/.ssh" "real protected list restored after the fail fixture"

# Positive control: the same shape with nothing refused exits 0.
mkdir -p "$TMP/pass/a"
head -c 1048576 /dev/zero > "$TMP/pass/a/blob"
printf '%s purge - yes\n' "$TMP/pass" > "$TMP/pass.conf"
assert_ok "clean_run \"$TMP/pass.conf\" 0 >/dev/null 2>&1" "an unobstructed run exits 0"

# --- an age entry kept unscanned is reported once per run ---
# The estimate, the apply and the re-measure each walk the root; each used to
# repeat the "cannot read all of" warning.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMP/agew/locked/sub" "$TMP/agew/old"
  head -c 8192 /dev/zero > "$TMP/agew/old/blob"
  touch -d "90 days ago" "$TMP/agew/old/blob" "$TMP/agew/old" "$TMP/agew/locked/sub" "$TMP/agew/locked"
  chmod 000 "$TMP/agew/locked/sub"
  printf '%s age 30d yes\n' "$TMP/agew" > "$TMP/agew.conf"
  DRY_RUN=0
  err=$(clean_run "$TMP/agew.conf" 0 2>&1 >/dev/null)
  chmod 755 "$TMP/agew/locked/sub"
  assert_eq "1" "$(printf '%s\n' "$err" | grep -c 'cannot read all of')" \
    "the unreadable age entry is warned about exactly once per clean run"
  assert_fails "[ -e \"$TMP/agew/old\" ]" "the stale sibling was still removed"
fi

echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
