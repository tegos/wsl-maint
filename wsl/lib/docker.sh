#!/usr/bin/env bash
# Docker pruning. Build cache and dangling (unreferenced) volumes only.
# Sourced, never executed.
set -uo pipefail

# Names that must never be pruned, no matter what the dangling-volume list
# contains. By default named volumes are not pruned at all (see
# docker_named_opt_in); under the opt-in this guard is the only thing
# standing between this code and real database volumes: `dangling=true`
# lists every volume not currently attached to a container, INCLUDING named
# ones like "db-data" or "redis" the moment their container stops -- it is
# not restricted to anonymous volumes (see docker_prune below for why the
# label-based filter this used to use never actually matched anything on
# Docker Engine under WSL).
# Generic database names only; project-specific names go in maint.conf
# (docker_guard_extra), which is appended, never substituted.
DOCKER_GUARD_RE='db-data|db_data|mysql|_data|redis|postgres|pgdata|mongo|mariadb'

# The effective guard: built-in names plus docker_guard_extra (config.sh
# validated it as an ERE). Read at call time, so a config loaded after this
# file was sourced still counts.
docker_guard_re() {
  if [ -n "${CFG_DOCKER_GUARD_EXTRA:-}" ]; then
    printf '%s|%s\n' "$DOCKER_GUARD_RE" "$CFG_DOCKER_GUARD_EXTRA"
  else
    printf '%s\n' "$DOCKER_GUARD_RE"
  fi
}

# The name filters below read volume names on stdin. "No match" (grep exit 1)
# is an empty result, not a failure; only grep's own error (exit 2) fails.
docker_filter() {
  grep "$@"
  [ $? -lt 2 ]
}

# Prints the names the guard matches / does not match.
docker_guarded() { docker_filter -iE -- "$(docker_guard_re)"; }
docker_unguarded() { docker_filter -viE -- "$(docker_guard_re)"; }

# Docker gives an anonymous volume a 64-hex-digit name; anything else was
# named by a person or by Compose.
DOCKER_ANON_RE='^[0-9a-f]{64}$'
docker_anonymous() { docker_filter -E -- "$DOCKER_ANON_RE"; }
docker_named() { docker_filter -vE -- "$DOCKER_ANON_RE"; }

# Logs one "kept <what>: <name><note>" line per name in a newline-separated
# list.
docker_log_kept() {
  local what=$1 names=$2 note=${3-} v
  [ -n "$names" ] || return 0
  while IFS= read -r v; do
    log_info "kept $what: $v$note"
  done <<< "$names"
}

# Named dangling volumes are candidates only when asked for: --named-volumes
# (NAMED_VOLUMES=1, set by wsl/maint from the flag only) or
# `docker_named_volumes = yes` in maint.conf.
docker_named_opt_in() {
  [ "${NAMED_VOLUMES:-0}" = "1" ] || [ "${CFG_DOCKER_NAMED_VOLUMES:-no}" = "yes" ]
}

# Seam for the tests: they cannot hand docker_prune a real terminal.
docker_interactive() {
  [ -t 0 ]
}

# Volume removal is the one irreversible step here, so it needs a yes: --yes
# (ASSUME_YES=1), or a y typed at a terminal. With no terminal to ask, the
# volumes are kept and the build cache prune still counts as the run.
docker_confirm_volumes() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  if ! docker_interactive; then
    log_warn "volumes kept: no terminal to confirm; rerun interactively or with --yes"
    return 1
  fi
  local answer=""
  read -r -p "Remove $(dangling_volumes_label "$1")? [y/N] " answer >&2 || true
  is_consent "$answer" && return 0
  log_info "volumes kept: not confirmed"
  return 1
}

# "1 dangling volume" / "2 dangling volumes".
dangling_volumes_label() {
  if [ "$1" -eq 1 ]; then echo "1 dangling volume"; else echo "$1 dangling volumes"; fi
}

# Size of the Build Cache row, or empty if the daemon answers oddly.
# $1 is the docker client to ask (see docker_cmd). Read-only calls get the
# same `timeout` + `tr -d '\r'` as space.sh: docker.exe may print CRLF. The
# prune and rm calls get no timeout, since killing one midway helps nobody.
docker_build_cache_size() {
  timeout 60 "$1" system df --format '{{json .}}' 2>/dev/null | tr -d '\r' \
    | jq -r 'select(.Type == "Build Cache") | .Size' 2>/dev/null \
    | head -1
}

# Non-zero if a prune step was attempted and did not fully succeed, or if no
# docker client reaches a daemon. The unreachable case used to be a 0-exit
# skip, so a run that pruned nothing read as success to the Windows side.
docker_prune() {
  local rc=0 d
  if ! d=$(docker_cmd); then
    log_err "docker not reachable (tried: $DOCKER_CANDIDATES); nothing pruned"
    return 1
  fi
  [ "$d" = "docker" ] || log_info "WSL docker did not answer; using $d"

  # `docker system df --format` renders the template once per resource-type
  # row (Images/Containers/Local Volumes/Build Cache); there is no single
  # ".BuildCacheSize" field on any of those contexts, so that template used
  # to fail outright ("can't evaluate field BuildCacheSize") on Docker
  # 29.7.2 -- and because the failure was masked by `2>/dev/null` inside an
  # unvalidated bare assignment, its non-zero exit reached `set -e` in the
  # caller (maint) and killed the whole `docker` subcommand silently.
  # `{{json .}}` gives one JSON object per row instead, so the Build Cache
  # row's own "Size" field can be picked out directly; `|| true` on the
  # capture and the "${before:-unknown}" fallback below keep this readable
  # (not the destructive) even if the daemon returns something unexpected.
  local before after
  before=$(docker_build_cache_size "$d") || true
  log_info "docker build cache before: ${before:-unknown}"

  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY docker builder prune -af"
  # "PRUNED" used to print unconditionally, one line after the `|| log_warn`
  # that admitted the prune had failed: the verb reported the outcome it
  # intended rather than the one it got.
  elif "$d" builder prune -af >/dev/null 2>&1; then
    echo "PRUNED build cache"
  else
    log_warn "builder prune failed"
    rc=1
  fi
  # Measured after the prune too, failed or not: what was reclaimed is the
  # one number an operator runs this verb for.
  if [ "$DRY_RUN" != "1" ]; then
    after=$(docker_build_cache_size "$d") || true
    log_info "docker build cache: ${before:-unknown} -> ${after:-unknown}"
  fi

  # `label=com.docker.volume.anonymous` is a Docker Desktop-only label; it
  # does not exist on Docker Engine under WSL, so filtering on it here was
  # dead code (verified against this box's real daemon: always empty, even
  # with real named volumes present). `dangling=true` is the real,
  # engine-supported equivalent for "not currently referenced by a
  # container" -- but unlike the label it is NOT anonymous-only, so every
  # name it returns must clear docker_guard_re before anything is removed.
  local dangling
  # A failed or timed-out listing is not "no dangling volumes": as a bare
  # assignment it tripped maint's `set -e` silently (stderr is discarded),
  # and without set -e it read as success.
  if ! dangling=$(timeout 60 "$d" volume ls -q -f dangling=true 2>/dev/null | tr -d '\r'); then
    log_err "docker volume ls failed or timed out; dangling volumes not checked"
    return 1
  fi
  if [ -z "$dangling" ]; then
    log_info "no dangling volumes"
    return "$rc"
  fi

  # Anonymous volumes (64 hex digits) are the leftover garbage. A named one is
  # somebody's data until proven otherwise: Compose names `mysql_data:` as
  # `<project>_mysql_data`, which no name guard can predict, and it is
  # dangling after every `docker compose down`. So named volumes are pruned
  # only behind the explicit opt-in, and even then through the guard.
  local named guarded
  if ! docker_named_opt_in; then
    named=$(printf '%s\n' "$dangling" | docker_named) \
      && dangling=$(printf '%s\n' "$dangling" | docker_anonymous) \
      || { log_err "volume name filter failed; dangling volumes not pruned"; return 1; }
    docker_log_kept "named volume" "$named" \
      " (not pruned without --named-volumes or docker_named_volumes = yes in maint.conf)"
    if [ -z "$dangling" ]; then
      log_info "no anonymous dangling volumes"
      return "$rc"
    fi
  fi

  # Guarded names are skipped one by one rather than aborting the batch: the
  # guarded stacks' volumes are dangling most of the time on this box, so an
  # all-or-nothing abort meant no volume was ever pruned.
  guarded=$(printf '%s\n' "$dangling" | docker_guarded) \
    && dangling=$(printf '%s\n' "$dangling" | docker_unguarded) \
    || { log_err "volume guard filter failed; dangling volumes not pruned"; return 1; }
  docker_log_kept "guarded volume" "$guarded"
  if [ -z "$dangling" ]; then
    log_info "no unguarded dangling volumes"
    return "$rc"
  fi

  local count
  count=$(printf '%s\n' "$dangling" | wc -l)
  printf '%s\n' "$dangling" | sed 's/^/  /' >&2
  # $dangling is split on purpose: one volume name per word.
  # shellcheck disable=SC2086
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY docker volume rm ($(dangling_volumes_label "$count"))"
  elif ! docker_confirm_volumes "$count"; then
    :
  elif "$d" volume rm $dangling >/dev/null 2>&1; then
    echo "PRUNED $(dangling_volumes_label "$count")"
  else
    # Partial failure: `docker volume rm` removes what it can and exits
    # non-zero for the rest, so the full $count was never achieved. Ask the
    # daemon which ones are actually gone instead of printing the number that
    # was requested.
    local left=0
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      if "$d" volume inspect "$v" >/dev/null 2>&1; then left=$((left + 1)); fi
    done <<< "$dangling"
    log_warn "volume prune incomplete: $left of $count still present"
    echo "PRUNED $(dangling_volumes_label "$((count - left))")"
    rc=1
  fi
  return "$rc"
}
