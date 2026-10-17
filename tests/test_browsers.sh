#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./assert.sh
. ../wsl/lib/common.sh
. ../wsl/lib/config.sh
. ../wsl/lib/browsers.sh
. ../wsl/lib/rules.sh
. ../wsl/lib/clean.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A browsers.json shaped like the real thing: chromium plus non-chromium browsers
# whose revisions must NOT leak into the wanted set.
mkdir -p "$TMP/root/pkg/playwright/driver/package"
cat > "$TMP/root/pkg/playwright/driver/package/browsers.json" <<'EOF'
{
  "browsers": [
    {"name": "chromium",               "revision": "1217"},
    {"name": "chromium-headless-shell","revision": "1217"},
    {"name": "chromium-tip-of-tree",   "revision": "1417"},
    {"name": "firefox",                "revision": "1489"},
    {"name": "webkit",                 "revision": "2248"},
    {"name": "ffmpeg",                 "revision": "1011"}
  ]
}
EOF

echo "$TMP/root" > "$TMP/roots"
wanted=$(pw_wanted_revisions "$TMP/roots")
assert_eq "1217
1417" "$wanted" "only chromium* revisions, firefox/webkit/ffmpeg excluded"

# A malformed browsers.json must not crash the scan or blank out the wanted
# set -- a valid sibling browsers.json elsewhere still counts.
mkdir -p "$TMP/root-malformed/ok/playwright/driver/package" \
         "$TMP/root-malformed/bad/playwright/driver/package"
cat > "$TMP/root-malformed/ok/playwright/driver/package/browsers.json" <<'EOF'
{"browsers": [{"name": "chromium", "revision": "9999"}]}
EOF
echo '{not valid json' > "$TMP/root-malformed/bad/playwright/driver/package/browsers.json"
echo "$TMP/root-malformed" > "$TMP/roots-malformed"
wanted_malformed=$(pw_wanted_revisions "$TMP/roots-malformed" 2>/dev/null)
malformed_rc=$?
assert_eq "9999" "$wanted_malformed" "malformed browsers.json does not crash the scan, valid sibling still listed"
assert_eq "1" "$malformed_rc" "malformed browsers.json makes the wanted set incomplete (non-zero)"

# Cache dir with one wanted rev and one orphan
mkdir -p "$TMP/cache/chromium-1217" \
         "$TMP/cache/chromium_headless_shell-1217" \
         "$TMP/cache/chromium-1234" \
         "$TMP/cache/chromium_headless_shell-1234" \
         "$TMP/cache/ffmpeg-1011"

PW_ROOTS_FILE="$TMP/roots"
orphans=$(pw_orphan_dirs "$TMP/cache" | sort)
assert_eq "$TMP/cache/chromium-1234
$TMP/cache/chromium_headless_shell-1234" "$orphans" "1234 orphaned, 1217 and ffmpeg kept"

# A cache dir with no trailing revision digits (e.g. a stray non-standard
# name) must not crash the suffix comparison or get misfiled as an orphan.
mkdir -p "$TMP/cache/chromium-tip-of-tree"
PW_ROOTS_FILE="$TMP/roots"
orphans_suffix=$(pw_orphan_dirs "$TMP/cache" | sort)
assert_eq "$TMP/cache/chromium-1234
$TMP/cache/chromium_headless_shell-1234" "$orphans_suffix" "non-numeric suffix dir ignored, same orphans as before"

# Empty wanted set must delete nothing (safety valve)
echo "$TMP/empty-root" > "$TMP/roots-empty"
mkdir -p "$TMP/empty-root"
PW_ROOTS_FILE="$TMP/roots-empty"
assert_eq "" "$(pw_orphan_dirs "$TMP/cache")" "no installed playwright -> no deletions"

# One clean scans for installed playwrights once. The scan walks every root,
# a /mnt projects dir included, and used to run two or three times per clean
# (estimate, apply, re-measure), which is what the removed cache file was for.
mkdir -p "$TMP/once-cache/chromium-1234"
echo x > "$TMP/once-cache/chromium-1234/blob"
printf '%s pw-orphan - yes\n' "$TMP/once-cache" > "$TMP/once.conf"
eval "$(declare -f pw_wanted_revisions | sed '1s/pw_wanted_revisions/_orig_pw_wanted_revisions/')"
pw_wanted_revisions() { echo x >> "$TMP/once-scans"; _orig_pw_wanted_revisions "$@"; }
: > "$TMP/once-scans"
PW_ROOTS_FILE="$TMP/roots"
DRY_RUN=0
clean_run "$TMP/once.conf" 0 >/dev/null 2>&1
assert_eq "1" "$(wc -l < "$TMP/once-scans")" "one clean scans for installed playwrights once"
assert_fails "[ -e \"$TMP/once-cache/chromium-1234\" ]" "the orphan was still removed"
eval "$(declare -f _orig_pw_wanted_revisions | sed '1s/_orig_pw_wanted_revisions/pw_wanted_revisions/')"
unset -f _orig_pw_wanted_revisions

# B1 fail-closed: an incomplete wanted set must delete nothing. The cache
# below holds chromium-1234, which no fixture pins, next to the pinned 1217;
# with a complete scan 1234 would be an orphan, so an empty answer here proves
# the prune was skipped, not that nothing qualified.

# (a) One real root plus one root that does not exist (e.g. /mnt/d unmounted).
printf '%s\n%s\n' "$TMP/root" "$TMP/not-mounted" > "$TMP/roots-missing"
PW_ROOTS_FILE="$TMP/roots-missing"
missing_out=$(pw_orphan_dirs "$TMP/cache" 2>"$TMP/missing.err")
assert_eq "" "$missing_out" "missing scan root -> no orphan dirs (fail closed)"
assert_contains "$(cat "$TMP/missing.err")" "$TMP/not-mounted" "missing scan root is named in the warning"
assert_contains "$(cat "$TMP/missing.err")" "skipping orphan prune" "missing scan root warning says the prune was skipped"

# A later call in the same process, once the root is back, must rescan rather
# than reuse anything from the failed run.
mkdir -p "$TMP/not-mounted"
recovered=$(pw_orphan_dirs "$TMP/cache" 2>/dev/null | sort)
assert_eq "$TMP/cache/chromium-1234
$TMP/cache/chromium_headless_shell-1234" "$recovered" "root back -> prune resumes, nothing stale reused"
rmdir "$TMP/not-mounted"

# (b) One browsers.json that jq cannot parse, next to a valid one.
printf '%s\n%s\n' "$TMP/root" "$TMP/root-malformed" > "$TMP/roots-jqfail"
PW_ROOTS_FILE="$TMP/roots-jqfail"
jqfail_out=$(pw_orphan_dirs "$TMP/cache" 2>"$TMP/jqfail.err")
assert_eq "" "$jqfail_out" "unparseable browsers.json -> no orphan dirs (fail closed)"
assert_contains "$(cat "$TMP/jqfail.err")" "$TMP/root-malformed/bad/playwright/driver/package/browsers.json" "unparseable browsers.json is named in the warning"

# (c) find itself failing inside a root (unreadable subdir). Skipped as root,
# where permissions don't bite.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMP/root-unreadable/locked"
  chmod 000 "$TMP/root-unreadable/locked"
  printf '%s\n%s\n' "$TMP/root" "$TMP/root-unreadable" > "$TMP/roots-findfail"
  PW_ROOTS_FILE="$TMP/roots-findfail"
  findfail_out=$(pw_orphan_dirs "$TMP/cache" 2>"$TMP/findfail.err")
  chmod 755 "$TMP/root-unreadable/locked"
  assert_eq "" "$findfail_out" "find error inside a root -> no orphan dirs (fail closed)"
  assert_contains "$(cat "$TMP/findfail.err")" "$TMP/root-unreadable" "find error names the root in the warning"
fi

# Default roots (no PW_ROOTS_FILE): a missing $HOME root means "nothing
# installed there" and is skipped; a missing drive root fails closed only when
# the drive itself looks unmounted. HOME and PW_MNT_BASE point into $TMP, and
# PW_MOUNTPOINT_CMD fakes the mount probe, so the real /mnt is never consulted.
# Only $HOME/tools exists; the other four $HOME roots are missing.
unset PW_ROOTS_FILE
FAKE_HOME="$TMP/home"
FAKE_MNT="$TMP/mnt"
mkdir -p "$FAKE_HOME/tools/pkg/playwright/driver/package"
cp "$TMP/root/pkg/playwright/driver/package/browsers.json" "$FAKE_HOME/tools/pkg/playwright/driver/package/"
EXPECT_1234="$TMP/cache/chromium-1234
$TMP/cache/chromium_headless_shell-1234"

# default_case DRIVE_STATE MOUNT_CMD [EXTRA_ROOTS] [HOME] -> sets d_out / d_err
#   DRIVE_STATE: absent | empty | full (drive dir has entries, nothing else)
#   EXTRA_ROOTS: pw_scan_roots_extra in a maint.conf, "-" (the default) for none.
#   HOME: defaults to $FAKE_HOME; the drive cases put it on the fake D: drive.
default_case() {
  local extra="${3:--}" home="${4:-$FAKE_HOME}"
  rm -rf "$FAKE_MNT"; mkdir -p "$FAKE_MNT"
  case "$1" in
    empty) mkdir -p "$FAKE_MNT/d" ;;
    full)  mkdir -p "$FAKE_MNT/d/other" ;;
  esac
  if [ "$extra" = "-" ]; then
    : > "$TMP/pw.conf"
  else
    printf 'pw_scan_roots_extra = %s\n' "$extra" > "$TMP/pw.conf"
  fi
  config_load "$TMP/pw.conf" 1
  d_out=$(HOME="$home" PW_MNT_BASE="$FAKE_MNT" PW_MOUNTPOINT_CMD="$2" \
          pw_orphan_dirs "$TMP/cache" 2>"$TMP/default.err" | sort)
  d_err=$(cat "$TMP/default.err")
  config_defaults
}

# Built-in roots are all under $HOME: an empty (unmounted-looking) D: drive
# does not block the prune when no root lives there.
default_case empty false
assert_eq "$EXPECT_1234" "$d_out" "built-in roots only: an unmounted D: drive does not block the prune"
assert_eq "" "$d_err" "built-in roots only: nothing to warn about"

# An extra root pins what it holds; roots are ':'-separated.
mkdir -p "$TMP/extra-a/pkg/playwright/driver/package" "$TMP/extra-b"
echo '{"browsers": [{"name": "chromium", "revision": "1234"}]}' \
  > "$TMP/extra-a/pkg/playwright/driver/package/browsers.json"
default_case full true "$TMP/extra-b:$TMP/extra-a"
assert_eq "" "$d_out" "pw_scan_roots_extra: a browser pinned under the second extra root is not an orphan"

# A missing extra root fails closed, on a mounted drive or off any drive: the
# user named it, so it is expected to hold installs, and skipping it would
# orphan what it pins. Same rule as a PW_ROOTS_FILE root.
default_case full true "$TMP/no-such-extra"
assert_eq "" "$d_out" "pw_scan_roots_extra: a missing extra root blocks the prune"
assert_contains "$d_err" "$TMP/no-such-extra" "pw_scan_roots_extra: the missing extra root is named"
assert_contains "$d_err" "pw_scan_roots_extra" "pw_scan_roots_extra: the warning names the key to fix"
default_case full true "$FAKE_MNT/d/work/projects"
assert_eq "" "$d_out" "pw_scan_roots_extra: a missing extra root on a mounted drive blocks the prune too"

# Built-in roots on a drive ($HOME on the fake D:, all of them missing; the
# existing extra root $TMP/root pins 1217): a missing built-in root is skipped
# while the drive is mounted, and fails closed when the drive looks unmounted.
DRIVE_HOME="$FAKE_MNT/d/home"
default_case full true "$TMP/root" "$DRIVE_HOME"
assert_eq "$EXPECT_1234" "$d_out" "built-in roots on a mounted drive: missing ones are skipped, prune runs"
assert_eq "" "$d_err" "built-in roots on a mounted drive: skipped silently"

default_case empty true "$TMP/root" "$DRIVE_HOME"
assert_eq "" "$d_out" "built-in roots: drive dir empty (unmounted) -> no orphan dirs"
assert_contains "$d_err" "$FAKE_MNT/d" "built-in roots: empty drive is named in the warning"

default_case full false "$TMP/root" "$DRIVE_HOME"
assert_eq "" "$d_out" "built-in roots: drive not a mountpoint -> no orphan dirs"
assert_contains "$d_err" "skipping orphan prune" "built-in roots: not-a-mountpoint warning says prune was skipped"

default_case absent true "$TMP/root" "$DRIVE_HOME"
assert_eq "" "$d_out" "built-in roots: drive dir absent -> no orphan dirs"

# mountpoint(1) unavailable: fall back to the emptiness check alone.
default_case full "$TMP/no-such-mountpoint-cmd" "$TMP/root" "$DRIVE_HOME"
assert_eq "$EXPECT_1234" "$d_out" "built-in roots, no mountpoint cmd: non-empty drive -> prune runs"
default_case empty "$TMP/no-such-mountpoint-cmd" "$TMP/root" "$DRIVE_HOME"
assert_eq "" "$d_out" "built-in roots, no mountpoint cmd: empty drive -> no orphan dirs"

# An existing but unreadable default root still fails closed.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$FAKE_HOME/.nvm"; chmod 000 "$FAKE_HOME/.nvm"
  default_case full true
  chmod 755 "$FAKE_HOME/.nvm"; rmdir "$FAKE_HOME/.nvm"
  assert_eq "" "$d_out" "default roots: unreadable \$HOME root -> no orphan dirs"
  assert_contains "$d_err" "$FAKE_HOME/.nvm" "default roots: unreadable root named in the warning"
fi

echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
