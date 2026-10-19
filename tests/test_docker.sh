#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./assert.sh
. ../wsl/lib/common.sh
. ../wsl/lib/config.sh
. ../wsl/lib/docker.sh

# Exit 0 when at least one name on stdin is guarded. Test-only predicate; the
# prune itself uses docker_guarded, which fails loudly on a grep error.
docker_guard_trips() { local m; m=$(docker_guarded) && [ -n "$m" ]; }

assert_fails "printf 'a1b2c3\nd4e5f6\n' | docker_guard_trips" "opaque hashes pass"
assert_ok "printf 'a1b2c3\ntest-db-data\n' | docker_guard_trips" "db-data trips"
assert_ok "printf 'MYSQL-DATA\n' | docker_guard_trips" "case insensitive"
assert_ok "printf 'redis_cache\n' | docker_guard_trips" "redis trips"
for name in postgres_data app-pgdata mongo-db mariadb_vol; do
  assert_ok "printf '%s\n' $name | docker_guard_trips" "built-in guard: $name trips"
done
assert_fails "printf 'myapp_db\n' | docker_guard_trips" "a project name is not guarded without docker_guard_extra"

# docker_guard_extra in maint.conf is appended to the built-in guard.
TMPC=$(mktemp -d)
printf 'docker_guard_extra = myapp|acme\n' > "$TMPC/guard.conf"
config_load "$TMPC/guard.conf" 1
assert_ok "printf 'myapp_db\n' | docker_guard_trips" "docker_guard_extra: myapp trips"
assert_ok "printf 'ACME-cache\n' | docker_guard_trips" "docker_guard_extra: case insensitive"
assert_ok "printf 'redis_cache\n' | docker_guard_trips" "docker_guard_extra keeps the built-in names"
assert_eq "a1b2c3" "$(printf 'a1b2c3\nmyapp_db\n' | docker_unguarded)" "docker_guard_extra: unguarded list drops the extra names"
printf 'docker_guard_extra = myapp(\n' > "$TMPC/badre.conf"
rc=0; err=$(config_load "$TMPC/badre.conf" 1 2>&1) || rc=$?
assert_eq "2" "$rc" "docker_guard_extra that is not a valid regex is refused"
assert_contains "$err" "$TMPC/badre.conf:1" "bad docker_guard_extra names file:line"
config_defaults
rm -rf "$TMPC"
assert_fails "printf '' | docker_guard_trips" "empty list passes"

# --- docker_prune integration, via a fake `docker` shim on PATH ---
# No real docker daemon is ever invoked here. The shim directory is always
# put ahead of the real PATH (never used alone with the real PATH appended
# after it), so the lookup for the literal name "docker" can only ever
# resolve to our shim (or, in the last case below, to nothing) -- never to
# the real docker binary. This must be structurally guaranteed, not merely
# likely: this box has a live, reachable Docker daemon, so any ordering
# mistake here runs real docker commands (found out the hard way while
# writing this test -- see task-5 report, and again: an earlier draft of
# `docker_prune` filtered on a Docker-Desktop-only label that is always
# empty on Docker Engine under WSL, which is why the filter changed to
# `dangling=true` and why these tests now assert on the literal flag the
# shim receives, not just on behaviour). The real PATH stays reachable for
# coreutils (grep/cat/wc/...) that docker_prune and the shim both need;
# only "docker" itself is ever intercepted. A shim script records every
# invocation to FAKE_DOCKER_CALLS and serves fixture data from
# FAKE_DOCKER_DANGLING_FILE.
# Anonymous volume names are 64 hex digits; only those are pruned by default.
V1=$(printf 'a%.0s' {1..64}); V2=$(printf 'b%.0s' {1..63}; printf 'c'); V3=$(printf '0123456789abcdef%.0s' 1 2 3 4)
REAL_PATH="$PATH"
# Same guarantee for the docker.exe fallback: WSL interop puts the real
# docker.exe on PATH, so only the literal shim name "docker" is a candidate
# unless a test names another one explicitly.
export DOCKER_CANDIDATES=docker
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/empty-bin"
export FAKE_DOCKER_CALLS="$TMP/calls.log"
# Never truncated: every verb the shim ever saw, for the whitelist check at the end.
export FAKE_DOCKER_ALL_CALLS="$TMP/all-calls.log"
export FAKE_DOCKER_DANGLING_FILE="$TMP/dangling.txt"
export FAKE_DOCKER_SURVIVORS_FILE="$TMP/survivors.txt"
export FAKE_DOCKER_PRUNED_MARK="$TMP/pruned.mark"
: > "$FAKE_DOCKER_SURVIVORS_FILE"
cat > "$TMP/bin/docker" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >> "$FAKE_DOCKER_CALLS"
echo "$*" >> "$FAKE_DOCKER_ALL_CALLS"
case "$1" in
  info) exit 0 ;;
  system)
    # Real `docker system df --format '{{json .}}'` output shape on this
    # box's Docker 29.7.2: one JSON object per resource-type row. Build
    # Cache's size is deliberately distinct from every other row's size
    # below so a test asserting on it can't pass by coincidence.
    cat <<'JSON'
{"Active":"6","Reclaimable":"2.985GB (37%)","Size":"7.937GB","TotalCount":"12","Type":"Images"}
{"Active":"6","Reclaimable":"0B (0%)","Size":"182.3MB","TotalCount":"6","Type":"Containers"}
{"Active":"2","Reclaimable":"5.001GB (29%)","Size":"16.89GB","TotalCount":"6","Type":"Local Volumes"}
JSON
    # After a successful `builder prune` the Build Cache row reports what is
    # left, so a test can tell a before reading from an after reading.
    if [ -e "$FAKE_DOCKER_PRUNED_MARK" ]; then
      echo '{"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Build Cache"}'
    else
      echo '{"Active":"0","Reclaimable":"512.3MB (100%)","Size":"512.3MB","TotalCount":"3","Type":"Build Cache"}'
    fi
    exit 0 ;;
  builder)
    rc="${FAKE_DOCKER_BUILDER_RC:-0}"
    [ "$rc" = "0" ] && : > "$FAKE_DOCKER_PRUNED_MARK"
    exit "$rc" ;;
  volume)
    case "$2" in
      # FAKE_DOCKER_LS_RC makes the listing itself fail (daemon gone mid-run,
      # or the 60s timeout firing).
      ls) [ "${FAKE_DOCKER_LS_RC:-0}" = "0" ] || exit "$FAKE_DOCKER_LS_RC"
          cat "$FAKE_DOCKER_DANGLING_FILE" 2>/dev/null; exit 0 ;;
      # `docker volume rm` with a partial failure removes what it can and still
      # exits non-zero; FAKE_DOCKER_SURVIVORS_FILE names what it could not
      # remove, which is what the `inspect` probe below then reports.
      rm) exit "${FAKE_DOCKER_RM_RC:-0}" ;;
      inspect) grep -qxF "$3" "$FAKE_DOCKER_SURVIVORS_FILE" 2>/dev/null && exit 0; exit 1 ;;
    esac
    ;;
esac
# Anything else is a verb docker_prune must not issue (README: "Never: Docker
# images"); fail loudly rather than pretend it worked.
echo "fake docker: unexpected verb: $*" >&2
exit 2
SHIM
chmod +x "$TMP/bin/docker"
# $TMP/bin first so the shim wins the lookup for "docker" specifically;
# the real PATH stays appended so coreutils (grep/cat/wc/...) used by
# docker_prune and by the shim itself keep resolving normally. Only the
# name "docker" is intercepted.
export PATH="$TMP/bin:$REAL_PATH"
# Volume removal asks first; the confirmation itself is tested near the end.
export ASSUME_YES=1

# Opaque dangling-volume names: guard does not trip, docker_prune actually
# removes them. Also assert on the exact flag the shim was invoked with --
# this is the regression check for the label -> dangling=true fix: a silent
# revert to the dead `label=com.docker.volume.anonymous` filter must fail
# this test.
printf "${V1}\n${V2}\n" > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
out=$(docker_prune)
assert_contains "$(cat "$FAKE_DOCKER_CALLS")" "volume ls -q -f dangling=true" "volume ls is invoked with dangling=true, not the dead label filter"
assert_contains "$out" "PRUNED 2 dangling volumes" "clean dangling volumes get pruned"
assert_contains "$(cat "$FAKE_DOCKER_CALLS")" "volume rm ${V1} ${V2}" "volume rm invoked with the opaque names"

# --- named volumes under the opt-in (--named-volumes / docker_named_volumes) ---
# The opt-in makes named volumes candidates, but the name guard still applies.
NAMED_VOLUMES=1

# A guard-tripping name in the dangling set: only that name is kept, the
# rest are still pruned. `dangling=true` surfaces real named volumes (a
# compose stack's db volume goes dangling once its containers are removed),
# so the guarded name must never reach `docker volume rm`. This used to abort
# the whole batch, which on this box meant zero volumes pruned, ever.
printf "${V1}\ntest-db-data\n" > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
out=$(docker_prune 2>"$TMP/guard.err")
rc=$?
assert_ok "grep -qx 'volume rm ${V1}' \"$FAKE_DOCKER_CALLS\"" "unguarded names are pruned next to a guarded one"
assert_fails "grep -q '^volume rm.*test-db-data' \"$FAKE_DOCKER_CALLS\"" "a guarded name never reaches volume rm"
assert_contains "$out" "PRUNED 1 dangling volume" "the count covers only what was pruned"
assert_contains "$(cat "$TMP/guard.err")" "kept guarded volume: test-db-data" "each kept volume is named"
assert_eq "0" "$rc" "keeping a guarded volume is not a failure"

# Every dangling name guarded: nothing to remove, no `volume rm` call at all.
printf 'db-data\npostgres_data\n' > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
err_named=$(docker_prune 2>&1 1>/dev/null)
assert_contains "$err_named" "kept guarded volume: postgres_data" "every guarded name is listed"
assert_fails "grep -q '^volume rm' \"$FAKE_DOCKER_CALLS\"" "an all-guarded dangling list removes nothing"

# Opt-in: an unguarded named volume is pruned, a Compose mysql volume is still
# kept by the guard (built-in `mysql` / `_data`), and so is a
# docker_guard_extra name.
TMPC=$(mktemp -d)
printf 'docker_guard_extra = acme\n' > "$TMPC/guard.conf"
config_load "$TMPC/guard.conf" 1
printf 'myapp_esdata\napp_mysql_data\nacme-files\n' > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
docker_prune >/dev/null 2>"$TMP/optin.err"
config_defaults; rm -rf "$TMPC"
assert_ok "grep -qx 'volume rm myapp_esdata' \"$FAKE_DOCKER_CALLS\"" "opt-in: an unguarded named volume is pruned"
assert_contains "$(cat "$TMP/optin.err")" "kept guarded volume: app_mysql_data" "opt-in: the guard still keeps app_mysql_data"
assert_contains "$(cat "$TMP/optin.err")" "kept guarded volume: acme-files" "opt-in: a docker_guard_extra name is kept"
for name in shop_mysql some_data; do
  assert_ok "printf '%s\n' $name | docker_guard_trips" "built-in guard: $name trips"
done
NAMED_VOLUMES=0

# A grep error inside a name filter must stop the volume prune, not read as
# "no volumes" (which pruned nothing silently) or "nothing guarded". The fake
# breaks only the filter grep it targets; the rest of docker_prune runs.
printf "${V1}\nmyapp_esdata\n" > "$FAKE_DOCKER_DANGLING_FILE"
for target in anon guard; do
  : > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
  if [ "$target" = anon ]; then pat=$DOCKER_ANON_RE; else pat=$(docker_guard_re); fi
  err=$(
    grep() { case " $* " in *" $pat "*) return 2 ;; esac; command grep "$@"; }
    docker_prune 2>&1 >/dev/null
  ); rc=$?
  assert_eq "1" "$rc" "$target filter grep error: docker_prune fails"
  assert_contains "$err" "filter failed; dangling volumes not pruned" "$target filter grep error is reported"
  assert_fails "grep -q '^volume rm' \"$FAKE_DOCKER_CALLS\"" "$target filter grep error: no volume rm"
done

# The maint.conf key is the same opt-in as the flag.
TMPC=$(mktemp -d)
printf 'docker_named_volumes = yes\n' > "$TMPC/named.conf"
config_load "$TMPC/named.conf" 1
printf 'myapp_esdata\n' > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
docker_prune >/dev/null 2>&1
config_defaults
assert_ok "grep -qx 'volume rm myapp_esdata' \"$FAKE_DOCKER_CALLS\"" "docker_named_volumes = yes prunes named volumes"
printf 'docker_named_volumes = maybe\n' > "$TMPC/badnamed.conf"
rc=0; err=$(config_load "$TMPC/badnamed.conf" 1 2>&1) || rc=$?
assert_eq "2" "$rc" "docker_named_volumes other than yes/no is refused"
assert_contains "$err" "$TMPC/badnamed.conf:1" "a bad docker_named_volumes names file:line"
config_defaults; rm -rf "$TMPC"

# Named dangling volumes are kept by default, guard or not: a Compose
# `mysql_data:` volume is `<project>_mysql_data`, dangling after
# `docker compose down`. Only the anonymous (exactly 64 lowercase hex) one is
# pruned: short all-hex names, a 63- or 65-digit one and uppercase hex are
# somebody's names, and a loosened DOCKER_ANON_RE used to pass this file.
HEX63=$(printf 'a%.0s' {1..63}); HEX65=$(printf 'a%.0s' {1..65}); HEX64U=$(printf 'A%.0s' {1..64})
printf "${V1}\napp_mysql_data\nmyapp_esdata\nminio\ncafe\n2024\n${HEX63}\n${HEX65}\n${HEX64U}\n" > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
out=$(docker_prune 2>"$TMP/named.err")
rc=$?
assert_ok "grep -qx 'volume rm ${V1}' \"$FAKE_DOCKER_CALLS\"" "default: only the anonymous volume reaches volume rm"
assert_contains "$out" "PRUNED 1 dangling volume" "default: the count covers the anonymous volume only"
for name in app_mysql_data myapp_esdata minio cafe 2024 "$HEX63" "$HEX65" "$HEX64U"; do
  assert_contains "$(cat "$TMP/named.err")" "kept named volume: $name" "default: $name is kept and reported as named"
done
assert_eq "1" "$(grep -c '^volume rm' "$FAKE_DOCKER_CALLS")" "default: exactly one volume rm call"
# maint.bat users have no --named-volumes flag: the config key must be named.
assert_contains "$(cat "$TMP/named.err")" "--named-volumes" "the kept message names the CLI opt-in"
assert_contains "$(cat "$TMP/named.err")" "docker_named_volumes = yes in maint.conf" "the kept message names the config opt-in"
assert_eq "0" "$rc" "keeping named volumes is not a failure"

# Only named volumes dangling: nothing to remove at all.
printf 'myapp_esdata\nminio\n' > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
docker_prune >/dev/null 2>&1
assert_fails "grep -q '^volume rm' \"$FAKE_DOCKER_CALLS\"" "default: an all-named dangling list removes nothing"

# Dry run with a mixed set: the would-prune count excludes guarded names.
printf "${V1}\n${V2}\nredis_data\n" > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
DRY_RUN=1
out=$(docker_prune 2>/dev/null)
DRY_RUN=0
assert_contains "$out" "DRY docker volume rm (2 dangling volumes)" "dry run counts only unguarded names"

# DRY_RUN must not call `docker volume rm` either, even for a clean set.
printf "${V1}\n" > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
DRY_RUN=1
out=$(docker_prune)
DRY_RUN=0
assert_contains "$out" "DRY docker volume rm (1 dangling volume)" "dry run reports what would be pruned"
assert_fails "echo \"$out\" | grep -q '1 dangling volumes'" "a single volume is not pluralized"
assert_fails "grep -q '^volume rm' \"$FAKE_DOCKER_CALLS\"" "dry run never calls volume rm"

# No dangling volumes at all: docker_prune must not attempt a removal call.
: > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
docker_prune >/dev/null
assert_fails "grep -q '^volume rm' \"$FAKE_DOCKER_CALLS\"" "no dangling volumes -> no volume rm call"

# Regression: `docker system df --format '{{.BuildCacheSize}}'` is not a
# valid template on Docker 29.7.2 -- `system df` renders once per
# resource-type row (Images/Containers/Local Volumes/Build Cache), and none
# of those rows has a `.BuildCacheSize` field, so the old template failed
# outright ("can't evaluate field BuildCacheSize"). Because that failure was
# captured into an unvalidated bare assignment with stderr silenced, its
# non-zero exit reached `set -e` in the caller (maint) and killed the whole
# `docker` subcommand before it did anything. The fix reads `{{json .}}`
# instead (one JSON object per row) and selects the Build Cache row's own
# Size field. Pinned against this box's real output shape (see the shim's
# `system` case above).
printf "${V1}\n" > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
info=$(docker_prune 2>&1 1>/dev/null)
assert_contains "$info" "docker build cache before: 512.3MB" "build cache size is read from the Build Cache row's own Size field, not a nonexistent .BuildCacheSize"
# ...and re-read after the prune, so the log shows what was reclaimed.
assert_contains "$info" "docker build cache: 512.3MB -> 0B" "build cache is measured again after the prune"
rm -f "$FAKE_DOCKER_PRUNED_MARK"

# A dry run prunes nothing, so it must not log an after reading.
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
DRY_RUN=1
info=$(docker_prune 2>&1 1>/dev/null)
DRY_RUN=0
assert_fails "echo \"$info\" | grep -q -- '->'" "dry run logs no before -> after line"

# A single opaque volume pruned for real reads "1 dangling volume".
rm -f "$FAKE_DOCKER_PRUNED_MARK"
printf "${V1}\n" > "$FAKE_DOCKER_DANGLING_FILE"
out=$(docker_prune 2>/dev/null)
rm -f "$FAKE_DOCKER_PRUNED_MARK"
assert_contains "$out" "PRUNED 1 dangling volume" "single pruned volume"
assert_fails "echo \"$out\" | grep -q '1 dangling volumes'" "single pruned volume is not pluralized"

# --- a prune that failed must not print PRUNED ---
# Regression: "PRUNED build cache" was echoed unconditionally, one line after
# the `|| log_warn` that admitted the prune had failed, so the verb reported
# the outcome it intended rather than the one it got -- and docker_prune still
# exited 0, which is the only thing the Windows side inspects.
: > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
export FAKE_DOCKER_BUILDER_RC=1
out=$(docker_prune 2>/dev/null)
rc=$?
unset FAKE_DOCKER_BUILDER_RC
assert_fails "echo \"$out\" | grep -q 'PRUNED build cache'" "a failed builder prune does not claim PRUNED"
assert_eq "1" "$rc" "a failed builder prune makes docker_prune exit non-zero"

# A partial `docker volume rm`: the count printed must be the number actually
# gone, asked of the daemon, not the number that was requested.
printf "${V1}\n${V2}\n${V3}\n" > "$FAKE_DOCKER_DANGLING_FILE"
printf "${V3}\n" > "$FAKE_DOCKER_SURVIVORS_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
export FAKE_DOCKER_RM_RC=1
out=$(docker_prune 2>"$TMP/prune.err")
rc=$?
err=$(cat "$TMP/prune.err")
unset FAKE_DOCKER_RM_RC
: > "$FAKE_DOCKER_SURVIVORS_FILE"
assert_contains "$out" "PRUNED 2 dangling volumes" "a partial volume prune reports the two that are really gone, not all three"
assert_contains "$err" "1 of 3 still present" "the survivor is named in the warning"
assert_eq "1" "$rc" "a partial volume prune makes docker_prune exit non-zero"

# A failed `volume ls` is not "no dangling volumes". Under maint's `set -e`
# it used to kill the verb silently (stderr to /dev/null, state_mark_run
# skipped); without set -e it logged "no dangling volumes" and exited 0.
# Both modes must exit 1 with a line naming the failure.
printf "${V1}\n" > "$FAKE_DOCKER_DANGLING_FILE"
export FAKE_DOCKER_LS_RC=1
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
docker_prune >/dev/null 2>"$TMP/ls.err"
rc=$?
assert_eq "1" "$rc" "a failed volume ls makes docker_prune exit non-zero"
assert_contains "$(cat "$TMP/ls.err")" "docker volume ls failed" "a failed volume ls is named"
assert_fails "grep -q 'no dangling volumes' \"$TMP/ls.err\"" "a failed volume ls is not reported as no dangling volumes"
assert_fails "grep -q '^volume rm' \"$FAKE_DOCKER_CALLS\"" "a failed volume ls removes nothing"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
( set -e; docker_prune; echo "after-prune" ) >"$TMP/ls-e.out" 2>"$TMP/ls-e.err"
rc=$?
unset FAKE_DOCKER_LS_RC
rm -f "$FAKE_DOCKER_PRUNED_MARK"
assert_eq "1" "$rc" "under set -e a failed volume ls still exits 1"
assert_contains "$(cat "$TMP/ls-e.err")" "docker volume ls failed" "under set -e a failed volume ls is not silent"

# Positive control: a clean run of both steps exits 0.
printf "${V1}\n" > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
docker_prune >/dev/null 2>&1
assert_eq "0" "$?" "a fully successful prune exits 0"

# No reachable client: docker_prune must fail, not skip with exit 0, or a
# run that pruned nothing reads as success. PATH points only at an empty
# directory -- not the shim, not the real system PATH -- so no candidate
# resolves here.
PATH="$TMP/empty-bin"
err=$(docker_prune 2>&1 1>/dev/null)
rc=$?
# Back to shim-first, never bare $REAL_PATH: any test after this one would
# otherwise resolve "docker" to the real binary and prune the real daemon.
PATH="$TMP/bin:$REAL_PATH"
assert_contains "$err" "docker not reachable" "an unreachable daemon is named"
assert_eq "1" "$rc" "an unreachable daemon makes docker_prune exit non-zero"

# WSL `docker` absent or dead, docker.exe answering: prune through docker.exe.
# Both names resolve in $TMP/exe-bin first: "docker" there is a dead shim
# that shadows any real /usr/bin/docker, "docker.exe" is the usual fake.
mkdir -p "$TMP/exe-bin"
cp "$TMP/bin/docker" "$TMP/exe-bin/docker.exe"
printf '#!/bin/sh\nexit 1\n' > "$TMP/exe-bin/docker"
chmod +x "$TMP/exe-bin/docker"
printf "${V1}\n" > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
out=$(PATH="$TMP/exe-bin:/usr/bin:/bin" DOCKER_CANDIDATES="docker docker.exe" docker_prune 2>"$TMP/exe.err")
rc=$?
rm -f "$FAKE_DOCKER_PRUNED_MARK"
assert_eq "0" "$rc" "docker.exe fallback prunes cleanly"
assert_contains "$out" "PRUNED build cache" "docker.exe fallback prunes the build cache"
assert_contains "$(cat "$TMP/exe.err")" "WSL docker did not answer; using docker.exe" "the fallback client is logged"

# docker.exe can print CRLF. A volume name read with its trailing \r is a
# name no daemon knows, so `volume rm` would fail and report the prune as
# incomplete. The names must reach `volume rm` stripped.
# Tripwire: everything below must hit the shim, never the real daemon.
[ "$(command -v docker)" = "$TMP/bin/docker" ] || { echo "ABORT: docker is not the shim" >&2; exit 1; }
printf "${V1}\r\n" > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
out=$(docker_prune 2>/dev/null)
rm -f "$FAKE_DOCKER_PRUNED_MARK"
assert_ok "grep -qx 'volume rm ${V1}' \"$FAKE_DOCKER_CALLS\"" "CRLF volume names reach volume rm without the \\r"
assert_contains "$out" "PRUNED 1 dangling volume" "a CRLF listing still prunes cleanly"

# --- confirmation before volume rm ---
printf "${V1}\n" > "$FAKE_DOCKER_DANGLING_FILE"
ASSUME_YES=0

# No terminal: volumes are kept, the build cache prune still runs, exit 0.
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
out=$(docker_prune 2>"$TMP/confirm.err" </dev/null)
rc=$?
assert_fails "grep -q '^volume rm' \"$FAKE_DOCKER_CALLS\"" "no terminal and no --yes removes no volume"
assert_contains "$(cat "$TMP/confirm.err")" "no terminal to confirm" "the kept volumes are explained"
assert_contains "$out" "PRUNED build cache" "the build cache prune does not wait for a yes"
assert_eq "0" "$rc" "an unconfirmed volume prune is not a failure"

# A terminal (faked through the seam): y removes, anything else keeps.
docker_interactive() { return 0; }
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
out=$(echo y | docker_prune 2>/dev/null)
assert_ok "grep -qx 'volume rm ${V1}' \"$FAKE_DOCKER_CALLS\"" "y at the prompt removes the volumes"
assert_contains "$out" "PRUNED 1 dangling volume" "a confirmed prune reports the count"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
echo YES | docker_prune >/dev/null 2>&1
assert_ok "grep -qx 'volume rm ${V1}' \"$FAKE_DOCKER_CALLS\"" "YES at the prompt removes the volumes (is_consent)"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
echo n | docker_prune >/dev/null 2>&1
assert_fails "grep -q '^volume rm' \"$FAKE_DOCKER_CALLS\"" "n at the prompt keeps the volumes"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
docker_prune >/dev/null 2>&1 </dev/null
assert_fails "grep -q '^volume rm' \"$FAKE_DOCKER_CALLS\"" "an empty answer (EOF) keeps the volumes"
rm -f "$FAKE_DOCKER_PRUNED_MARK"

# Through the CLI. Dry run, the shim on PATH, state in $TMP.
# Default: the dry run lists both groups, the anonymous one to prune and the
# named ones kept.
: > "$TMP/empty.conf"
printf "${V1}\nmyapp_db\napp_mysql_data\n" > "$FAKE_DOCKER_DANGLING_FILE"
: > "$FAKE_DOCKER_CALLS"; rm -f "$FAKE_DOCKER_PRUNED_MARK"
rc=0
cli_out=$(STATE_FILE="$TMP/state" ../wsl/maint docker --dry-run --config "$TMP/empty.conf" 2>&1) || rc=$?
assert_eq "0" "$rc" "maint docker --dry-run exits 0"
assert_fails "grep -q '^lastrun.docker=' \"$TMP/state\" 2>/dev/null" "maint docker --dry-run writes no lastrun.docker"
assert_contains "$cli_out" "kept named volume: myapp_db" "maint docker --dry-run lists a named volume as kept"
assert_contains "$cli_out" "kept named volume: app_mysql_data" "maint docker --dry-run lists app_mysql_data as kept"
assert_contains "$cli_out" "  ${V1}" "maint docker --dry-run lists the anonymous volume to prune"
assert_contains "$cli_out" "DRY docker volume rm (1 dangling volume)" "maint docker --dry-run counts only the anonymous one"
# An inherited NAMED_VOLUMES is not the opt-in: only the flag sets it.
cli_out=$(NAMED_VOLUMES=1 STATE_FILE="$TMP/state" ../wsl/maint docker --dry-run --config "$TMP/empty.conf" 2>&1)
assert_contains "$cli_out" "kept named volume: myapp_db" "an exported NAMED_VOLUMES=1 does not opt in"

# --named-volumes: a docker_guard_extra name in maint.conf is still kept, next
# to an unguarded named one that would be pruned.
printf 'docker_guard_extra = myapp\n' > "$TMP/cli-guard.conf"
printf "${V1}\nmyapp_db\nother_cache\n" > "$FAKE_DOCKER_DANGLING_FILE"
rc=0
cli_out=$(STATE_FILE="$TMP/state" ../wsl/maint docker --dry-run --named-volumes --config "$TMP/cli-guard.conf" 2>&1) || rc=$?
assert_eq "0" "$rc" "maint docker --dry-run --named-volumes exits 0"
assert_contains "$cli_out" "kept guarded volume: myapp_db" "--named-volumes keeps a docker_guard_extra volume"
assert_contains "$cli_out" "DRY docker volume rm (2 dangling volumes)" "--named-volumes counts the unguarded named one"
cli_out=$(STATE_FILE="$TMP/state" ../wsl/maint docker --dry-run --named-volumes --config "$TMP/empty.conf" 2>&1)
assert_contains "$cli_out" "DRY docker volume rm (3 dangling volumes)" "without docker_guard_extra the project volume is not guarded"
out=$(../wsl/maint help 2>&1)
assert_contains "$out" "--named-volumes" "help documents --named-volumes"

# --- every verb docker_prune issued, across all the runs above ---
# README "Never: Docker images" / how-it-works "Images are never touched" have
# no other check: the shim used to exit 0 for any verb, so an added
# `image prune -af`, `container prune -f`, `system prune` or a guard-bypassing
# `volume prune -f` passed every assertion above.
stray=$(grep -vxE 'info|system df --format \{\{json \.\}\}|builder prune -af|volume ls -q -f dangling=true|volume rm .*|volume inspect .*' "$FAKE_DOCKER_ALL_CALLS")
assert_eq "" "$stray" "docker_prune issues no verb beyond info / system df / builder prune / volume ls|rm|inspect"
assert_ok "grep -qx 'builder prune -af' \"$FAKE_DOCKER_ALL_CALLS\"" "positive control: the whitelist log saw the build cache prune"

echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
