#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./assert.sh
. ../wsl/lib/common.sh
. ../wsl/lib/rules.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- parser ---
cat > "$TMP/rules.conf" <<'EOF'
# comment line

~/.cache/demo                 purge         -      yes
/var/log/journal              vacuum        100M   yes
~/.claude/projects            age           45d    no
EOF

parsed=$(rules_parse "$TMP/rules.conf")
assert_eq "3" "$(echo "$parsed" | wc -l)" "three rules parsed"
assert_contains "$parsed" "$HOME/.cache/demo|purge|-|yes" "tilde expanded"
assert_contains "$parsed" "/var/log/journal|vacuum|100M|yes" "vacuum row"
assert_contains "$parsed" "$HOME/.claude/projects|age|45d|no" "auto=no preserved"

# --- parser: a path may contain spaces ---
# Regression: the parser used awk's `NF >= 4`, which field-splits, so
# "/some path purge - yes" bound policy="path" and the line was dropped
# without a word. The last three fields are policy/arg/auto; everything
# before them is the path.
cat > "$TMP/spaced.conf" <<'EOF'
/tmp/has space/cache          purge         -      yes
EOF
parsed=$(rules_parse "$TMP/spaced.conf")
assert_eq "/tmp/has space/cache|purge|-|yes" "$parsed" "a path with a space keeps its columns"

# --- parser: errors must reach the caller ---
# Regression: every one of these exited 0, because the only call sites read the
# parser through `done < <(rules_parse ...)`, where the exit status is invisible
# to both the caller and set -e. A typo'd --rules path then made `maint clean` a
# silent no-op that reported success across the WSL/Windows boundary.
assert_fails "rules_parse \"$TMP/does-not-exist.conf\" 2>/dev/null" "missing rules file fails"

printf '/tmp/x purge\n' > "$TMP/short.conf"
assert_fails "rules_parse \"$TMP/short.conf\" 2>/dev/null" "a line with fewer than four fields fails"
err=$(rules_parse "$TMP/short.conf" 2>&1 >/dev/null)
assert_contains "$err" "malformed rule" "the malformed line is named, not skipped silently"

printf '/tmp/x frobnicate - yes\n' > "$TMP/bad-policy.conf"
assert_fails "rules_parse \"$TMP/bad-policy.conf\" 2>/dev/null" "an unknown policy fails"

# "|" is the parser's own output delimiter, so a path carrying one would be
# re-split into different fields by every caller's `IFS='|' read`.
printf '/tmp/a|b purge - yes\n' > "$TMP/pipe.conf"
assert_fails "rules_parse \"$TMP/pipe.conf\" 2>/dev/null" "a path containing | is refused"

# A valid rule on a file with no trailing newline must still be read.
printf '/tmp/x purge - yes' > "$TMP/no-newline.conf"
assert_eq "/tmp/x|purge|-|yes" "$(rules_parse "$TMP/no-newline.conf")" "last line without a trailing newline is read"

# A UTF-8 BOM (Notepad, PS 5.1 Out-File -Encoding UTF8) is not part of the
# first rule's path, and not a malformed rule in front of a first-line comment.
printf '\xef\xbb\xbf~/x purge - yes\n' > "$TMP/bom.conf"
assert_eq "$HOME/x|purge|-|yes" "$(rules_parse "$TMP/bom.conf" 2>/dev/null)" "a BOM before the first rule is dropped"
printf '\xef\xbb\xbf# comment\r\n~/x purge - yes\r\n' > "$TMP/bom2.conf"
assert_eq "$HOME/x|purge|-|yes" "$(rules_parse "$TMP/bom2.conf" 2>/dev/null)" "a BOM before a first-line comment is not a rule"

# --- parser: policy args are validated ---
# Regression: the arg passed unchecked. `age` strips one lowercase `d` and awk
# compared the rest as text, so `age 30D` / `age 1w` deleted 5-day-old entries
# and `age -` deleted fresh ones; `keep-newest -1` became `tail -n +0` and
# deleted every entry; `vacuum` handed anything to journalctl.
for bad in "age 30D" "age 30days" "age 1w" "age -" "age d" "keep-newest -1" \
           "keep-newest 0" "keep-newest 08" "keep-newest 1d" "keep-newest -" \
           "vacuum abc" "vacuum 100m" "vacuum 0" "vacuum -" "vacuum 1.5G"; do
  printf '/tmp/x %s yes\n' "$bad" > "$TMP/bad-arg.conf"
  assert_fails "rules_parse \"$TMP/bad-arg.conf\" >/dev/null 2>&1" "bad arg refused: $bad"
done
printf '/tmp/x age 1w yes\n' > "$TMP/bad-arg.conf"
assert_contains "$(rules_parse "$TMP/bad-arg.conf" 2>&1 >/dev/null)" "/tmp/x age 1w yes" \
  "a bad arg names the rule line"
printf '/tmp/x age 1w yes\n/tmp/y purge - yes\n' > "$TMP/bad-arg.conf"
assert_eq "/tmp/y|purge|-|yes" "$(rules_parse "$TMP/bad-arg.conf" 2>/dev/null)" \
  "a bad-arg line is dropped, not passed on"
# The auto column is a two-valued switch (rules.conf:3). Anything else used to
# parse and read as "no": the rule never ran on plain `maint clean`, which
# exited 0 and recorded lastrun as if it had.
for bad in Yes YES true y 1 -; do
  printf '/tmp/x purge - %s\n' "$bad" > "$TMP/bad-auto.conf"
  assert_fails "rules_parse \"$TMP/bad-auto.conf\" >/dev/null 2>&1" "bad auto refused: $bad"
done
assert_contains "$(rules_parse "$TMP/bad-auto.conf" 2>&1 >/dev/null)" "auto must be yes or no, got '-'" \
  "a bad auto names the token"
printf '/tmp/x purge yes -\n' > "$TMP/bad-auto.conf"
assert_fails "rules_parse \"$TMP/bad-auto.conf\" >/dev/null 2>&1" "swapped arg/auto refused"
for good in "age 30" "age 30d" "age 0d" "age 045d" "keep-newest 1" "keep-newest 10" \
            "vacuum 100M" "vacuum 1G" "vacuum 512K" "vacuum 1T" "vacuum 4096" \
            "purge -" "pw-orphan -"; do
  printf '/tmp/x %s yes\n' "$good" > "$TMP/good-arg.conf"
  assert_eq "/tmp/x|${good% *}|${good#* }|yes" "$(rules_parse "$TMP/good-arg.conf" 2>/dev/null)" \
    "good arg accepted: $good"
done

# --- shipped rules.conf: state-holding caches are opt-in ---
# Regression: these ran on plain `maint clean` (auto=yes) and hold state that a
# stranger cannot get back: per-project MCP browser profiles (cookies, logins),
# user-supplied EasyOCR models, the Hugging Face token, pinned puppeteer
# browsers, an owner-only tool's cache. They must need --all. The
# Playwright cache joins them: a project outside the scan roots looks unpinned.
# Under a fixture HOME: on the real one a cache dir that is a symlink would
# be resolved to its target and the rows below would not match by name.
SHIPPED_HOME="$TMP/shipped-home"; mkdir -p "$SHIPPED_HOME"
assert_ok "HOME=\"$SHIPPED_HOME\" rules_parse ../rules.conf >/dev/null 2>&1" "shipped rules.conf parses cleanly"
shipped=$(HOME="$SHIPPED_HOME" rules_parse ../rules.conf)
for p in .cache/ms-playwright .cache/ms-playwright-mcp .EasyOCR .cache/huggingface .cache/puppeteer .cache/wayback-video; do
  row=$(echo "$shipped" | grep -F "$SHIPPED_HOME/$p|" | head -1)
  assert_eq "no" "${row##*|}" "shipped rules.conf: ~/$p is auto=no"
done

# --- a rule root that is a symlink ---
# Regression: `[ -d ]` follows the link so the rule was accepted, but `find`
# (-P) does not descend a command-line symlink: purge/age/keep-newest listed
# nothing, clean printed "freed: 0.0", exit 0, and recorded a run. The root
# is now resolved once, so the walk and the guard see the real directory.
mkdir -p "$TMP/lnk-real/a" "$TMP/lnk-real/b"
head -c 4096 /dev/zero > "$TMP/lnk-real/a/blob"
ln -s "$TMP/lnk-real" "$TMP/lnk-root"
printf '%s purge - yes\n' "$TMP/lnk-root" > "$TMP/lnk.conf"
assert_eq "$TMP/lnk-real|purge|-|yes" "$(rules_parse "$TMP/lnk.conf" 2>/dev/null)" \
  "a symlinked root is resolved to its target"
assert_contains "$(rules_parse "$TMP/lnk.conf" 2>&1 >/dev/null)" "is a symlink; using $TMP/lnk-real" \
  "a resolved root is announced"
assert_eq "2" "$(rule_targets "$TMP/lnk-real" purge - | wc -l)" "the resolved root is walked"
# Regression: a trailing "/" or "/." made find resolve the link while the
# targets kept the link's spelling (root//name), which the lexical guard then
# let through: `~/.cache/lnk/ purge` with lnk -> ~/.ssh deleted id_rsa.
mkdir -p "$TMP/lnk-prot"; head -c 2048 /dev/zero > "$TMP/lnk-prot/id_rsa"
ln -s "$TMP/lnk-prot" "$TMP/lnk-to-prot"
REAL_PATTERNS=("${PROTECTED_PATTERNS[@]}")
PROTECTED_PATTERNS+=("$TMP/lnk-prot")
for spelling in "$TMP/lnk-to-prot/" "$TMP/lnk-to-prot/."; do
  printf '%s purge - yes\n' "$spelling" > "$TMP/lnk2.conf"
  assert_eq "$TMP/lnk-prot|purge|-|yes" "$(rules_parse "$TMP/lnk2.conf" 2>/dev/null)" \
    "a symlinked root with a trailing slash resolves to its target: $spelling"
  DRY_RUN=1
  out=$(rule_run "$TMP/lnk-prot" purge - 2>"$TMP/lnk2.err"); rc=$?
  assert_eq "1" "$rc" "the resolved protected target fails the rule: $spelling"
  assert_contains "$(cat "$TMP/lnk2.err")" "refusing to delete protected path" "the guard sees the real path: $spelling"
  assert_fails "printf '%s' \"\$out\" | grep -q '^ *DRY'" "nothing under the protected target is announced: $spelling"
done
assert_ok "[ -f \"$TMP/lnk-prot/id_rsa\" ]" "the protected file survived"
# A protected name that is itself a symlink elsewhere stays protected by its
# spelling: resolving it would have made ~/.config deletable through the link.
mkdir -p "$TMP/lnk-elsewhere"; touch "$TMP/lnk-elsewhere/secret"
ln -s "$TMP/lnk-elsewhere" "$TMP/lnk-named-prot"
PROTECTED_PATTERNS+=("$TMP/lnk-named-prot")
printf '%s purge - yes\n' "$TMP/lnk-named-prot" > "$TMP/lnk3.conf"
assert_fails "rules_parse \"$TMP/lnk3.conf\" >/dev/null 2>&1" "a protected symlinked root is refused at parse"
assert_contains "$(rules_parse "$TMP/lnk3.conf" 2>&1 >/dev/null)" "rule path is protected" "the refusal names the reason"
# Regression: only the last segment was checked with `[ -L ]`, so a symlink
# higher up (`~/.cache/lnk/sub` with lnk -> ~/.ssh) left the root unresolved
# and the targets kept the link's spelling: ~/.ssh/sub/id was deleted.
mkdir -p "$TMP/lnk-prot/sub"; head -c 2048 /dev/zero > "$TMP/lnk-prot/sub/id"
printf '%s purge - yes\n' "$TMP/lnk-to-prot/sub" > "$TMP/lnk4.conf"
assert_eq "$TMP/lnk-prot/sub|purge|-|yes" "$(rules_parse "$TMP/lnk4.conf" 2>/dev/null)" \
  "a symlink above the rule root is resolved too"
DRY_RUN=0
out=$(rule_run "$TMP/lnk-prot/sub" purge - 2>"$TMP/lnk4.err"); rc=$?
assert_eq "1" "$rc" "the protected target under a mid-path link fails the rule"
assert_contains "$(cat "$TMP/lnk4.err")" "refusing to delete protected path" "the guard sees the real path"
assert_ok "[ -f \"$TMP/lnk-prot/sub/id\" ]" "the file under the protected dir survived"
DRY_RUN=1
# A root that does not exist is left as written: rule_targets skips it.
printf '%s purge - yes\n' "$TMP/no-such/dir" > "$TMP/lnk5.conf"
assert_eq "$TMP/no-such/dir|purge|-|yes" "$(rules_parse "$TMP/lnk5.conf" 2>/dev/null)" \
  "a missing root parses unchanged"
PROTECTED_PATTERNS=("${REAL_PATTERNS[@]}")
# A symlink inside a rule root is still removed as a link, never followed.

# --- keep-newest ---
mkdir -p "$TMP/kn"
for n in 1 2 3 4; do
  mkdir -p "$TMP/kn/v$n"
  head -c 1024 /dev/zero > "$TMP/kn/v$n/blob"
  touch -d "2026-01-0$n" "$TMP/kn/v$n"
done
targets=$(rule_targets "$TMP/kn" keep-newest 2 | sort)
assert_eq "$TMP/kn/v1
$TMP/kn/v2" "$targets" "keep-newest 2 targets the two oldest"

DRY_RUN=1
rule_run "$TMP/kn" keep-newest 2 >/dev/null
assert_ok "[ -d \"$TMP/kn/v1\" ]" "dry-run keeps oldest"

DRY_RUN=0
rule_run "$TMP/kn" keep-newest 2 >/dev/null
assert_fails "[ -d \"$TMP/kn/v1\" ]" "v1 removed"
assert_fails "[ -d \"$TMP/kn/v2\" ]" "v2 removed"
assert_ok "[ -d \"$TMP/kn/v3\" ]" "v3 kept"
assert_ok "[ -d \"$TMP/kn/v4\" ]" "v4 kept"

# Same newline-name hole as purge: keep-newest printed one path per line, so
# an old $'a\nvictim' entry yielded a bare `victim` relative to the cwd.
mkdir -p "$TMP/kn-nl/p/$(printf 'a\nvictim')" "$TMP/kn-nl/p/old" "$TMP/kn-nl/p/new" "$TMP/kn-nl/victim"
# rule_run skips a rule with nothing to free, so each target carries a byte.
echo x > "$TMP/kn-nl/p/old/blob"
touch -d "2026-01-01" "$TMP/kn-nl/p/$(printf 'a\nvictim')"
touch -d "2026-01-02" "$TMP/kn-nl/p/old"
touch -d "2026-01-03" "$TMP/kn-nl/p/new"
knl_targets=$(cd "$TMP/kn-nl" && rule_targets "$PWD/p" keep-newest 1 2>/dev/null)
assert_eq "$TMP/kn-nl/p/old" "$knl_targets" "keep-newest: an entry whose name has a newline is kept"
assert_contains "$(rule_targets "$TMP/kn-nl/p" keep-newest 1 2>&1 >/dev/null)" "newline" \
  "keep-newest: the kept newline name is reported"
DRY_RUN=0
(cd "$TMP/kn-nl" && rule_run "$PWD/p" keep-newest 1 >/dev/null 2>&1)
assert_ok "[ -d \"$TMP/kn-nl/victim\" ]" "keep-newest: rule_run never deletes a cwd-relative name"
assert_ok "[ -d \"$TMP/kn-nl/p/$(printf 'a\nvictim')\" ]" "keep-newest: the newline-named entry itself is kept"
assert_ok "[ -d \"$TMP/kn-nl/p/new\" ]" "keep-newest: the newest entry is kept"
assert_fails "[ -e \"$TMP/kn-nl/p/old\" ]" "keep-newest: an older plain entry is still removed"

# A name with a space survives the sort/cut round trip intact.
mkdir -p "$TMP/kn-sp/p/has space" "$TMP/kn-sp/p/new"
touch -d "2026-01-01" "$TMP/kn-sp/p/has space"
assert_eq "$TMP/kn-sp/p/has space" "$(rule_targets "$TMP/kn-sp/p" keep-newest 1)" \
  "keep-newest: a name with a space is targeted whole"

# --- age ---
mkdir -p "$TMP/age/old" "$TMP/age/new"
touch -d "2020-01-01" "$TMP/age/old"
targets=$(rule_targets "$TMP/age" age 30d)
assert_eq "$TMP/age/old" "$targets" "age targets only the stale entry"

# An entry is judged by the activity inside it, never by its own directory atime:
# readdir from `du` (what `maint audit` and `maint space` run) refreshes that, so
# the old rule never expired anything on a box audited more often than every N days.
mkdir -p "$TMP/age-du/old/sub"
touch "$TMP/age-du/old/sub/f"
touch -d "90 days ago" "$TMP/age-du/old/sub/f" "$TMP/age-du/old/sub" "$TMP/age-du/old"
du -sxb "$TMP/age-du" >/dev/null
assert_eq "$TMP/age-du/old" "$(rule_targets "$TMP/age-du" age 30d)" \
  "age: a du walk over a stale entry does not keep it"

# The reverse: a file read by path refreshes nothing above it, yet it is in use.
mkdir -p "$TMP/age-read/hub/models"
touch "$TMP/age-read/hub/models/w.bin"
touch -d "90 days ago" "$TMP/age-read/hub/models/w.bin" "$TMP/age-read/hub/models" "$TMP/age-read/hub"
touch -a "$TMP/age-read/hub/models/w.bin"
assert_eq "" "$(rule_targets "$TMP/age-read" age 30d)" \
  "age: a file read recently deep inside keeps the entry"

mkdir -p "$TMP/age-write/e/sub"
touch "$TMP/age-write/e/sub/f"
touch -d "90 days ago" "$TMP/age-write/e/sub/f" "$TMP/age-write/e/sub" "$TMP/age-write/e"
touch -m "$TMP/age-write/e/sub/f"
assert_eq "" "$(rule_targets "$TMP/age-write" age 30d)" \
  "age: a file written recently deep inside keeps the entry"

# Plain files at the root are judged by their own times; an empty directory by
# its mtime.
mkdir -p "$TMP/age-plain/empty"
touch "$TMP/age-plain/old.bin" "$TMP/age-plain/new.bin"
touch -d "90 days ago" "$TMP/age-plain/old.bin" "$TMP/age-plain/empty"
targets=$(rule_targets "$TMP/age-plain" age 30d | sort)
assert_eq "$TMP/age-plain/empty
$TMP/age-plain/old.bin" "$targets" "age: old plain file and old empty dir go, a fresh file stays"

# A symlink counts by its own times and is not followed: a link to a fresh file
# outside the root cannot keep an old entry alive.
mkdir -p "$TMP/age-link/e" "$TMP/age-link-outside"
touch "$TMP/age-link-outside/fresh"
ln -s "$TMP/age-link-outside/fresh" "$TMP/age-link/e/link"
touch -h -d "90 days ago" "$TMP/age-link/e/link"
touch -d "90 days ago" "$TMP/age-link/e"
assert_eq "$TMP/age-link/e" "$(rule_targets "$TMP/age-link" age 30d)" \
  "age: a symlink to a fresh file does not keep an old entry"

# Fail closed: an entry the walk cannot read fully is kept and named on stderr,
# and the rest of the root is still judged. Root reads everything, so skip there.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMP/age-perm/locked/sub" "$TMP/age-perm/open"
  touch -d "90 days ago" "$TMP/age-perm/locked/sub" "$TMP/age-perm/locked" "$TMP/age-perm/open"
  chmod 000 "$TMP/age-perm/locked/sub"
  err=$(rule_targets "$TMP/age-perm" age 30d 2>&1 >/dev/null)
  targets=$(rule_targets "$TMP/age-perm" age 30d 2>/dev/null)
  chmod 755 "$TMP/age-perm/locked/sub"
  assert_eq "$TMP/age-perm/open" "$targets" "age: an entry with an unreadable subdir is kept, the rest judged"
  assert_contains "$err" "$TMP/age-perm/locked" "age: the kept unreadable entry is named in a warning"
fi

# A mount inside an entry: -xdev keeps the walk off it, so its activity is
# unseen, and `rm -rf` would still descend into it. Such an entry is kept.
# Needs an unprivileged mount (unshare -rm); skipped where that is denied.
mkdir -p "$TMP/mnt-probe"
if unshare -rm mount -t tmpfs t "$TMP/mnt-probe" 2>/dev/null; then
  mkdir -p "$TMP/age-mnt/withmount/m" "$TMP/age-mnt/old"
  out=$(unshare -rm bash -c '
    . ../wsl/lib/common.sh; . ../wsl/lib/rules.sh
    r="$1"
    mount -t tmpfs t "$r/withmount/m" || exit 9
    mkdir "$r/withmount/m/sub"; touch "$r/withmount/m/sub/fresh"
    touch -d "90 days ago" "$r/withmount/m" "$r/withmount" "$r/old"
    rule_targets "$r" age 30d 2>"$r.err"' _ "$TMP/age-mnt")
  assert_eq "$TMP/age-mnt/old" "$out" "age: an entry holding a mount is kept, the rest judged"
  assert_contains "$(cat "$TMP/age-mnt.err")" "$TMP/age-mnt/withmount holds a mount" "age: the entry kept for a mount is named in a warning"
fi

# Regression: the tag stream out of the walk was newline-separated, so an entry
# named $'a\nT ..' came out as two records and targeted ROOT/.., and rule_run
# then removed the parent. Such a name is kept with a warning.
nl_root="$TMP/age-nl/parent/root"
mkdir -p "$nl_root/$(printf 'a\nT ..')"
touch "$TMP/age-nl/parent/sentinel"
touch -d "90 days ago" "$nl_root/$(printf 'a\nT ..')" "$nl_root" "$TMP/age-nl/parent"
nl_targets=$(rule_targets "$nl_root" age 30d 2>/dev/null)
nl_outside=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  case "$t" in "$nl_root/.."|"$nl_root/../"*|"$nl_root/."|*/../*) nl_outside=1 ;; "$nl_root/"?*) ;; *) nl_outside=1 ;; esac
done <<< "$nl_targets"
assert_eq "0" "$nl_outside" "age: a newline in a name never targets a path outside the root"
assert_eq "" "$nl_targets" "age: an entry whose name has a newline is kept"
assert_contains "$(rule_targets "$nl_root" age 30d 2>&1 >/dev/null)" "newline" \
  "age: the kept newline name is reported"
DRY_RUN=0
rule_run "$nl_root" age 30d >/dev/null 2>&1
assert_ok "[ -e \"$TMP/age-nl/parent/sentinel\" ]" "age: rule_run leaves the parent of a newline-named entry alone"

# A failed walk is a failure of the rule, not "nothing to do": it used to warn
# and return 0, so `maint clean` exited 0. find's own error text is kept in the
# warning. The fake find lives only inside each command substitution's
# subshell, so PATH is never changed for the rest of this file.
mkdir -p "$TMP/age-fail/e" "$TMP/fakefind"
touch -d "90 days ago" "$TMP/age-fail/e"
printf '#!/bin/sh\necho "find: simulated walk error" >&2\nexit 1\n' > "$TMP/fakefind/find"
chmod +x "$TMP/fakefind/find"
assert_fails "(PATH=\"$TMP/fakefind:\$PATH\"; rule_targets \"$TMP/age-fail\" age 30d >/dev/null 2>&1)" \
  "age: a failed walk makes rule_targets fail"
DRY_RUN=1
assert_fails "(PATH=\"$TMP/fakefind:\$PATH\"; rule_run \"$TMP/age-fail\" age 30d >/dev/null 2>&1)" \
  "age: a failed walk makes rule_run fail"
err=$(PATH="$TMP/fakefind:$PATH"; rule_targets "$TMP/age-fail" age 30d 2>&1 >/dev/null)
assert_contains "$err" "simulated walk error" "age: find's own error text is in the warning"
assert_fails "case \":$PATH:\" in *fakefind*) true ;; *) false ;; esac" "the fake find did not leak into PATH"
# purge and keep-newest fail the same way, and say why: their find's stderr
# used to be discarded, so a busybox find (no -printf) left "rule(s) failed"
# as the only word.
for pol in "purge -" "keep-newest 1"; do
  assert_fails "(PATH=\"$TMP/fakefind:\$PATH\"; rule_targets \"$TMP/age-fail\" $pol >/dev/null 2>&1)" \
    "$pol: a failed walk makes rule_targets fail"
  err=$(PATH="$TMP/fakefind:$PATH"; rule_targets "$TMP/age-fail" $pol 2>&1 >/dev/null)
  assert_contains "$err" "simulated walk error" "$pol: find's own error text reaches stderr"
done

# A timestamp in the future is unknown, not "used now": a file dated 2030 would
# otherwise pin its entry until 2030. The entry falls back to its other times.
mkdir -p "$TMP/age-future/e/sub"
touch -d "2030-01-01" "$TMP/age-future/e/sub/f"
touch -d "90 days ago" "$TMP/age-future/e/sub" "$TMP/age-future/e"
assert_eq "$TMP/age-future/e" "$(rule_targets "$TMP/age-future" age 30d)" \
  "age: a future-dated file does not keep an old entry"
mkdir -p "$TMP/age-future-only"
touch -d "2030-01-01" "$TMP/age-future-only/f"
assert_eq "" "$(rule_targets "$TMP/age-future-only" age 30d)" \
  "age: an entry with only future times is kept, not judged stale"

# --- purge ---
mkdir -p "$TMP/purge/a" "$TMP/purge/b"
# rule_run skips a rule with nothing to free, so each target carries a byte.
echo x > "$TMP/purge/a/blob"
targets=$(rule_targets "$TMP/purge" purge - | sort)
assert_eq "$TMP/purge/a
$TMP/purge/b" "$targets" "purge targets all children, not the dir"
DRY_RUN=0
rule_run "$TMP/purge" purge - >/dev/null
assert_ok "[ -d \"$TMP/purge\" ]" "purge keeps the container dir"
assert_eq "" "$(ls -A "$TMP/purge")" "purge empties it"

# Regression: purge printed find's output one path per line, so an entry named
# $'a\nvictim' came out as ROOT/a and a bare `victim`, and safe_rm removed that
# relative path from the cwd (maint runs from ~ or /mnt/c/WINDOWS/system32).
# Such a name is kept with a warning; the run from inside the work dir shows a
# wet rule_run leaves the cwd sentinel alone.
mkdir -p "$TMP/purge-nl/p/$(printf 'a\nvictim')" "$TMP/purge-nl/p/plain" "$TMP/purge-nl/victim"
# rule_run skips a rule with nothing to free, so each target carries a byte.
echo x > "$TMP/purge-nl/p/plain/blob"
pnl_targets=$(cd "$TMP/purge-nl" && rule_targets "$PWD/p" purge - 2>/dev/null)
assert_eq "$TMP/purge-nl/p/plain" "$pnl_targets" "purge: an entry whose name has a newline is kept"
assert_contains "$(rule_targets "$TMP/purge-nl/p" purge - 2>&1 >/dev/null)" "newline" \
  "purge: the kept newline name is reported"
DRY_RUN=0
(cd "$TMP/purge-nl" && rule_run "$PWD/p" purge - >/dev/null 2>&1)
assert_ok "[ -d \"$TMP/purge-nl/victim\" ]" "purge: rule_run never deletes a cwd-relative name"
assert_ok "[ -d \"$TMP/purge-nl/p/$(printf 'a\nvictim')\" ]" "purge: the newline-named entry itself is kept"
assert_fails "[ -e \"$TMP/purge-nl/p/plain\" ]" "purge: a plain sibling is still removed"

# --- freed bytes ---
mkdir -p "$TMP/fb/x"
head -c 8192 /dev/zero > "$TMP/fb/x/blob"
rule_estimate "$TMP/fb" purge -
assert_ok "[ \"$RULE_ESTIMATE\" -ge 8192 ]" "rule_estimate counts the target's bytes"

# --- rule_run reports a refusal from anywhere in the rule ---
# Regression: the loop's exit status was the status of its LAST safe_rm, so a
# target refused in the middle of a rule was reported as success.
mkdir -p "$TMP/mid/a" "$TMP/mid/b" "$TMP/mid/c"
# rule_run skips a rule with nothing to free, so each target carries a byte.
echo x > "$TMP/mid/c/blob"
REAL_PATTERNS=("${PROTECTED_PATTERNS[@]}")
PROTECTED_PATTERNS=("$TMP/mid/a")
DRY_RUN=0
assert_fails "rule_run \"$TMP/mid\" purge - >/dev/null 2>&1" \
  "a refused target makes rule_run fail even when a later target succeeds"
PROTECTED_PATTERNS=("${REAL_PATTERNS[@]}")
assert_ok "[ -d \"$TMP/mid/a\" ]" "the protected target survived the refusal"
assert_fails "[ -d \"$TMP/mid/c\" ]" "an unprotected sibling was still removed"

mkdir -p "$TMP/allok/a"
DRY_RUN=0
assert_ok "rule_run \"$TMP/allok\" purge - >/dev/null 2>&1" "a rule with nothing refused succeeds"

# --- vacuum byte math ---
# Regression: journalctl --disk-usage prints a trailing sentence period
# ("... in the file system.") that a naive size regex can also match as
# a bogus second token, so `tail -1` silently grabs "." instead of the
# real size and the function reports 0 freed bytes on every real system.
# Shadow journalctl with the full sentence form (period included) inside
# the command substitution's own subshell, so the stub never leaks into
# any assertion outside this block.
vacuum_out=$(
  journalctl() { echo 'Archived and active journals take up 514.2M in the file system.'; }
  rule_estimate "$TMP" vacuum 100M; echo "$RULE_ESTIMATE"
)
assert_eq "434320180" "$vacuum_out" "vacuum freed bytes: usage above limit returns the difference"

vacuum_out=$(
  journalctl() { echo 'Archived and active journals take up 50M in the file system.'; }
  rule_estimate "$TMP" vacuum 100M; echo "$RULE_ESTIMATE"
)
assert_eq "0" "$vacuum_out" "vacuum freed bytes: usage at or below limit returns 0"

# Regression: under a comma-decimal locale journalctl prints "514,2M", which a
# dot-only size pattern matched as the two tokens "514" and "2M"; `tail -1` took
# "2M", so a journal 400M over its limit reported 2M to free and clean skipped
# the rule as not worth running.
vacuum_out=$(
  journalctl() { echo 'Archived and active journals take up 514,2M in the file system.'; }
  rule_estimate "$TMP" vacuum 100M; echo "$RULE_ESTIMATE"
)
assert_eq "434320180" "$vacuum_out" "a comma decimal separator reads as the same size as a dot"

# --- vacuum: what the sudo gate is allowed to probe ---
# Regression: the gate used to be `sudo -n true`, i.e. it asked "can I run an
# ARBITRARY command without a password?" A correctly narrow sudoers grant --
# NOPASSWD for `journalctl --vacuum-size=...` and nothing else -- answers no to
# that, so the vacuum was skipped on exactly the boxes that had been configured
# properly for it. The only meaningful probe is the real command.
narrow_sudo() {
  # Emulates NOPASSWD for one command and nothing else. `-n` is part of the
  # contract: without it a real sudo prompts at a terminal (an elevated
  # maint.bat window) or errors out, never "skips with a warning".
  [ "${1:-}" = "-n" ] || { echo "sudo: a password is required" >&2; return 1; }
  shift
  if [ "${1:-}" = "journalctl" ] && [ "${2:-}" = "--vacuum-size=100M" ]; then
    return 0
  fi
  echo "sudo: a password is required" >&2
  return 1
}

# rule_run only vacuums a journal over its limit, so one is stubbed for all of these.
journalctl() { echo 'Archived and active journals take up 514.2M in the file system.'; }
DRY_RUN=0
out=$(sudo() { narrow_sudo "$@"; }; rule_run "$TMP" vacuum 100M 2>/dev/null)
assert_eq "  VACUUM 100M" "$out" "narrow NOPASSWD grant is enough to vacuum"

err=$(sudo() { narrow_sudo "$@"; }; rule_run "$TMP" vacuum 100M 2>&1 >/dev/null | grep -v '^\[info\]')
assert_eq "" "$err" "a successful vacuum warns about nothing"

# No grant at all: skipped, and the warning carries sudo's own reason.
out=$(sudo() { echo "sudo: a password is required" >&2; return 1; }; rule_run "$TMP" vacuum 100M 2>/dev/null)
assert_eq "" "$out" "no grant means no VACUUM line"
err=$(sudo() { echo "sudo: a password is required" >&2; return 1; }; rule_run "$TMP" vacuum 100M 2>&1 >/dev/null)
assert_contains "$err" "a password is required" "the skip warning quotes sudo's reason"

# A grant pinned to a DIFFERENT size is not a grant for this rule. This is the
# failure the narrow-grant approach actually produces in practice, and it must
# not look like a success.
out=$(sudo() { narrow_sudo "$@"; }; rule_run "$TMP" vacuum 50M 2>/dev/null)
assert_eq "" "$out" "grant for another size does not vacuum"

# Dry-run never reaches sudo at all.
DRY_RUN=1
out=$(sudo() { echo "SUDO WAS CALLED"; return 0; }; rule_run "$TMP" vacuum 100M 2>/dev/null)
assert_eq "  DRY journalctl --vacuum-size=100M" "$out" "dry-run announces without invoking sudo"
DRY_RUN=0
unset -f journalctl

# --- rule run: one walk, estimate and freed from the same plan ---
mkdir -p "$TMP/rr/a" "$TMP/rr/b"
head -c 1048576 /dev/zero > "$TMP/rr/a/blob"
head -c 3145728 /dev/zero > "$TMP/rr/b/blob"
DRY_RUN=0
rule_estimate "$TMP/rr" purge -
assert_ok "[ \"$RULE_ESTIMATE\" -ge 4194304 ]" "rule_estimate sums every target"
assert_ok "[ -d \"$TMP/rr/a\" ]" "rule_estimate deletes nothing"

DRY_RUN=1
rr_out=$(rule_run "$TMP/rr" purge - 2>&1; echo "freed=$RULE_FREED est=$RULE_ESTIMATE")
assert_contains "$rr_out" "  DRY $TMP/rr/a" "dry rule_run announces each target indented"
assert_contains "$rr_out" "frees 4.0M" "rule_run logs the rule's estimate"
assert_contains "$rr_out" "freed=0 " "a dry run frees nothing"
assert_ok "[ -d \"$TMP/rr/a\" ]" "dry rule_run leaves the targets"

DRY_RUN=0
rr_out=$(rule_run "$TMP/rr" purge - 2>/dev/null; echo "rc=$? freed=$RULE_FREED est=$RULE_ESTIMATE")
assert_contains "$rr_out" "  RM $TMP/rr/b" "rule_run prints each removal indented"
assert_contains "$rr_out" "rc=0 freed=$(echo "$rr_out" | sed -n 's/.*est=//p')" "an unobstructed rule frees its whole estimate"
assert_fails "[ -e \"$TMP/rr/a\" ] || [ -e \"$TMP/rr/b\" ]" "rule_run removed every target"

# Nothing to free: silent, no header.
mkdir -p "$TMP/rr-empty"
rr_out=$(rule_run "$TMP/rr-empty" purge - 2>&1; echo "rc=$? freed=$RULE_FREED")
assert_eq "rc=0 freed=0" "$rr_out" "a rule with nothing to free prints nothing"

# A refused target fails the rule and counts nothing; its sibling still counts.
mkdir -p "$TMP/rr-ref/a" "$TMP/rr-ref/b"
head -c 1048576 /dev/zero > "$TMP/rr-ref/a/blob"
head -c 1048576 /dev/zero > "$TMP/rr-ref/b/blob"
REAL_PATTERNS=("${PROTECTED_PATTERNS[@]}")
PROTECTED_PATTERNS=("$TMP/rr-ref/a")
rr_out=$(rule_run "$TMP/rr-ref" purge - 2>/dev/null; echo "rc=$? freed=$RULE_FREED")
PROTECTED_PATTERNS=("${REAL_PATTERNS[@]}")
assert_contains "$rr_out" "rc=1 " "a refused target makes rule_run fail"
assert_ok "[ \"\$(echo \"\$rr_out\" | sed -n 's/.*freed=//p')\" -ge 1048576 ] && [ \"\$(echo \"\$rr_out\" | sed -n 's/.*freed=//p')\" -lt 2097152 ]" \
  "freed counts the removed sibling, not the refused target"

# A target rm only half deletes counts only what went.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMP/rr-half/t/locked"
  head -c 1048576 /dev/zero > "$TMP/rr-half/t/locked/stuck"
  head -c 2097152 /dev/zero > "$TMP/rr-half/t/loose"
  chmod a-w "$TMP/rr-half/t/locked"
  rr_out=$(rule_run "$TMP/rr-half" purge - 2>/dev/null; echo "rc=$? freed=$RULE_FREED")
  chmod u+w "$TMP/rr-half/t/locked"
  rr_freed=$(echo "$rr_out" | sed -n 's/.*freed=//p')
  assert_contains "$rr_out" "rc=1 " "a half-deleted target makes rule_run fail"
  assert_ok "[ \"$rr_freed\" -ge 2097152 ] && [ \"$rr_freed\" -lt 3145728 ]" \
    "freed counts the half that went, not the estimate"
fi

# One walk: rule_targets runs once per rule_run.
eval "$(declare -f rule_targets | sed '1s/rule_targets/_orig_rule_targets/')"
rule_targets() { echo x >> "$TMP/rr-walks"; _orig_rule_targets "$@"; }
mkdir -p "$TMP/rr-once/a"
head -c 4096 /dev/zero > "$TMP/rr-once/a/blob"
: > "$TMP/rr-walks"
rule_run "$TMP/rr-once" purge - >/dev/null 2>&1
assert_eq "1" "$(wc -l < "$TMP/rr-walks")" "rule_run walks the rule once"
eval "$(declare -f _orig_rule_targets | sed '1s/_orig_rule_targets/rule_targets/')"
unset -f _orig_rule_targets

# vacuum: freed is the journal's own shrinkage, measured after the vacuum.
journal_stub() {
  if [ -e "$TMP/vacuumed" ]; then
    echo 'Archived and active journals take up 120M in the file system.'
  else
    echo 'Archived and active journals take up 514.2M in the file system.'
  fi
}
rm -f "$TMP/vacuumed"
rr_out=$(
  journalctl() { journal_stub; }
  sudo() { : > "$TMP/vacuumed"; return 0; }
  rule_run "$TMP" vacuum 100M 2>/dev/null; echo "rc=$? freed=$RULE_FREED est=$RULE_ESTIMATE"
)
rm -f "$TMP/vacuumed"
assert_contains "$rr_out" "  VACUUM 100M" "vacuum announces itself indented"
assert_contains "$rr_out" "rc=0 freed=413348660 est=434320180" "vacuum frees what the journal shrank, not the estimate"
rr_out=$(
  journalctl() { journal_stub; }
  sudo() { echo "sudo: a password is required" >&2; return 1; }
  rule_run "$TMP" vacuum 100M 2>/dev/null; echo "rc=$? freed=$RULE_FREED"
)
assert_contains "$rr_out" "rc=0 freed=0" "a vacuum without a sudo grant frees 0 and does not fail"
# A journal size that cannot be re-read after the vacuum is unknown, not 0:
# reading it as 0 reported the whole journal as freed.
rm -f "$TMP/vacuumed"
rr_out=$(
  journalctl() { [ -e "$TMP/vacuumed" ] || journal_stub; }
  sudo() { : > "$TMP/vacuumed"; return 0; }
  rule_run "$TMP" vacuum 100M 2>"$TMP/vac-unknown.err"; echo "rc=$? freed=$RULE_FREED"
)
rm -f "$TMP/vacuumed"
assert_contains "$rr_out" "rc=0 freed=0" "an unreadable post-vacuum size frees 0, not the whole journal"
assert_contains "$(cat "$TMP/vac-unknown.err")" "journal size after the vacuum" "the unknown size is warned about"

# --- missing path is not an error ---
assert_eq "" "$(rule_targets "$TMP/does-not-exist" purge -)" "missing path yields no targets"
rule_estimate "$TMP/does-not-exist" purge -
assert_eq "0" "$RULE_ESTIMATE" "missing path frees 0"

# --- property: no policy hands safe_rm anything but ROOT/<entry> ---
# Every policy that enumerates targets, looped from KNOWN_POLICIES so a new
# policy is covered (or fails here for want of a fixture) without anyone
# remembering this test. Each root holds old entries with hostile names: a
# newline once split $'a\nvictim' into ROOT/a and a bare `victim` that safe_rm
# resolved against the cwd. The run happens from a cwd holding a sentinel for
# every fragment after a newline, next to a sibling of ROOT, and both must
# survive a wet rule_run.
. ../wsl/lib/browsers.sh
PROP_NAMES=($'a\nvictim' $'a\nT ..' '-rf' ' lead space' 'trail space ' 'plain')

# _prop_fixture POLICY ROOT -> "ARG|PLAIN" after building ROOT; PLAIN is the
# entry that must come out as a target, so a fixture that targets nothing
# cannot pass vacuously. Returns 1 for a policy with no fixture.
_prop_fixture() {
  local policy="$1" root="$2" n
  mkdir -p "$root"
  case "$policy" in
    purge|age|keep-newest)
      for n in "${PROP_NAMES[@]}"; do
        mkdir -p "$root/$n"
        echo x > "$root/$n/f"
        touch -d '2020-01-01' "$root/$n/f" "$root/$n"
      done
      mkdir -p "$root/fresh"   # keep-newest 1 keeps this one
      case "$policy" in
        purge) echo "-|plain" ;;
        age) echo "30d|plain" ;;
        keep-newest) echo "1|plain" ;;
      esac
      ;;
    pw-orphan)
      # Only chromium-<digits> dirs are candidates, so each name rides between
      # the prefix and an orphan revision; chromium-1217 is pinned.
      mkdir -p "$root.pw/pkg/playwright/driver/package" "$root/chromium-1217"
      echo '{"browsers": [{"name": "chromium", "revision": "1217"}]}' \
        > "$root.pw/pkg/playwright/driver/package/browsers.json"
      echo "$root.pw" > "$root.roots"
      PW_ROOTS_FILE="$root.roots"
      for n in "${PROP_NAMES[@]}"; do
        mkdir -p "$root/chromium-$n-1234"
        # rule_run skips a rule with nothing to free, so each dir carries a byte.
        echo x > "$root/chromium-$n-1234/blob"
        touch -d '2020-01-01' "$root/chromium-$n-1234"
      done
      echo "-|chromium-plain-1234"
      ;;
    *) return 1 ;;
  esac
}

for policy in $KNOWN_POLICIES; do
  [ "$policy" = vacuum ] && continue   # journald's files, nothing enumerated
  base="$TMP/prop/$policy"
  root="$base/parent/root"
  mkdir -p "$base/cwd" "$base/parent"
  echo keep > "$base/parent/sibling"
  if ! fx=$(_prop_fixture "$policy" "$root"); then
    assert_eq "a fixture" "none" "property: policy '$policy' has no fixture in _prop_fixture"
    continue
  fi
  # A command substitution forks, so PW_ROOTS_FILE set inside it is lost.
  [ "$policy" = pw-orphan ] && PW_ROOTS_FILE="$root.roots"
  arg="${fx%%|*}" plain="${fx#*|}"
  sentinels=()
  while IFS= read -r -d '' n; do
    case "$n" in *$'\n'*) sentinels+=("${n#*$'\n'}") ;; esac
  done < <(find "$root" -mindepth 1 -maxdepth 1 -printf '%f\0')
  assert_ok "[ ${#sentinels[@]} -gt 0 ]" "property $policy: fixture holds a newline name"
  for n in "${sentinels[@]}"; do mkdir -p "$base/cwd/$n"; done

  targets=$(cd "$base/cwd" && rule_targets "$root" "$policy" "$arg" 2>/dev/null)
  bad=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rel="${line#"$root"/}"
    if [ "$rel" = "$line" ] || [ -z "$rel" ] || [ "$rel" = . ] || [ "$rel" = .. ] \
        || [[ "$rel" == */* ]]; then
      bad+="$(printf '%q' "$line") "
    fi
  done <<< "$targets"
  assert_eq "" "$bad" "property $policy: every target is an absolute ROOT/<entry>"
  assert_contains "$targets" "$root/$plain" "property $policy: the plain old entry is a target"

  (cd "$base/cwd" && DRY_RUN=0 rule_run "$root" "$policy" "$arg" >/dev/null 2>&1)
  for n in "${sentinels[@]}"; do
    assert_ok "[ -d \"\$base/cwd/\$n\" ]" "property $policy: cwd sentinel $(printf '%q' "$n") survives"
  done
  assert_ok "[ -f \"$base/parent/sibling\" ]" "property $policy: ROOT's parent survives"
  assert_ok "[ ! -e \"$root/$plain\" ]" "property $policy: the wet run removed the plain entry"
done

echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
