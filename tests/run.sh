#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

TOTAL_PASS=0
TOTAL_FAIL=0

for t in test_*.sh; do
  [ -f "$t" ] || continue
  echo "== $t"
  out=$(bash "$t" 2>&1)
  echo "$out" | grep -v '^RESULT ' || true
  line=$(echo "$out" | grep '^RESULT ' | tail -1)
  p=$(echo "$line" | awk '{print $2}')
  f=$(echo "$line" | awk '{print $3}')
  TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
  TOTAL_FAIL=$((TOTAL_FAIL + ${f:-1}))
done

# Windows-side PowerShell suite (tests/win/Run.ps1). It is a separate runner
# because it needs powershell.exe, but its totals are folded in here so
# `bash tests/run.sh` is still the one command that says whether the repo is
# green. Skipped cleanly - not failed - when there is no Windows to run it on,
# except under CI (CI set): there a half that did not run is a failure, so a
# missing powershell.exe can never read as green. Set WSL_MAINT_SKIP_WIN=1 to
# skip it deliberately; that is honoured everywhere, CI included.
WIN_SKIPPED=""
if [ "${WSL_MAINT_SKIP_WIN:-0}" = "1" ]; then
  echo "== win/Run.ps1  SKIPPED (WSL_MAINT_SKIP_WIN=1)"
elif command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
  runner=$(wslpath -w "$PWD/win/Run.ps1" 2>/dev/null || true)
  if [ -z "$runner" ]; then
    WIN_SKIPPED="cannot map $PWD/win/Run.ps1 to a Windows path"
  else
    echo "== win/Run.ps1"
    # -ExecutionPolicy Bypass, same as maint.bat: this repo lives on a path
    # that PowerShell can see as remote/UNC, where an unsigned .ps1 is refused
    # outright. Without the flag the runner does not skip cleanly, it reports
    # failed: 1.
    out=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$runner" 2>&1 | tr -d '\r')
    echo "$out" | grep -v '^passed: ' || true
    line=$(echo "$out" | grep '^passed: ' | tail -1)
    p=$(echo "$line" | awk '{print $2}')
    f=$(echo "$line" | awk '{print $4}')
    TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
    TOTAL_FAIL=$((TOTAL_FAIL + ${f:-1}))
  fi
else
  WIN_SKIPPED="powershell.exe not available"
fi

if [ -n "$WIN_SKIPPED" ]; then
  if [ -n "${CI:-}" ]; then
    echo "== win/Run.ps1  FAIL under CI: did not run ($WIN_SKIPPED); set WSL_MAINT_SKIP_WIN=1 to skip on purpose"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  else
    echo "== win/Run.ps1  SKIPPED ($WIN_SKIPPED)"
  fi
fi

echo
echo "passed: $TOTAL_PASS  failed: $TOTAL_FAIL"
[ "$TOTAL_FAIL" -eq 0 ]
