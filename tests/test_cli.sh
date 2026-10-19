#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./assert.sh

MAINT=../wsl/maint
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export STATE_FILE="$TMP/state"

# Hermetic: this file runs real (non-dry) cleans. Only --rules keeps them on
# the fixture, so if that ever broke, the repo rules.conf would hit the real
# home and a real journal vacuum. A throwaway HOME and recording sudo and
# journalctl fakes (they never run their arguments) keep a broken build safe.
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin"
for fake in sudo journalctl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 0\n' "$fake" "$TMP" > "$TMP/bin/$fake"
  chmod +x "$TMP/bin/$fake"
done
# The sudo fake insists on -n, as the README's "skipped with a warning" does.
printf '#!/bin/sh\necho "sudo $*" >> "%s/calls"\n[ "$1" = -n ] || { echo "sudo: a password is required" >&2; exit 1; }\nexit 0\n' "$TMP" > "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH"

# Hermetic config: the owner's checkout has a real maint.conf at the repo
# root. Every run here reads an empty one unless a test says otherwise.
: > "$TMP/empty.conf"
export WSL_MAINT_CONFIG="$TMP/empty.conf"

mkdir -p "$TMP/auto/x" "$TMP/manual/y"
head -c 2048 /dev/zero > "$TMP/auto/x/blob"
head -c 2048 /dev/zero > "$TMP/manual/y/blob"
cat > "$TMP/rules.conf" <<EOF
$TMP/auto      purge   -   yes
$TMP/manual    purge   -   no
EOF

assert_ok "[ -x $MAINT ]" "maint is executable"

out=$("$MAINT" help 2>&1)
assert_contains "$out" "audit" "help mentions audit"
assert_contains "$out" "--dry-run" "help mentions --dry-run"

rc=0; "$MAINT" bogus >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "unknown subcommand exits 2"
rc=0; "$MAINT" clean --bogus-flag >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "unknown flag exits 2"

out=$("$MAINT" audit --rules "$TMP/rules.conf" 2>&1)
assert_contains "$out" "TOTAL" "audit runs"

# dry-run changes nothing, and records no run: `--if-stale` after a dry run
# must still clean (a look with --dry-run used to be able to suppress the
# README's `@reboot maint clean --if-stale 7` for a week).
rm -f "$STATE_FILE"
"$MAINT" clean --dry-run --rules "$TMP/rules.conf" >/dev/null 2>&1
assert_ok "[ -f \"$TMP/auto/x/blob\" ]" "dry-run leaves auto rule alone"
assert_fails "grep -q '^lastrun.clean=' \"$STATE_FILE\" 2>/dev/null" "dry-run writes no lastrun.clean"
out=$("$MAINT" clean --dry-run --if-stale 7 --rules "$TMP/rules.conf" 2>&1)
assert_fails "printf '%s' \"\$out\" | grep -q 'not stale'" "--if-stale after only a dry run still runs"

# real run applies auto rules only
"$MAINT" clean --rules "$TMP/rules.conf" >/dev/null 2>&1
assert_fails "[ -f \"$TMP/auto/x/blob\" ]" "auto rule applied"
assert_ok "[ -f \"$TMP/manual/y/blob\" ]" "auto=no rule skipped"

# --sessions opts the manual rules in
"$MAINT" clean --sessions --rules "$TMP/rules.conf" >/dev/null 2>&1
assert_fails "[ -f \"$TMP/manual/y/blob\" ]" "--sessions applies auto=no rules"

# --if-stale short-circuits right after a run
"$MAINT" clean --rules "$TMP/rules.conf" >/dev/null 2>&1
out=$("$MAINT" clean --if-stale 7 --rules "$TMP/rules.conf" 2>&1)
assert_contains "$out" "not stale" "--if-stale skips a fresh run"

# Regression: a leading zero made `$(( days * 86400 ))` read the value as
# octal: `08` died with "value too great for base" (exit 1) and `010`
# silently meant 8 days. The value is base 10.
rc=0
out=$("$MAINT" clean --if-stale 08 --rules "$TMP/rules.conf" 2>&1) || rc=$?
assert_eq "0" "$rc" "--if-stale 08 exits 0"
assert_contains "$out" "not stale" "--if-stale 08 means 8 days"
# Last run 9 days ago: stale for 8 days (octal 010), not stale for 10 days.
printf 'lastrun.clean=%s\n' "$(( $(date +%s) - 9 * 86400 ))" > "$STATE_FILE"
out=$("$MAINT" clean --if-stale 010 --rules "$TMP/rules.conf" 2>&1)
assert_contains "$out" "not stale" "--if-stale 010 means 10 days, not octal 8"

# Regression: --if-stale with no value used to default silently via
# ${2:-7} and then run `shift 2` with only one positional param left.
# `shift` failing there is an unshielded simple command, so under this
# script's `set -e` the whole CLI died with exit 1 and no output at all
# instead of reporting a usable error. It must now fail loudly.
rc=0; err=$("$MAINT" clean --if-stale 2>&1 1>/dev/null) || rc=$?
assert_eq "2" "$rc" "--if-stale without a value exits 2"
assert_contains "$err" "[err ] --if-stale needs" "--if-stale without a value explains why"
# Same for the other value-taking flags: `${2:?}` used to exit 1 with bash's
# own "line N: 2:" message instead of the CLI's usage error.
for flag in --rules --config; do
  rc=0; err=$("$MAINT" audit $flag 2>&1 1>/dev/null) || rc=$?
  assert_eq "2" "$rc" "$flag without a value exits 2"
  assert_contains "$err" "[err ] $flag needs a path" "$flag without a value explains why"
  rc=0; err=$("$MAINT" audit $flag "" 2>&1 1>/dev/null) || rc=$?
  assert_eq "2" "$rc" "$flag with an empty value exits 2"
done
rc=0; err=$("$MAINT" clean --if-stale "" 2>&1 1>/dev/null) || rc=$?
assert_eq "2" "$rc" "--if-stale with an empty value exits 2"

# Regression: --if-stale with a non-numeric value used to reach
# state_is_stale unvalidated, hit `$(( days * 86400 ))` in state.sh with a
# non-numeric operand, and trip `set -u` there -- a raw "unbound variable"
# error naming an internal lib file/line instead of the CLI's own message,
# and exit 1 instead of the CLI's documented "bad flag" exit code of 2.
rc=0
err_nn=$("$MAINT" clean --if-stale banana --rules "$TMP/rules.conf" 2>&1 1>/dev/null) || rc=$?
assert_eq "2" "$rc" "--if-stale with a non-numeric value exits 2"
assert_contains "$err_nn" "--if-stale needs a number of days" "--if-stale with a non-numeric value reports the CLI's own message"
assert_fails "echo \"$err_nn\" | grep -q 'state.sh'" "--if-stale with a non-numeric value does not leak an internal lib file/line"

# The playwright-revision cache is per-process by design; the entry point
# removes its own on exit, so runs do not strand one /tmp file each.
mkdir -p "$TMP/pwtmp" "$TMP/pwcache/chromium-1"
: > "$TMP/pwroots"
printf '%s pw-orphan - yes\n' "$TMP/pwcache" > "$TMP/pw.rules"
TMPDIR="$TMP/pwtmp" PW_ROOTS_FILE="$TMP/pwroots" "$MAINT" audit --rules "$TMP/pw.rules" >/dev/null 2>&1
TMPDIR="$TMP/pwtmp" PW_ROOTS_FILE="$TMP/pwroots" "$MAINT" clean --dry-run --rules "$TMP/pw.rules" >/dev/null 2>&1
assert_eq "" "$(ls -A "$TMP/pwtmp")" "no pw-wanted cache file left behind after audit/clean"

# The fixture has no journal rule, so nothing may have reached sudo/journalctl.
assert_fails "[ -s \"$TMP/calls\" ]" "no sudo/journalctl call escaped the fixture rules"

# --- maint.conf ---

# A broken line stops the command before any work, naming file and line.
printf '# comment\n\nbackup_root = D:\\b\nbogus_key = 1\n' > "$TMP/bad-key.conf"
rc=0
err=$("$MAINT" audit --config "$TMP/bad-key.conf" --rules "$TMP/rules.conf" 2>&1) || rc=$?
assert_eq "2" "$rc" "unknown config key exits 2"
assert_contains "$err" "$TMP/bad-key.conf:4" "unknown config key names file:line"
assert_contains "$err" "bogus_key" "unknown config key is named"
assert_fails "printf '%s' \"\$err\" | grep -q TOTAL" "unknown config key stops before audit runs"

printf 'distro = Ubuntu\njust some words\n' > "$TMP/no-eq.conf"
rc=0
err=$(WSL_MAINT_CONFIG="$TMP/no-eq.conf" "$MAINT" audit --rules "$TMP/rules.conf" 2>&1) || rc=$?
assert_eq "2" "$rc" "line without = exits 2"
assert_contains "$err" "$TMP/no-eq.conf:2" "line without = names file:line (via WSL_MAINT_CONFIG)"

# A UTF-8 BOM (Notepad, PS 5.1's UTF8 encoding) in front of line 1 is not
# part of the first key; Common.ps1 strips it the same way.
printf '\xef\xbb\xbfdistro = Debian\n' > "$TMP/bom.conf"
rc=0
err=$("$MAINT" audit --config "$TMP/bom.conf" --rules "$TMP/rules.conf" 2>&1) || rc=$?
assert_eq "0" "$rc" "a UTF-8 BOM before the first key is accepted"
assert_fails "printf '%s' \"\$err\" | grep -q 'unknown key'" "a UTF-8 BOM is not read as part of the key"

# Keys match exactly: a key holding a space, or one that is a substring of the
# joined key list, is unknown.
for bad in 'keep docker_guard_extra = x' 'p = x' 'distro backup_root = x'; do
  printf '%s\n' "$bad" > "$TMP/sub-key.conf"
  rc=0
  err=$("$MAINT" audit --config "$TMP/sub-key.conf" --rules "$TMP/rules.conf" 2>&1) || rc=$?
  assert_eq "2" "$rc" "key '${bad%% =*}' is unknown, exits 2"
  assert_contains "$err" "$TMP/sub-key.conf:1: unknown key" "key '${bad%% =*}' is reported as unknown with file:line"
done

# distro and keep are validated exactly as Common.ps1 does, same messages:
# keep is a whole number 1 to 1000, distro is [A-Za-z0-9._-]+.
for bad in 'keep = 0' 'keep = -1' 'keep = three' 'keep = 2.5' 'keep = 1001' \
           'keep = 99999999999999999999999' 'keep = 0x10'; do
  printf '%s\n' "$bad" > "$TMP/bad-val.conf"
  rc=0
  err=$("$MAINT" audit --config "$TMP/bad-val.conf" --rules "$TMP/rules.conf" 2>&1) || rc=$?
  assert_eq "2" "$rc" "rejected: $bad"
  assert_contains "$err" "$TMP/bad-val.conf:1: keep must be a whole number from 1 to 1000, got: ${bad#keep = }" "file:line message for: $bad"
done
for bad in 'distro = Ub*' 'distro = my distro' 'distro = ..\x' 'distro = a/b'; do
  printf '%s\n' "$bad" > "$TMP/bad-val.conf"
  rc=0
  err=$("$MAINT" audit --config "$TMP/bad-val.conf" --rules "$TMP/rules.conf" 2>&1) || rc=$?
  assert_eq "2" "$rc" "rejected: $bad"
  assert_contains "$err" "$TMP/bad-val.conf:1: distro may only contain letters, digits, '.', '_' and '-', got: ${bad#distro = }" "file:line message for: $bad"
done
printf 'keep = 1000\ndistro = Ubuntu-22.04_x\n' > "$TMP/good-val.conf"
rc=0
"$MAINT" audit --config "$TMP/good-val.conf" --rules "$TMP/rules.conf" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "keep = 1000 and a dotted, dashed distro are accepted"

# --config wins over the environment variable.
rc=0
WSL_MAINT_CONFIG="$TMP/no-eq.conf" "$MAINT" audit --config "$TMP/empty.conf" --rules "$TMP/rules.conf" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "--config overrides WSL_MAINT_CONFIG"

# An explicitly named config that does not exist is an error, not defaults.
rc=0
err=$("$MAINT" audit --config "$TMP/nope.conf" --rules "$TMP/rules.conf" 2>&1) || rc=$?
assert_eq "2" "$rc" "missing --config file exits 2"
assert_contains "$err" "$TMP/nope.conf" "missing --config file is named"
assert_fails "$MAINT audit --config >/dev/null 2>&1" "--config without a value fails"

out=$("$MAINT" help 2>&1)
assert_contains "$out" "--config" "help documents --config"

# The shipped example is a valid config as-is (all defaults).
rc=0
err=$("$MAINT" verify --config ../maint.conf.example 2>&1) || rc=$?
assert_contains "$err" "set backup_root in ../maint.conf.example" "maint.conf.example parses and leaves backup_root unset"
for key in distro backup_root keep docker_guard_extra docker_named_volumes pw_scan_roots_extra; do
  assert_ok "grep -q '^$key =' ../maint.conf.example" "maint.conf.example lists $key"
done

# Values are data: a $(...) value is never executed.
printf 'backup_root = D:\\$(touch %s/pwned)\n' "$TMP" > "$TMP/inject.conf"
"$MAINT" verify --config "$TMP/inject.conf" >/dev/null 2>&1
assert_fails "[ -e \"$TMP/pwned\" ]" "a \$(...) config value is not executed"

# verify: refuses without backup_root and names the key.
rc=0
err=$("$MAINT" verify 2>&1) || rc=$?
assert_eq "1" "$rc" "verify without backup_root exits 1"
assert_contains "$err" "set backup_root in $TMP/empty.conf" "verify without backup_root names the key and file"

# verify: backup_root goes through the D:\ -> /mnt/d rule, and only archives
# named after the distro count (a newer foreign archive is ignored). zstd is
# a recording fake; MAINT_MNT_BASE stands in for /mnt.
printf '#!/bin/sh\necho "zstd $*" >> "%s/zstd.calls"\nexit 0\n' "$TMP" > "$TMP/bin/zstd"
chmod +x "$TMP/bin/zstd"
BK="$TMP/mnt/q/Backups/WSL"
mkdir -p "$BK"
printf 'x' > "$BK/debian_2026-01-01_0100.tar.zst"
touch -d '2026-01-01' "$BK/debian_2026-01-01_0100.tar.zst"
printf 'x' > "$BK/ubuntu_2026-02-01_0100.tar.zst"
touch -d '2026-02-01' "$BK/ubuntu_2026-02-01_0100.tar.zst"
# Newer, and starting with ubuntu_, but not an archive Windows retention would
# count (<prefix>yyyy-MM-dd_HHmm.tar.zst): another distro (Ubuntu_22) and a
# hand-made copy. verify must skip them like retention does.
printf 'x' > "$BK/ubuntu_22_2026-03-01_0100.tar.zst"
touch -d '2026-03-01' "$BK/ubuntu_22_2026-03-01_0100.tar.zst"
printf 'x' > "$BK/ubuntu_manual-copy.tar.zst"
touch -d '2026-03-02' "$BK/ubuntu_manual-copy.tar.zst"
cat > "$TMP/verify.conf" <<'EOF'
backup_root = Q:\Backups\WSL
distro = Debian
EOF
: > "$TMP/zstd.calls"
rc=0
MAINT_MNT_BASE="$TMP/mnt" "$MAINT" verify --config "$TMP/verify.conf" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "verify with a configured backup_root exits 0"
assert_eq "zstd -t $BK/debian_2026-01-01_0100.tar.zst" "$(cat "$TMP/zstd.calls")" "verify picks the configured distro's newest archive, not a newer foreign one"

# Default distro Ubuntu -> ubuntu_ prefix.
printf '%s\n' 'backup_root = Q:\Backups\WSL' > "$TMP/verify-default.conf"
: > "$TMP/zstd.calls"
MAINT_MNT_BASE="$TMP/mnt" "$MAINT" verify --config "$TMP/verify-default.conf" >/dev/null 2>&1
assert_eq "zstd -t $BK/ubuntu_2026-02-01_0100.tar.zst" "$(cat "$TMP/zstd.calls")" "default distro Ubuntu verifies the newest archive in retention's name shape, not a newer look-alike"

# Lowercasing is locale-independent: under tr_TR `${x,,}` maps I to dotless
# ı, so I:\ became /mnt/ı and Ubuntu-IoT the prefix ubuntu-ıot_, which the
# Windows side (ToLowerInvariant) never writes. Needs a generated locale;
# skipped where localedef cannot make one.
if mkdir -p "$TMP/loc" && localedef -i tr_TR -f UTF-8 "$TMP/loc/tr_TR.UTF-8" >/dev/null 2>&1; then
  mkdir -p "$TMP/mnt/i/wsl"
  printf 'x' > "$TMP/mnt/i/wsl/ubuntu-iot_2026-02-01_0100.tar.zst"
  printf '%s\n' 'backup_root = I:\wsl' 'distro = Ubuntu-IoT' > "$TMP/verify-tr.conf"
  : > "$TMP/zstd.calls"
  rc=0
  LOCPATH="$TMP/loc" LC_ALL=tr_TR.UTF-8 MAINT_MNT_BASE="$TMP/mnt" "$MAINT" verify --config "$TMP/verify-tr.conf" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "verify under tr_TR exits 0 for I:\ and a distro with an I"
  assert_eq "zstd -t $TMP/mnt/i/wsl/ubuntu-iot_2026-02-01_0100.tar.zst" "$(cat "$TMP/zstd.calls")" "verify under tr_TR lowercases I to i"
else
  echo "SKIP tr_TR locale cannot be generated here"
fi

# A root that is not a local drive path is refused, not mangled.
printf '%s\n' 'backup_root = \\server\share' > "$TMP/unc.conf"
rc=0
err=$("$MAINT" verify --config "$TMP/unc.conf" 2>&1) || rc=$?
assert_eq "1" "$rc" "verify with a UNC backup_root exits 1"
assert_contains "$err" "local drive path" "verify with a UNC backup_root says why"

# Default location: maint.conf at the repo root, found through a symlink to
# the entry point (how ~/.local/bin/maint and ~/tools/wsl-maint reach it).
# A copy of wsl/ under a fake repo keeps the real checkout's maint.conf out.
mkdir -p "$TMP/repo" "$TMP/links"
cp -r ../wsl "$TMP/repo/wsl"
ln -s "$TMP/repo/wsl/maint" "$TMP/links/maint"
ln -s "$TMP/repo/wsl" "$TMP/links/wsl-maint"
rc=0
err=$(env -u WSL_MAINT_CONFIG "$TMP/links/maint" verify 2>&1) || rc=$?
assert_eq "1" "$rc" "no maint.conf at the repo root: defaults, verify refuses"
assert_contains "$err" "set backup_root in $TMP/repo/maint.conf" "no maint.conf: the message points at the repo-root file"
printf '%s\n' 'backup_root = Q:\Backups\WSL' > "$TMP/repo/maint.conf"
: > "$TMP/zstd.calls"
rc=0
env -u WSL_MAINT_CONFIG MAINT_MNT_BASE="$TMP/mnt" "$TMP/links/maint" verify >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "repo-root maint.conf is read through a ~/.local/bin/maint style symlink"
: > "$TMP/zstd.calls"
env -u WSL_MAINT_CONFIG MAINT_MNT_BASE="$TMP/mnt" "$TMP/links/wsl-maint/maint" verify >/dev/null 2>&1
assert_contains "$(cat "$TMP/zstd.calls")" "ubuntu_2026-02-01_0100" "repo-root maint.conf is read through a ~/tools/wsl-maint style symlink"

# pw_scan_roots_extra: a browser pinned by a project under an extra root is
# kept by a pw-orphan rule, the unpinned revision is the only target. HOME is
# the empty fixture home, so the built-in roots find nothing.
mkdir -p "$TMP/pwc/chromium-1217" "$TMP/pwc/chromium-1234" \
         "$TMP/proj/app/node_modules/playwright-core"
head -c 2048 /dev/zero > "$TMP/pwc/chromium-1217/blob"
head -c 2048 /dev/zero > "$TMP/pwc/chromium-1234/blob"
echo '{"browsers": [{"name": "chromium", "revision": "1217"}]}' \
  > "$TMP/proj/app/node_modules/playwright-core/browsers.json"
printf '%s pw-orphan - yes\n' "$TMP/pwc" > "$TMP/pwc.rules"
printf 'pw_scan_roots_extra = %s/proj\n' "$TMP" > "$TMP/pw-extra.conf"
out=$(env -u PW_ROOTS_FILE "$MAINT" clean --dry-run --rules "$TMP/pwc.rules" --config "$TMP/pw-extra.conf" 2>&1)
assert_contains "$out" "DRY $TMP/pwc/chromium-1234" "extra scan root: the unpinned revision is targeted"
assert_fails "printf '%s' \"\$out\" | grep -q 'chromium-1217'" "extra scan root: the revision it pins is kept"
# A configured root that is gone blocks the prune and says which key to fix.
printf 'pw_scan_roots_extra = %s/nothing-here:%s/proj\n' "$TMP" "$TMP" > "$TMP/pw-gone.conf"
out=$(env -u PW_ROOTS_FILE "$MAINT" clean --dry-run --rules "$TMP/pwc.rules" --config "$TMP/pw-gone.conf" 2>&1)
assert_fails "printf '%s' \"\$out\" | grep -q 'DRY .*chromium-1234'" "missing extra scan root: nothing is targeted"
assert_contains "$out" "$TMP/nothing-here (listed in pw_scan_roots_extra in $TMP/pw-gone.conf" "missing extra scan root: named, with the file to fix"
out=$(env -u PW_ROOTS_FILE "$MAINT" clean --dry-run --rules "$TMP/pwc.rules" 2>&1)
assert_contains "$out" "no installed playwright found" "without the extra root nothing pins anything and the prune is skipped"

# Inherited environment: a generic ASSUME_YES or DRY_RUN another tool exported
# must not answer yes or turn a real run into a silent dry one. Only --yes and
# --dry-run set them. A docker shim records calls; it is first on PATH and the
# only candidate, so the real daemon is never reached.
mkdir -p "$TMP/dbin"
anon=$(printf 'a%.0s' $(seq 64))
cat > "$TMP/dbin/docker" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$TMP/docker.calls"
case "\$1 \${2:-}" in
  "volume ls") echo "$anon"; echo "app_mysql_data" ;;
esac
exit 0
SHIM
chmod +x "$TMP/dbin/docker"
: > "$TMP/docker.calls"
ASSUME_YES=1 PATH="$TMP/dbin:$PATH" DOCKER_CANDIDATES=docker \
  "$MAINT" docker < /dev/null > /dev/null 2>&1
assert_contains "$(cat "$TMP/docker.calls")" "volume ls" "env ASSUME_YES: the shim was reached"
assert_fails "grep -q 'volume rm' \"$TMP/docker.calls\"" "env ASSUME_YES=1 without --yes removes no volume without a terminal"
: > "$TMP/docker.calls"
PATH="$TMP/dbin:$PATH" DOCKER_CANDIDATES=docker \
  "$MAINT" docker --yes < /dev/null > /dev/null 2>&1
assert_contains "$(cat "$TMP/docker.calls")" "volume rm" "--yes still removes volumes"

mkdir -p "$TMP/envdry/x"
head -c 2048 /dev/zero > "$TMP/envdry/x/blob"
printf '%s purge - yes\n' "$TMP/envdry" > "$TMP/envdry.rules"
out=$(DRY_RUN=1 "$MAINT" clean --rules "$TMP/envdry.rules" 2>&1)
assert_fails "[ -f \"$TMP/envdry/x/blob\" ]" "env DRY_RUN=1 without --dry-run: the run is real"
assert_fails "printf '%s' \"\$out\" | grep -q '^DRY '" "env DRY_RUN=1 without --dry-run prints no DRY line"

# The shipped rules.conf: the claude versions rule keeps the newest by mtime,
# which need not be the version in use, so plain `clean` must not run it;
# `--sessions` still does. Dry runs of the default rules against a throwaway
# HOME; sudo and journalctl are the recording fakes above.
CV="$TMP/cvhome/.local/share/claude/versions"
mkdir -p "$CV/1.0.0" "$CV/2.0.0"
head -c 2048 /dev/zero > "$CV/1.0.0/bin"
head -c 2048 /dev/zero > "$CV/2.0.0/bin"
touch -d '2026-01-01' "$CV/1.0.0"
# A crashed run prints nothing and would pass the "leaves alone" check, so
# both runs must exit 0 and report their dry-run total.
rc=0; out=$(HOME="$TMP/cvhome" "$MAINT" clean --dry-run 2>&1) || rc=$?
assert_eq "0" "$rc" "plain clean --dry-run on the shipped rules exits 0"
assert_contains "$out" "would free: " "plain clean --dry-run reports its total"
assert_fails "printf '%s' \"\$out\" | grep -q '$CV'" "plain clean leaves the claude versions dir alone"
rc=0; out=$(HOME="$TMP/cvhome" "$MAINT" clean --dry-run --sessions 2>&1) || rc=$?
assert_eq "0" "$rc" "clean --dry-run --sessions exits 0"
assert_contains "$out" "DRY $CV/1.0.0" "clean --sessions still prunes old claude versions"


# --- exit code is the contract between the halves (docs/how-it-works.md) ---
# Usage errors exit 2, not just "non-zero"; Invoke-Wsl throws on any non-zero
# so a 1 would still throw, but README documents 2 for usage/config errors.
# A failed clean exits 1 and does not write lastrun.clean, so --if-stale does
# not count it as a run. The rule's target is the fixture HOME, an ancestor of
# $HOME/.ssh, which is_protected refuses.
mkdir -p "$HOME/.ssh" "$HOME/junk"
head -c 2048 /dev/zero > "$HOME/junk/blob"
printf '%s purge - yes\n' "$HOME" > "$TMP/refused.rules"
rm -f "$STATE_FILE"
rc=0; err=$("$MAINT" clean --rules "$TMP/refused.rules" 2>&1 1>/dev/null) || rc=$?
assert_eq "1" "$rc" "a refused clean exits 1 through the CLI"
assert_contains "$err" "rule(s) failed" "a refused clean reports the failure"
assert_fails "grep -q '^lastrun.clean=' \"$STATE_FILE\" 2>/dev/null" "a failed clean writes no lastrun.clean"
out=$("$MAINT" clean --if-stale 7 --rules "$TMP/refused.rules" 2>&1) || true
assert_fails "printf '%s' \"\$out\" | grep -q 'not stale'" "a failed clean does not satisfy --if-stale"

# A dead docker client: exit 1, no lastrun.docker. The shim fails `docker info`.
mkdir -p "$TMP/deadbin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/deadbin/docker"
chmod +x "$TMP/deadbin/docker"
rm -f "$STATE_FILE"
rc=0; err=$(PATH="$TMP/deadbin:$PATH" DOCKER_CANDIDATES=docker "$MAINT" docker --yes < /dev/null 2>&1 1>/dev/null) || rc=$?
assert_eq "1" "$rc" "an unreachable docker exits 1 through the CLI"
assert_contains "$err" "docker not reachable" "an unreachable docker is named through the CLI"
assert_fails "grep -q '^lastrun.docker=' \"$STATE_FILE\" 2>/dev/null" "a failed docker prune writes no lastrun.docker"

echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
