#!/usr/bin/env bash
# maint.conf reader. Sourced, never executed directly.
#
# Format, shared with the PowerShell half: `key = value` per line, `#` starts a
# comment line, blank lines are ignored, the value is taken literally (outer
# whitespace trimmed, nothing expanded). The file is PARSED, never sourced: it
# lives on a Windows drive and is edited from both sides, so it must not be
# able to run code inside the distro. Empty value = use the default.
set -uo pipefail

# Every key either half reads. The bash half only uses some of them, but an
# unknown key is an error here, so a key valid on Windows must be valid here.
CONFIG_KEYS="distro backup_root keep winclean_age winclean_extra docker_guard_extra docker_named_volumes pw_scan_roots_extra"

# Defaults, overwritten by config_load. CFG_CONFIG_FILE is the file the values
# came from (shown in messages that ask the user to set a key).
config_defaults() {
  CFG_CONFIG_FILE=""
  CFG_DISTRO="Ubuntu"
  CFG_DISTRO_SET=""   # 1 when maint.conf named a distro, not the default
  CFG_BACKUP_ROOT=""
  CFG_KEEP="3"
  CFG_DOCKER_GUARD_EXTRA=""
  CFG_DOCKER_NAMED_VOLUMES="no"
  CFG_PW_SCAN_ROOTS_EXTRA=""
}
config_defaults

# config_load FILE REQUIRED
# REQUIRED=1: the file was named explicitly (--config / WSL_MAINT_CONFIG) and
# must exist. REQUIRED=0: the default location; no file means defaults.
# Returns 2 on any error, after printing file:line.
config_load() {
  local file="$1" required="${2:-0}" line key value n=0
  config_defaults
  CFG_CONFIG_FILE="$file"
  if [ ! -e "$file" ]; then
    [ "$required" = "1" ] || return 0
    log_err "config file not found: $file"
    return 2
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    log_err "config file not readable: $file"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"   # written from Windows, CRLF is normal
    # A BOM is what Notepad and PS 5.1's UTF8 encoding put in front of line 1;
    # Common.ps1 strips it too.
    [ "$n" -eq 1 ] && line="${line#$'\xef\xbb\xbf'}"
    case "${line#"${line%%[![:space:]]*}"}" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) log_err "$file:$n: expected key = value, got: $line"; return 2 ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    # Exact match against each known key: a substring test on the joined
    # list would let "keep docker_guard_extra" through.
    local k known=0
    for k in $CONFIG_KEYS; do
      [ "$key" = "$k" ] && { known=1; break; }
    done
    if [ "$known" -ne 1 ]; then
      log_err "$file:$n: unknown key '$key' (known: $CONFIG_KEYS)"
      return 2
    fi
    [ -n "$value" ] || continue
    case "$key" in
      distro)
        # Same rule and message as Common.ps1: the name ends up in archive
        # file names, so it is held to the characters WSL allows.
        case "$value" in
          *[!A-Za-z0-9._-]*)
            log_err "$file:$n: distro may only contain letters, digits, '.', '_' and '-', got: $value"
            return 2
            ;;
        esac
        CFG_DISTRO="$value"; CFG_DISTRO_SET=1
        ;;
      backup_root) CFG_BACKUP_ROOT="$value" ;;
      keep)
        # Same rule and message as Common.ps1: a whole number from 1 to 1000.
        # Leading zeros are dropped and the length checked before any
        # arithmetic, so a huge value cannot overflow into range.
        local digits
        case "$value" in
          *[!0-9]*) digits="" ;;
          *) digits="${value#"${value%%[!0]*}"}"; digits="${digits:-0}" ;;
        esac
        if [ -z "$digits" ] || [ "${#digits}" -gt 4 ] || [ "$((10#$digits))" -lt 1 ] || [ "$((10#$digits))" -gt 1000 ]; then
          log_err "$file:$n: keep must be a whole number from 1 to 1000, got: $value"
          return 2
        fi
        CFG_KEEP="$((10#$digits))"
        ;;
      winclean_age)
        # Read by the Windows half only (winclean's age gate), validated here
        # with the same rule and message as Common.ps1: the keep check with a
        # range of 1 to 3650 days, so a bad value stops both halves alike.
        local age
        case "$value" in
          *[!0-9]*) age="" ;;
          *) age="${value#"${value%%[!0]*}"}"; age="${age:-0}" ;;
        esac
        if [ -z "$age" ] || [ "${#age}" -gt 4 ] || [ "$((10#$age))" -lt 1 ] || [ "$((10#$age))" -gt 3650 ]; then
          log_err "$file:$n: winclean_age must be a whole number from 1 to 3650, got: $value"
          return 2
        fi
        ;;
      # Read and validated by the Windows half only (winclean's owner patterns,
      # Common.ps1); known here so a file that sets it serves both halves.
      winclean_extra) ;;
      docker_guard_extra)
        # A broken pattern would make every guard grep fail, which reads as
        # "nothing guarded" in one place and "nothing to list" in another.
        # Refuse it here instead. Exit 2 is grep's "bad pattern".
        local grc=0
        printf '' | grep -qiE -- "$value" 2>/dev/null || grc=$?
        if [ "$grc" -eq 2 ]; then
          log_err "$file:$n: docker_guard_extra is not a valid extended regex: $value"
          return 2
        fi
        CFG_DOCKER_GUARD_EXTRA="$value"
        ;;
      docker_named_volumes)
        # Opts in to pruning named dangling volumes, so only an exact yes
        # turns it on; a typo must not read as either answer.
        case "$value" in
          yes|no) CFG_DOCKER_NAMED_VOLUMES="$value" ;;
          *) log_err "$file:$n: docker_named_volumes must be yes or no, got: $value"; return 2 ;;
        esac
        ;;
      pw_scan_roots_extra) CFG_PW_SCAN_ROOTS_EXTRA="$value" ;;
    esac
  done < "$file"
  return 0
}

# Windows drive path -> WSL path, the same rule as ConvertTo-WslPath in
# win/Common.ps1 ("D:\a\b" -> "/mnt/d/a/b"), so both halves agree on where
# backups live. Anything that is not X:\ or X:/ (UNC, relative) is refused.
# MAINT_MNT_BASE is a test seam (default /mnt).
config_wsl_path() {
  local p="$1"
  case "$p" in
    [A-Za-z]:[\\/]*) ;;
    *) return 1 ;;
  esac
  local drive="${p:0:1}" rest="${p:2}"
  printf '%s/%s%s\n' "${MAINT_MNT_BASE:-/mnt}" "$(lc_ascii "$drive")" "${rest//\\//}"
}
