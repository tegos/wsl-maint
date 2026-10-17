#!/usr/bin/env bash
# Line endings a default Git for Windows clone (core.autocrlf=true) produces.
# wsl/maint and every *.sh run inside WSL, where a CRLF line is a syntax error,
# so .gitattributes must pin them to LF; maint.bat must be CRLF, because
# cmd.exe misparses labels and goto targets in an LF-only batch file.
#
# The working tree's tracked files (uncommitted edits included) are copied
# into a scratch repo, committed, and cloned with autocrlf=true, so the test
# sees exactly what such a clone checks out.
set -uo pipefail
cd "$(dirname "$0")"
. ./assert.sh

# The repo root is the parent of tests/. Not `git rev-parse --show-toplevel`:
# with GIT_DIR exported (as under a hook) that answers with the current dir.
top=$(cd .. && pwd)
if ! command -v git >/dev/null 2>&1 || ! git -C "$top" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "  SKIP not a git work tree"
  echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
  exit 0
fi

tracked=$(cd "$top" && git ls-files -z --cached --others --exclude-standard | tr '\0' '\n')
# Under the pre-commit hook git exports GIT_DIR, GIT_INDEX_FILE and friends,
# which would point every git call below at the real repo and its index.
# From here on git only ever sees the scratch repos.
unset $(git rev-parse --local-env-vars)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkdir -p "$TMP/src"
while IFS= read -r f; do
  [ -f "$top/$f" ] || continue
  mkdir -p "$TMP/src/$(dirname "$f")"
  cp -p "$top/$f" "$TMP/src/$f"
done <<< "$tracked"
git init -q "$TMP/src"
# Refuse to go on unless git really resolves to the scratch repo.
if [ "$(git -C "$TMP/src" rev-parse --show-toplevel)" != "$(cd "$TMP/src" && pwd -P)" ]; then
  echo "  FAIL TEST GUARD: git does not resolve to the scratch repo"
  echo "RESULT 0 1"
  exit 1
fi
git -C "$TMP/src" add -A
git -C "$TMP/src" commit -q -m snapshot
git -c core.autocrlf=true clone -q "$TMP/src" "$TMP/win"

has_cr() { grep -q $'\r' "$1"; }

lf_files=$(cd "$TMP/src" && ls -1 wsl/maint wsl/lib/*.sh tests/*.sh .githooks/pre-commit rules.conf maint.conf.example)
assert_ok "[ $(printf '%s\n' "$lf_files" | wc -l) -ge 20 ]" "the LF file list is not empty"
for f in $lf_files; do
  assert_fails "has_cr '$TMP/win/$f'" "autocrlf=true clone keeps $f LF"
done
assert_ok "has_cr '$TMP/win/maint.bat'" "autocrlf=true clone gives maint.bat CRLF"
assert_fails "grep -q \$'[^\\r]\$' '$TMP/win/maint.bat'" "every maint.bat line ends in CRLF"
# A clone made with autocrlf off (WSL, Linux CI) gets the same shell files.
git -c core.autocrlf=false clone -q "$TMP/src" "$TMP/lin"
assert_fails "has_cr '$TMP/lin/wsl/maint'" "autocrlf=false clone keeps wsl/maint LF"
assert_ok "has_cr '$TMP/lin/maint.bat'" "autocrlf=false clone still gives maint.bat CRLF"

echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
