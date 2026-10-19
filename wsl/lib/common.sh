#!/usr/bin/env bash
# Shared helpers. Sourced, never executed directly.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DRY_RUN="${DRY_RUN:-0}"

log_info() { echo "[info] $*" >&2; }
log_warn() { echo "[warn] $*" >&2; }
log_err()  { echo "[err ] $*" >&2; }

# The one consent rule, shared with win\Common.ps1 Test-MaintConsent: "y" or
# "yes" in any case, surrounding whitespace ignored. Anything else is a no.
is_consent() {
  local a="${1:-}"
  a="${a#"${a%%[![:space:]]*}"}"
  a="${a%"${a##*[![:space:]]}"}"
  case "${a,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

human() {
  local b="${1:-0}"
  numfmt --to=iec --format='%.1f' "$b" 2>/dev/null || echo "${b}B"
}

dir_bytes() {
  local p="$1" out
  [ -e "$p" ] || { echo 0; return 0; }
  out=$(du -sxb "$p" 2>/dev/null | cut -f1)
  case "$out" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$out" ;;
  esac
}

# Lexical path normalization: collapses repeated slashes, drops "." and
# resolves ".." against the preceding segment. Deliberately not `realpath`,
# which would follow symlinks and change what the guard below means.
lexical_path() {
  local path="$1" seg out=""
  local -a parts stack=()
  # read -d '' always returns 1 here (no NUL in the input); `|| true` keeps
  # that from killing a `set -e` caller.
  IFS=/ read -rd '' -a parts < <(printf '%s' "$path") || true
  for seg in "${parts[@]}"; do
    case "$seg" in
      ''|.) ;;
      ..)
        if [ "${#stack[@]}" -gt 0 ] && [ "${stack[-1]}" != ".." ]; then
          unset 'stack[-1]'
        elif [ "${path:0:1}" != "/" ]; then
          stack+=("..")
        fi
        ;;
      *) stack+=("$seg") ;;
    esac
  done
  for seg in "${stack[@]}"; do out+="/$seg"; done
  if [ "${path:0:1}" = "/" ]; then
    echo "${out:-/}"
  else
    echo "${out#/}"
  fi
}

# $HOME as the guard compares it: lexical_path is applied to every
# TARGET, so the patterns must be built from the same shape. A raw HOME with
# a trailing slash (`/home/u/`, straight from /etc/passwd or an exported
# launcher value), `//` or `/.` gave patterns like `/home/u//.ssh` that no
# normalised target ever matched, and ~/.ssh, ~/.gnupg, ~/.config and the
# memory dirs were silently unprotected.
_MAINT_HOME=$(lexical_path "$HOME")
_MAINT_HOME="${_MAINT_HOME%/}"

# Paths that must never be deleted, regardless of rules.conf.
# Matched as the path itself or any path beneath it.
# Only the test suite may modify this array (it appends sandbox paths). Production
# code must never add, drop or reorder entries: the guard would keep reporting
# success over a shrunken list. Not `readonly` because the tests need to append.
PROTECTED_PATTERNS=(
  "$_MAINT_HOME/.ssh"
  "$_MAINT_HOME/.gnupg"
  "$_MAINT_HOME/.config"
  "$_MAINT_HOME/.claude/projects/*/memory"
  # The author's own code and project dirs. Not part of the design: on another
  # box they usually do not exist and protect nothing, which is harmless.
  "$_MAINT_HOME/scripts"
  "$_MAINT_HOME/work"
  "$_MAINT_HOME/tools"
  # Windows drives (/mnt/c, /mnt/d, ...) are NOT listed here: a glob entry
  # would be expanded by is_protected's ancestor loop, a readdir of /mnt on
  # every call. is_protected checks them with a `case` instead.
  "/etc"
  # "/" is deliberately NOT listed: `${p%/}` would reduce it to the empty
  # string and it would be skipped by the `[ -n "$p" ]` guard below anyway.
  # "/" is refused by the empty-target guard in is_protected instead. Making a
  # "/" prefix rule actually work here would be wrong, not just redundant: it
  # would match every path on the system and make rules.conf's
  # /var/log/journal row (and every other absolute-path rule) undeletable.
)

is_protected() {
  # Normalized first: `//` and `$HOME/../<user>/.ssh` must not walk around
  # the textual comparisons below. "/" itself reduces to the empty string.
  # Lexical only: a symlinked segment before a `..` still resolves elsewhere
  # in the kernel than here (a known limit, not handled).
  local target
  target=$(lexical_path "$1")
  target="${target%/}"
  [ -n "$target" ] || return 0
  # Every Windows drive WSL mounts (drvfs: /mnt/c, /mnt/d, /mnt/e, ...), and
  # /mnt itself as their ancestor. One letter only, so WSL's own /mnt/wsl and
  # /mnt/wslg are not matched. Pure string test: no readdir of /mnt.
  case "$target" in
    /mnt|/mnt/[a-z]|/mnt/[a-z]/*) return 0 ;;
  esac
  # Only for the glob-expansion loop at the bottom of this function: an
  # unquoted "$p" is field-split before it is pathname-expanded, so a pattern
  # (or a $HOME) containing whitespace would otherwise be split into fragments
  # that glob onto nothing and silently protect nothing. Newline-only IFS is
  # local to this function and restored on return.
  local IFS=$'\n'
  local p m
  for p in "${PROTECTED_PATTERNS[@]}"; do
    p="${p%/}"
    [ -n "$p" ] || continue
    # $p is matched unquoted so any glob metacharacters it carries
    # (e.g. the wildcard project dir in the memory pattern) act as
    # wildcards here, at call time, rather than being expanded once
    # against whatever happens to exist on disk when this file is sourced.
    case "$target" in
      $p|$p/*) return 0 ;;
    esac
    # ...and the other direction: refuse a target that is an ANCESTOR of a
    # protected path. Without this, `--rules` pointed at a file containing
    # "/home purge - yes" yields target /home/<user>, which matches none of the
    # patterns above yet would take ~/.ssh, ~/work and ~/tools with it. The
    # plan's constraint is that the guard always wins over rules.conf; before
    # this it only won in one direction.
    #
    # $target is quoted here, so the pattern is the SUBJECT of this case and
    # any "*" it carries is a literal character rather than a wildcard. That
    # makes this branch exact for the literal patterns and BLIND for the
    # globbed one: with p=$HOME/.claude/projects/*/memory and
    # target=$HOME/.claude/projects/-mnt-d, the subject's literal "*" does not
    # match "-mnt-d" and the ancestor is wrongly reported deletable -- even
    # though rm -rf on it destroys the protected memory dir underneath. That is
    # under-inclusive, i.e. the UNSAFE direction, which is why the next branch
    # exists. (Do not restate this as "refuses more, never fewer": it does not.)
    case "$p" in
      "$target"/*) return 0 ;;
    esac
    # Globbed patterns, ancestor direction. Expand the pattern against the
    # filesystem and refuse the target if any REAL match sits beneath it. Only
    # paths that actually exist can be lost, so expanding is enough to close
    # the hole, and it keeps the refusal as narrow as the data justifies: a
    # ~/.claude/projects/<proj> dir with no memory/ inside stays deletable, so
    # an auto=no session-pruning rule run under --sessions still works.
    #
    # `for m in $p` is deliberately unquoted (that is the expansion). With no
    # nullglob -- and this file must not set shell options as a side effect of
    # being sourced -- an unmatched pattern expands to ITSELF, so the `[ -e ]`
    # test below is what discards it; a literal path containing "*" does not
    # exist. Skipped entirely for patterns with no metacharacter, both to save
    # the syscalls and because those are already fully handled above.
    case "$p" in
      *[*?[]*)
        for m in $p; do
          # -L too: a dangling memory/ symlink still means someone meant
          # something to live there, and -e alone follows it and fails.
          [ -e "$m" ] || [ -L "$m" ] || continue
          case "$m" in
            "$target"/*) return 0 ;;
          esac
        done
        ;;
    esac
  done
  return 1
}

# safe_rm PATH -- the only sanctioned deletion path in this codebase.
safe_rm() {
  local target="$1"
  # A relative target resolves against the cwd, and maint runs from ~ or
  # /mnt/c/WINDOWS/system32: a stray bare name from a split target list once
  # meant `rm -rf victim` there. Every caller passes absolute paths.
  case "$target" in
    /*) ;;
    *) log_err "refusing to delete non-absolute path: $(printf '%q' "$target")"; return 1 ;;
  esac
  if is_protected "$target"; then
    log_err "refusing to delete protected path: $target"
    return 1
  fi
  [ -e "$target" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY $target"
  else
    # Tested, not followed by a bare echo: the echo's status used to be the
    # function's, so a target rm only half deleted logged RM and returned 0.
    if ! rm -rf -- "$target"; then
      log_warn "could not fully delete $target"
      return 1
    fi
    echo "RM $target"
  fi
}

# The WSL-side `docker` can be installed while its socket is dead (Docker
# Desktop running with the integration not yet attached); docker.exe still
# reaches the daemon then. Prints the first client that answers.
# Callers name DOCKER_CANDIDATES in their "not reachable" message, so set it
# once here rather than repeating the default list in each message.
DOCKER_CANDIDATES="${DOCKER_CANDIDATES:-docker docker.exe}"
docker_cmd() {
  local c
  for c in $DOCKER_CANDIDATES; do
    command -v "$c" >/dev/null 2>&1 || continue
    timeout 20 "$c" info >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}
