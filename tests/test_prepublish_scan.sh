#!/usr/bin/env bash
# tools/pre-publish-scan.sh: the owner runs it on the exported tree before
# publishing. Every string here is made up; the real pattern file lives
# outside the repo and is never committed.
set -uo pipefail
cd "$(dirname "$0")"
. ./assert.sh

scan="$(cd .. && pwd)/tools/pre-publish-scan.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pats="$tmp/patterns.txt"
printf '%s\n' '# private strings, one per line' '' 'acme-widgets' '/home/jdoe' > "$pats"

# A match: non-zero exit, file:line printed.
tree="$tmp/dirty"
mkdir -p "$tree/docs"
printf 'line one\nsee /home/jdoe/notes\n' > "$tree/docs/a.md"
printf 'nothing here\n' > "$tree/b.sh"
out=$(bash "$scan" "$tree" "$pats" 2>&1); rc=$?
assert_eq 1 "$rc" "match exits 1"
assert_contains "$out" "docs/a.md:2:" "match printed as file:line"
assert_fails '[[ "$out" == *b.sh* ]]' "clean file not listed"

# Matching ignores case: a username can appear as Jdoe or JDOE.
printf 'client: ACME-Widgets\n' > "$tree/c.txt"
out=$(bash "$scan" "$tree" "$pats" 2>&1)
assert_contains "$out" "c.txt:1:" "case-insensitive match"

# A clean tree: exit 0. The blank line in the pattern file must not match
# everything, and the comment line is not a pattern.
clean="$tmp/clean"
mkdir -p "$clean/sub"
printf 'private strings, one per line\nplain text\n' > "$clean/sub/x.md"
out=$(bash "$scan" "$clean" "$pats" 2>&1); rc=$?
assert_eq 0 "$rc" "clean tree exits 0"
assert_fails '[[ "$out" == *x.md* ]]' "nothing listed for a clean tree"

# A scan that checked nothing must never read as clean.
printf '# only a comment\n\n' > "$tmp/empty.txt"
bash "$scan" "$clean" "$tmp/empty.txt" >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "pattern file without patterns exits 2"
bash "$scan" "$clean" "$tmp/missing.txt" >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "missing pattern file exits 2"
bash "$scan" "$tmp/nope" "$pats" >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "missing tree exits 2"

# A private string in a file or directory name, or in a symlink target,
# leaks just as much as one in the contents.
names="$tmp/names"
mkdir -p "$names/acme-widgets-notes"
printf 'plain\n' > "$names/acme-widgets-notes/readme.md"
printf 'plain\n' > "$names/report-ACME-WIDGETS.txt"
ln -s /home/jdoe/secret "$names/link"
out=$(bash "$scan" "$names" "$pats" 2>&1); rc=$?
assert_eq 1 "$rc" "name-only match exits 1"
assert_contains "$out" "path: acme-widgets-notes" "directory name reported"
assert_contains "$out" "path: report-ACME-WIDGETS.txt" "file name reported case-insensitively"
assert_contains "$out" "symlink: link -> /home/jdoe/secret" "symlink target reported"

# A byte that is not valid UTF-8 (cp1252 text from a Windows editor) next to
# a hit, in a content line, a file name or a symlink target. Under a UTF-8
# locale grep called the stream binary and dropped the line, bash `read`
# lost a target ending in one, and the scan printed "clean" with exit 0.
bytes="$tmp/bytes"
mkdir -p "$bytes"
printf 'client acme-widgets caf\xe9\n' > "$bytes/notes.txt"
printf 'plain\n' > "$bytes/acme-widgets-caf\xe9.txt"
ln -s "/home/jdoe/caf\xe9" "$bytes/link-mid"
ln -s "/home/jdoe/x\xe9" "$bytes/link-end"
for loc in C.UTF-8 C; do
  out=$(LC_ALL=$loc bash "$scan" "$bytes" "$pats" 2>&1); rc=$?
  assert_eq 1 "$rc" "invalid bytes: match exits 1 under $loc"
  assert_contains "$out" "notes.txt:1:" "invalid bytes: content hit listed under $loc"
  assert_contains "$out" "path: acme-widgets-caf" "invalid bytes: file name hit listed under $loc"
  assert_contains "$out" "symlink: link-mid -> " "invalid bytes: symlink target hit listed under $loc"
  assert_contains "$out" "symlink: link-end -> " "invalid bytes: symlink target ending in one listed under $loc"
  assert_eq 4 "$(printf '%s\n' "$out" | grep -ac 'notes.txt:1:\|^path: \|^symlink: ')" "invalid bytes: all four hits listed under $loc"
done
assert_fails '[[ "$out" == *"path: link"* ]]' "symlink with a clean name not listed as a path"

# Pattern lines are trimmed: a trailing space must not hide a match, and a
# whitespace-only line is blank, not a pattern that matches every line.
printf '  acme-widgets \t\r\n' > "$tmp/padded.txt"
out=$(bash "$scan" "$tree" "$tmp/padded.txt" 2>&1); rc=$?
assert_eq 1 "$rc" "padded pattern still matches"
assert_contains "$out" "c.txt:1:" "padded pattern trimmed before matching"
printf '   \t\r\n# note\n' > "$tmp/spaces.txt"
bash "$scan" "$clean" "$tmp/spaces.txt" >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "whitespace-only pattern file exits 2"

# A failed find or grep in the path or symlink pass leaves names unscanned:
# that is exit 2, never "clean". Each fake breaks one call and passes every
# other through to the real tool, so the earlier passes still run for real.
ftree="$tmp/ftree"
mkdir -p "$ftree"
printf 'nothing here\n' > "$ftree/a.txt"
ln -s a.txt "$ftree/link"
real_find=$(command -v find) real_grep=$(command -v grep)
mkdir -p "$tmp/fbin"
fake() {  # fake <tool> <real path> <case pattern on "$*"> breaks the matching call
  printf '#!/bin/bash\ncase " $* " in %s) exit 2 ;; esac\nexec %s "$@"\n' "$3" "$2" > "$tmp/fbin/$1"
  chmod +x "$tmp/fbin/$1"
}
scan_broken() {  # scan_broken <label>: the scan must exit 2 and never say clean
  local out rc
  out=$(PATH="$tmp/fbin:$PATH" bash "$scan" "$ftree" "$pats" 2>&1); rc=$?
  rm -f "$tmp/fbin/"*
  assert_eq 2 "$rc" "$1 exits 2"
  assert_fails '[[ "$out" == *"scan: clean"* ]]' "$1 never reports clean"
}
bash "$scan" "$ftree" "$pats" >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "the fixture tree is clean without fakes"
fake find "$real_find" '*" -mindepth "*'; scan_broken "failed find listing paths"
fake find "$real_find" '*" -type l "*'; scan_broken "failed find listing symlinks"
fake grep "$real_grep" '" -aiF -f "*'; scan_broken "failed grep matching paths"
fake grep "$real_grep" '" -qaiF -f "*'; scan_broken "failed grep matching symlink targets"

echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
