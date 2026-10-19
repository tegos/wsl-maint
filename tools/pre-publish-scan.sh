#!/usr/bin/env bash
# Pre-publish scan: list every line in a tree that contains a private string.
#
# Usage: tools/pre-publish-scan.sh <tree> <pattern-file>
#
# <tree>          the tree about to be published, e.g. a `git archive` export
# <pattern-file>  one string per line (client names, home paths, usernames,
#                 vault paths). Matched literally and case-insensitively.
#                 Blank lines and lines starting with # are ignored. Keep it
#                 OUTSIDE the repo: it holds the very strings being hunted.
#
#                 Leading/trailing whitespace on a line is trimmed.
#
# Prints file:line:text for each content match, "path: <path>" for a file or
# directory whose path matches, and "symlink: <path> -> <target>" for a
# symlink whose target matches. Paths are relative to <tree>.
# Exit: 0 clean, 1 at least one match, 2 error: a bad argument, a pattern
# file with no patterns, or a failed find or grep. Each of those would
# otherwise leave part of the tree unscanned and read as clean.
set -uo pipefail
# Byte-wise matching everywhere. Under a UTF-8 locale (WSL's default) grep
# treats input holding an invalid byte (a cp1252 "é" from a Windows editor)
# as binary and drops the matching line while still exiting 0, and bash
# `read` loses a line that ends in one; a real hit then read as clean. -i
# therefore folds ASCII letters only.
export LC_ALL=C

usage() { echo "usage: $0 <tree> <pattern-file>" >&2; exit 2; }
fail() { echo "pre-publish-scan: $1" >&2; exit 2; }

[ $# -eq 2 ] || usage
tree=$1 pats=$2
[ -d "$tree" ] || fail "not a directory: $tree"
[ -f "$pats" ] && [ -r "$pats" ] || fail "cannot read pattern file: $pats"

# Strip a CR (a pattern file edited on Windows), trim surrounding whitespace,
# then drop comments and blank lines. A blank pattern would match every line,
# so it must never reach grep.
clean=$(mktemp) || exit 2
trap 'rm -f "$clean"' EXIT
tr -d '\r' < "$pats" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v -e '^#' -e '^$' > "$clean"
[ -s "$clean" ] || fail "no patterns in $pats"

# -a: a binary file is scanned as text, so a match there is still listed
# with its line number instead of a bare "Binary file matches".
cd "$tree" || exit 2
out=$(grep -rnaiF --exclude-dir=.git -f "$clean" . 2>/dev/null)
rc=$?
[ "$rc" -gt 1 ] && fail "grep failed (exit $rc)"
out=$(printf '%s' "$out" | sed 's|^\./||')

# Names leak too: match every path (relative to <tree>) and every symlink
# target. grep -r does not follow symlinks, so a target is never read above.
tree_paths=$(find . -mindepth 1 -name .git -prune -o -printf '%P\n') || fail "find failed listing paths"
paths=$(printf '%s\n' "$tree_paths" | grep -aiF -f "$clean")
[ $? -gt 1 ] && fail "grep failed matching paths"
paths=$(printf '%s' "$paths" | sed 's|^|path: |')
symlinks=$(find . -name .git -prune -o -type l -printf '%P\t%l\n') || fail "find failed listing symlinks"
links=""
while IFS=$'\t' read -r p t; do
  [ -n "$p" ] || continue
  printf '%s\n' "$t" | grep -qaiF -f "$clean"
  case $? in
    0) links+="symlink: $p -> $t"$'\n' ;;
    1) ;;
    *) fail "grep failed matching symlink targets" ;;
  esac
done <<< "$symlinks"

# -a here too: this filter re-reads the hits, and an invalid byte in one of
# them made grep call the whole stream binary and print nothing.
hits=$(printf '%s\n' "$out" "$paths" "$links" | grep -av '^$')
if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  echo "pre-publish-scan: $(printf '%s\n' "$hits" | wc -l) match(es), do not publish" >&2
  exit 1
fi
echo "pre-publish-scan: clean"
exit 0
