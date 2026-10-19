#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./assert.sh
. ../wsl/lib/common.sh

TMP=$(mktemp -d)
# Undo any chmod 000 fixtures before rm -rf, so cleanup can never fail.
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

assert_eq "1.0K" "$(human 1024)" "human 1024"
assert_eq "0" "$(dir_bytes "$TMP/nope")" "dir_bytes on missing path"

mkdir -p "$TMP/data"
head -c 4096 /dev/zero > "$TMP/data/f"
[ "$(dir_bytes "$TMP/data")" -ge 4096 ] \
  && ASSERT_PASS=$((ASSERT_PASS + 1)) \
  || { ASSERT_FAIL=$((ASSERT_FAIL + 1)); echo "  FAIL dir_bytes counted $(dir_bytes "$TMP/data")" >&2; }

# Regression: du's pipeline can exit non-zero on a permission-denied
# subdirectory while still printing a partial total on stdout. Under
# pipefail that used to also trigger a stale `|| echo 0` fallback,
# producing two lines instead of one. dir_bytes must emit exactly one
# numeric line no matter what du's exit status was.
mkdir -p "$TMP/dbperm/sub"
head -c 2048 /dev/zero > "$TMP/dbperm/sub/f"
chmod 000 "$TMP/dbperm/sub"
db_out=$(dir_bytes "$TMP/dbperm")
case "$db_out" in
  ''|*[!0-9]*)
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "  FAIL dir_bytes under permission-denied subdir: expected a single integer, got [$db_out]" >&2
    ;;
  *)
    ASSERT_PASS=$((ASSERT_PASS + 1))
    ;;
esac
chmod 755 "$TMP/dbperm/sub"

assert_ok "is_protected \"$HOME/.ssh\"" "ssh is protected"
assert_ok "is_protected \"$HOME/.ssh/id_rsa\"" "under ssh is protected"

# Memory-dir protection must hold via glob matching at call time, not by
# accident of whatever project directories happen to exist on this host.
# Use a project name guaranteed not to exist, and prove it doesn't, so the
# assertions below cannot be passing just because a real dir was found.
FAKE_PROJECT="wsl-maint-fixture-$$-$RANDOM"
assert_fails "[ -e \"$HOME/.claude/projects/$FAKE_PROJECT\" ]" "fixture project dir does not exist (test is hermetic)"
assert_ok "is_protected \"$HOME/.claude/projects/$FAKE_PROJECT/memory\"" "memory is protected"
assert_ok "is_protected \"$HOME/.claude/projects/$FAKE_PROJECT/memory/x.md\"" "under memory is protected"
assert_fails "is_protected \"$HOME/.claude/projects/$FAKE_PROJECT/memory-backup\"" "memory-like sibling not protected (no widening)"
assert_fails "is_protected \"$HOME/.cache/puppeteer\"" "puppeteer not protected"

# Ancestor guard: a target that CONTAINS a protected path must be refused too,
# not just a target that is one or sits beneath one. `--rules` accepts any file,
# so a one-line rules file of "/home purge - yes" resolves to $HOME and would
# otherwise take ~/.ssh, ~/work and ~/tools with it.
assert_ok "is_protected \"$HOME\"" "\$HOME is protected (ancestor of ~/.ssh etc)"
assert_ok "is_protected \"$HOME/.claude\"" "~/.claude is protected (ancestor of the memory pattern)"
# Every single-letter drvfs mount is a Windows drive, not just C: and D:.
assert_ok "is_protected /mnt/e/x" "a path on drive E: is protected"
assert_ok "is_protected /mnt/z" "drive Z: itself is protected (need not be mounted)"
assert_ok "is_protected /mnt/c/Users" "drive C: is still protected"
assert_ok "is_protected /mnt" "/mnt is protected (ancestor of the drives)"
# /mnt/wsl is WSL's own shared tmpfs, not a Windows drive: deliberately left
# unprotected, as it was before drives were matched by pattern.
assert_fails "is_protected /mnt/wsl" "/mnt/wsl is not protected (unchanged)"
assert_fails "is_protected /mnt/wslg/x" "/mnt/wslg is not protected (unchanged)"
assert_ok "is_protected //mnt//e/../d/x" "a drive path is protected after normalization"
assert_fails "is_protected /mnt/ab" "a two-letter /mnt entry is not a drive"
# Drives are a fixed case check, not a glob entry: a glob in PROTECTED_PATTERNS
# is expanded by the ancestor loop, i.e. a readdir of /mnt on every call.
drive_globs=0
for p in "${PROTECTED_PATTERNS[@]}"; do
  case "$p" in /mnt/*) drive_globs=$((drive_globs + 1)) ;; esac
done
assert_eq 0 "$drive_globs" "no /mnt entry in PROTECTED_PATTERNS (drives checked without readdir)"
# The ancestor rule must not widen into unrelated siblings: a directory that
# merely shares a prefix with a protected path is not an ancestor of one. Use
# names guaranteed not to exist so this cannot pass by accident of the host.
assert_fails "is_protected \"$HOME/.ssh-fixture-$$-$RANDOM\"" "prefix-sharing sibling of ~/.ssh not protected"
assert_fails "is_protected \"/var/log/journal\"" "rules.conf journal target still deletable"
assert_fails "is_protected \"$HOME/.claude/projects/$FAKE_PROJECT/foo.jsonl\"" "session file not protected"

# Ancestor guard, GLOBBED patterns. The literal-pattern branch matches the
# pattern as a case SUBJECT, where its "*" is a literal character: it therefore
# cannot see that ~/.claude/projects/<proj> is the parent of a real
# ~/.claude/projects/<proj>/memory, and used to report that parent deletable
# even though rm -rf on it destroys the protected memory dir. is_protected
# closes that by expanding the pattern against the filesystem.
#
# Hermetic: a fixture pattern is appended to PROTECTED_PATTERNS and matched
# against dirs created under $TMP, so nothing here depends on which real
# ~/.claude/projects/*/memory dirs exist on this host.
mkdir -p "$TMP/glob/projects/with-mem/memory"
mkdir -p "$TMP/glob/projects/without-mem"
PROTECTED_PATTERNS+=("$TMP/glob/projects/*/memory")
assert_ok "is_protected \"$TMP/glob/projects/with-mem/memory\"" "globbed pattern still protects its own match"
assert_ok "is_protected \"$TMP/glob/projects/with-mem/memory/x.md\"" "globbed pattern still protects beneath its match"
assert_ok "is_protected \"$TMP/glob/projects/with-mem\"" "parent of an EXISTING globbed match is refused"
assert_ok "is_protected \"$TMP/glob/projects\"" "grandparent of an existing globbed match is refused"
# ...and no wider than the data justifies: a project dir with no memory/ inside
# has nothing protected to lose, so `--sessions` + an auto=no rule can still
# prune it. Widening this to the pattern's whole literal prefix would refuse
# every target under ~/.claude/projects and disable that documented flag.
assert_fails "is_protected \"$TMP/glob/projects/without-mem\"" "sibling project with no memory/ stays deletable (--sessions)"
assert_fails "is_protected \"$TMP/glob/projects-other\"" "prefix-sharing sibling of the glob root not protected"
# A glob root with NO match anywhere under it protects only the ancestors of
# its own literal text (~/.claude, ~/.claude/projects -- that is the older
# literal-ancestor branch, asserted above); everything one level further down
# stays deletable. This is the assertion that distinguishes expanding the
# pattern from refusing its whole literal prefix. Separate fixture root so it
# cannot be answered by the matching fixture above.
#
# Note on `[ -e ]`: with nullglob off an unmatched pattern expands to itself,
# and that test discards it. It is belt-and-braces rather than load-bearing --
# without it the glob branch would just re-run the same comparison the literal
# branch already did -- so no assertion here can isolate it.
mkdir -p "$TMP/glob2/projects"
PROTECTED_PATTERNS+=("$TMP/glob2/projects/*/memory")
assert_ok "is_protected \"$TMP/glob2/projects\"" "the glob root is still refused (literal-ancestor branch)"
assert_fails "is_protected \"$TMP/glob2/projects/some-proj\"" "no match under the glob root at all: still deletable"
assert_fails "is_protected \"/var/log/journal\"" "journal target still deletable after glob expansion"

# A dangling memory/ symlink: `-e` follows the link and fails, so the parent
# used to be reported deletable. A link that exists at all counts.
mkdir -p "$TMP/glob3/projects/linked"
ln -s "$TMP/glob3/nowhere" "$TMP/glob3/projects/linked/memory"
PROTECTED_PATTERNS+=("$TMP/glob3/projects/*/memory")
assert_ok "is_protected \"$TMP/glob3/projects/linked\"" "parent of a dangling memory/ symlink is refused"

# String-shaped walks around the guard: repeated slashes and `..` segments.
# is_protected normalizes lexically (no symlink resolution), so these are
# compared as the paths they spell.
assert_ok "is_protected //" "// is refused like /"
assert_ok "is_protected ///" "/// is refused like /"
assert_ok "is_protected \"$HOME/../$(basename "$HOME")/.ssh\"" "\$HOME/../<user>/.ssh is protected"
assert_ok "is_protected \"$HOME//.ssh\"" "\$HOME//.ssh is protected"
assert_ok "is_protected \"$HOME/.ssh/.\"" "\$HOME/.ssh/. is protected"
assert_ok "is_protected \"$HOME/.cache/../.ssh/\"" "\$HOME/.cache/../.ssh/ is protected"
assert_ok "is_protected \"$HOME/..\"" "parent of \$HOME is refused (ancestor)"
assert_ok "is_protected /.." "/.. is refused like /"
assert_fails "is_protected \"$HOME/.cache/x/../puppeteer\"" "normalization does not over-protect"

# The catastrophic case, with `rm` shadowed exactly as the \$HOME test below
# does it: a regression must report RM-WOULD-HAVE-RUN, never delete the
# fixture. DRY_RUN is pinned to 0 inside the subshell so nothing else is
# holding rm back.
glob_rm_out=$(
  DRY_RUN=0
  rm() { echo "RM-WOULD-HAVE-RUN $*"; }
  safe_rm "$TMP/glob/projects/with-mem" 2>&1
  echo "exit=$?"
)
assert_contains "$glob_rm_out" "refusing to delete protected path" "safe_rm refuses the parent of a globbed match"
assert_fails "case \"\$glob_rm_out\" in *RM-WOULD-HAVE-RUN*) true ;; *) false ;; esac" \
  "safe_rm never reached rm for the parent of a globbed match"
assert_ok "[ -d \"$TMP/glob/projects/with-mem/memory\" ]" "the fixture memory dir survived"

# safe_rm honours DRY_RUN
mkdir -p "$TMP/victim"
DRY_RUN=1
out=$(safe_rm "$TMP/victim")
assert_contains "$out" "DRY" "dry-run prints DRY"
assert_ok "[ -d \"$TMP/victim\" ]" "dry-run leaves path"

DRY_RUN=0
out=$(safe_rm "$TMP/victim")
assert_contains "$out" "RM" "real run prints RM"
assert_fails "[ -d \"$TMP/victim\" ]" "real run removes path"

# safe_rm fails when rm only gets part of the target. Regression: an
# unconditional `echo "RM"` after `rm -rf` made the echo's status the
# function's, so a half-deleted target logged RM and returned 0.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMP/half/locked"
  : > "$TMP/half/locked/stuck"
  : > "$TMP/half/loose"
  chmod a-w "$TMP/half/locked"
  DRY_RUN=0
  half_out=$(safe_rm "$TMP/half" 2>&1; echo "exit=$?")
  chmod u+w "$TMP/half/locked"
  assert_contains "$half_out" "exit=1" "safe_rm returns non-zero when rm leaves part of the target"
  assert_fails "printf '%s' \"\$half_out\" | grep -q '^RM '" "safe_rm prints no RM line for a half-deleted target"
  assert_contains "$half_out" "could not fully delete" "safe_rm says the target was only partly deleted"
  rm -rf "$TMP/half"
fi

# safe_rm refuses a relative target: it would resolve against the cwd, and
# maint runs from ~ or /mnt/c/WINDOWS/system32. Run from inside a dir holding
# the name, with rm shadowed, so a regression cannot delete anything.
mkdir -p "$TMP/relcwd/victim"
for rel in victim ./victim "" ; do
  rel_out=$(
    cd "$TMP/relcwd" || exit 9
    DRY_RUN=0
    rm() { echo "RM-WOULD-HAVE-RUN $*"; }
    safe_rm "$rel" 2>&1
    echo "exit=$?"
  )
  assert_contains "$rel_out" "refusing to delete non-absolute path" "safe_rm refuses relative [$rel]"
  assert_contains "$rel_out" "exit=1" "safe_rm returns non-zero for relative [$rel]"
  assert_fails "case \"\$rel_out\" in *RM-WOULD-HAVE-RUN*) true ;; *) false ;; esac" \
    "safe_rm never reached rm for relative [$rel]"
done
assert_ok "[ -d \"$TMP/relcwd/victim\" ]" "the cwd-relative fixture survived"

# safe_rm refuses protected paths even when DRY_RUN=0. This targets the REAL
# ~/.ssh, so `rm` is shadowed with a recorder inside the subshell (same pattern
# as the $HOME case below): a regressed guard reports RM-WOULD-HAVE-RUN instead
# of deleting the keys.
ssh_rm_out=$(
  rm() { echo "RM-WOULD-HAVE-RUN $*"; }
  safe_rm "$HOME/.ssh" 2>&1
  echo "exit=$?"
)
assert_contains "$ssh_rm_out" "refusing to delete protected path" "safe_rm refuses .ssh"
assert_contains "$ssh_rm_out" "exit=1" "safe_rm returns non-zero for .ssh"
assert_fails "case \"\$ssh_rm_out\" in *RM-WOULD-HAVE-RUN*) true ;; *) false ;; esac" \
  "safe_rm never reached rm for .ssh"

# safe_rm must also refuse $HOME itself -- the ancestor case a hand-written
# --rules file can produce ("/home purge - yes" -> target $HOME). Unlike the
# assertions above, a regression here would be catastrophic rather than merely
# red, so `rm` is shadowed with a recorder inside this subshell: if the guard
# ever stops firing, the test reports RM-WOULD-HAVE-RUN instead of deleting the
# home directory. DRY_RUN is still 0 here, so nothing else is holding rm back.
home_rm_out=$(
  rm() { echo "RM-WOULD-HAVE-RUN $*"; }
  safe_rm "$HOME" 2>&1
  echo "exit=$?"
)
assert_contains "$home_rm_out" "refusing to delete protected path" "safe_rm refuses \$HOME"
assert_contains "$home_rm_out" "exit=1" "safe_rm returns non-zero for \$HOME"
assert_fails "case \"\$home_rm_out\" in *RM-WOULD-HAVE-RUN*) true ;; *) false ;; esac" \
  "safe_rm never reached rm for \$HOME"
if [ -d "$HOME/.ssh" ]; then
  assert_ok "[ -d \"$HOME/.ssh\" ]" "ssh untouched"
else
  # No ~/.ssh on this machine to verify against; use a temporary
  # protected-path fixture so this assertion is still capable of failing.
  mkdir -p "$TMP/ssh_fixture"
  PROTECTED_PATTERNS+=("$TMP/ssh_fixture")
  safe_rm "$TMP/ssh_fixture" >/dev/null 2>&1
  assert_ok "[ -d \"$TMP/ssh_fixture\" ]" "ssh-fixture untouched"
fi

# is_consent: the same rule as win\Common.ps1 Test-MaintConsent.
for a in y Y yes YES Yes " y" "yes " $'\ty'; do
  assert_ok "is_consent \"$a\"" "is_consent accepts '$a'"
done
for a in "" " " n N no nope yeah sure 1 "y y" yess; do
  assert_fails "is_consent \"$a\"" "is_consent refuses '$a'"
done
assert_fails "is_consent" "is_consent refuses a missing answer"


# --- the protected list survives a non-canonical HOME ---
# Regression: the patterns were built from the raw $HOME while only the
# target was normalised, so HOME=/home/u/ gave `/home/u//.ssh` and
# `~/.ssh purge` was allowed through. Re-sourced in a subshell so the odd
# HOME never leaks into the rest of this file.
mkdir -p "$TMP/hs/.ssh"
for h in "$TMP/hs/" "$TMP//hs" "$TMP/hs/."; do
  assert_ok "HOME=\"$h\" bash -c 'source ../wsl/lib/common.sh; is_protected \"\$HOME/.ssh/id_rsa\"'" \
    "~/.ssh is protected with HOME=$h"
  assert_ok "HOME=\"$h\" bash -c 'source ../wsl/lib/common.sh; is_protected \"\$HOME/.config/x\"'" \
    "~/.config is protected with HOME=$h"
done
assert_ok "HOME=/ bash -c 'source ../wsl/lib/common.sh; is_protected /.ssh/id_rsa'" "HOME=/ protects /.ssh"


# --- safe_rm never deletes through a mount point ---
# Regression: `rm -rf` does not stop at a mount, so a purge/keep-newest target
# that was, or held, a mount of another filesystem was emptied, while the
# estimate (du -x) had counted none of it. Needs an unprivileged mount
# (unshare -rm); skipped where that is denied.
mkdir -p "$TMP/mnt-probe"
if unshare -rm mount -t tmpfs t "$TMP/mnt-probe" 2>/dev/null; then
  mkdir -p "$TMP/srm/self" "$TMP/srm/nested/m" "$TMP/srm/link-target"
  out=$(unshare -rm bash -c '
    . ../wsl/lib/common.sh
    r="$1"
    mount -t tmpfs t "$r/self" || exit 9
    mount -t tmpfs t "$r/nested/m" || exit 9
    mount -t tmpfs t "$r/link-target" || exit 9
    head -c 4096 /dev/zero > "$r/self/big"
    head -c 4096 /dev/zero > "$r/nested/m/big"
    head -c 16 /dev/zero > "$r/nested/own"
    head -c 4096 /dev/zero > "$r/link-target/big"
    ln -s "$r/link-target" "$r/lnk"
    DRY_RUN=1 safe_rm "$r/self" >"$r/self.dry" 2>"$r/self.dry.err"; echo "dry-self=$?"
    [ -f "$r/self/big" ] && echo "dry-self-kept"
    DRY_RUN=0 safe_rm "$r/self" >"$r/self.out" 2>"$r/self.err"; echo "self=$?"
    [ -f "$r/self/big" ] && echo "self-kept"
    DRY_RUN=0 safe_rm "$r/nested" >"$r/nested.out" 2>"$r/nested.err"; echo "nested=$?"
    [ -f "$r/nested/m/big" ] && echo "nested-kept"
    [ -e "$r/nested/own" ] || echo "nested-own-gone"
    DRY_RUN=0 safe_rm "$r/lnk" >"$r/lnk.out" 2>"$r/lnk.err"; echo "lnk=$?"
    [ -L "$r/lnk" ] || echo "lnk-gone"
    [ -f "$r/link-target/big" ] && echo "lnk-target-kept"
    exit 0' _ "$TMP/srm")
  assert_contains "$out" "dry-self=1" "safe_rm: a dry run refuses a mount point target"
  assert_contains "$(cat "$TMP/srm/self.dry.err")" "refusing to delete mount point" "safe_rm: the dry-run refusal names the mount"
  assert_fails "grep -q '^DRY' \"$TMP/srm/self.dry\"" "safe_rm: a dry run announces nothing for a mount point"
  assert_contains "$out" "self=1" "safe_rm: a mount point target fails"
  assert_contains "$out" "self-kept" "safe_rm: nothing under a mount point target is deleted"
  assert_contains "$(cat "$TMP/srm/self.err")" "refusing to delete mount point" "safe_rm: the refusal names the mount"
  assert_contains "$out" "nested=1" "safe_rm: a target holding a mount fails"
  assert_contains "$out" "nested-kept" "safe_rm: nothing under a nested mount is deleted"
  assert_contains "$out" "nested-own-gone" "safe_rm: the target's own files still go"
  assert_contains "$(cat "$TMP/srm/nested.err")" "could not fully delete" "safe_rm: the leftover mount is reported"
  assert_fails "grep -q '^RM' \"$TMP/srm/nested.out\"" "safe_rm: a half-deleted target is not logged as RM"
  assert_contains "$out" "lnk=0" "safe_rm: a symlink entry to a mount is removed as a link"
  assert_contains "$out" "lnk-gone" "safe_rm: the link itself is gone"
  assert_contains "$out" "lnk-target-kept" "safe_rm: the link's mounted target is intact"
fi

echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
