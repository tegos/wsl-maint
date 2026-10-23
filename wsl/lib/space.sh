#!/usr/bin/env bash
# Read-only breakdown of what fills the two vhdx files on C:. Sourced, never
# executed. `audit` only sees the paths in rules.conf; this answers "the vhdx
# grew, by what?" without knowing in advance where to look.
set -uo pipefail

# Overridable so tests never touch the real C: drive or the real registry.
# SPACE_DISTRO_VHDX_GLOB, when unset, is built per distro in space_distro_glob.
SPACE_REG="${SPACE_REG:-reg.exe}"
SPACE_DOCKER_VHDX_GLOB="${SPACE_DOCKER_VHDX_GLOB:-/mnt/c/Users/*/AppData/Local/Docker/wsl/disk/docker_data.vhdx}"
SPACE_TOP="${SPACE_TOP:-12}"

# docker_bytes "16.86GB" -> 16860000000. Docker prints SI units (kB, MB, GB).
docker_bytes() {
  awk -v s="$1" 'BEGIN {
    n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
    m = 1
    if (u == "kB" || u == "KB") m = 1e3
    else if (u == "MB") m = 1e6
    else if (u == "GB") m = 1e9
    else if (u == "TB") m = 1e12
    printf "%.0f\n", n * m
  }'
}

# First existing file matching a glob, or nothing.
space_first_match() {
  local f
  for f in $1; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

# space_vhdx_line LABEL GLOB USED_BYTES -- first match of GLOB, see below.
space_vhdx_line() {
  local f
  if ! f=$(space_first_match "$2"); then
    printf '%-8s %s\n' "$1" "vhdx not found"
    return 0
  fi
  space_file_line "$1" "$f" "$3"
}

# space_distro_name -- whose disk the report shows. maint.conf `distro` when
# set, since that is the disk maint.bat compact acts on; else the distro this
# runs in; else Ubuntu, the same default as the Windows side.
space_distro_name() {
  if [ "${CFG_DISTRO_SET:-}" = "1" ]; then
    echo "$CFG_DISTRO"
  elif [ -n "${WSL_DISTRO_NAME:-}" ]; then
    echo "$WSL_DISTRO_NAME"
  else
    echo "${CFG_DISTRO:-Ubuntu}"
  fi
}

# space_registry_entries -- one "name<TAB>basepath<TAB>vhdfilename" line per
# distro WSL has registered (HKCU\...\Lxss\{guid}), read with reg.exe over
# interop. Non-zero when reg.exe is missing, fails or prints nothing usable.
# reg.exe prints CRLF, and under some codepages NUL-padded (UTF-16-ish)
# bytes; both are stripped before parsing.
space_registry_entries() {
  local raw
  command -v "$SPACE_REG" >/dev/null 2>&1 || return 1
  raw=$(timeout 15 "$SPACE_REG" query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss' /s 2>/dev/null \
    | tr -d '\000\r') || return 1
  [ -n "$raw" ] || return 1
  awk '
    function flush() { if (n != "") printf "%s\t%s\t%s\n", n, b, v; n = b = v = "" }
    /^HKEY_/ { flush(); next }
    {
      line = $0; sub(/^[ \t]+/, "", line)
      i = index(line, "    REG_SZ    ")
      if (!i) next
      key = substr(line, 1, i - 1); val = substr(line, i + 14)
      if (key == "DistributionName") n = val
      else if (key == "BasePath") b = val
      else if (key == "VhdFileName") v = val
    }
    END { flush() }
  ' <<< "$raw"
}

# space_registry_disks DISTRO -- the distro's disk as WSL paths, by the
# rules of Get-DistroVhdxPath in win/Common.ps1 (except that a miss here
# falls back to the glob, where compact says not found): the entry whose
# DistributionName equals DISTRO (case-insensitive), BasePath minus any \\?\
# prefix, plus VhdFileName or ext4.vhdx, kept only if the file exists.
# Returns 1 when the registry is unreadable, has no such distro or names no
# file that exists (the caller then globs: reg.exe output over interop is in
# the console codepage, so a non-ASCII BasePath can arrive mangled).
space_registry_disks() {
  local want="${1,,}" entries name base file p hit=0
  entries=$(space_registry_entries) || return 1
  while IFS=$'\t' read -r name base file; do
    [ "${name,,}" = "$want" ] || continue
    [ -n "$base" ] || continue
    case "$base" in
      '\\?\UNC\'*) continue ;;   # a network share has no /mnt path
      '\\?\'*) base="${base:4}" ;;
    esac
    p=$(config_wsl_path "${base%\\}\\${file:-ext4.vhdx}") || continue
    [ -f "$p" ] && { echo "$p"; hit=1; }
  done <<< "$entries"
  [ "$hit" = 1 ]
}

# space_distro_glob DISTRO -- the fallback when the registry has no answer,
# as on Windows: a Store package folder containing the distro name.
space_distro_glob() {
  echo "${SPACE_DISTRO_VHDX_GLOB:-${MAINT_MNT_BASE:-/mnt}/c/Users/*/AppData/Local/Packages/*$1*/LocalState/ext4.vhdx}"
}

# space_distro_line DISTRO USED_BYTES -- the distro disk line, labelled with
# the distro. Several matching disks are listed, not guessed between. USED
# comes from `df /`, which measures the distro this runs in, so for another
# distro's disk it is shown as unknown.
space_distro_line() {
  local distro="$1" used="$2" disks f n=0
  if ! disks=$(space_registry_disks "$distro"); then
    disks=""
    local had_nocase=0
    shopt -q nocaseglob && had_nocase=1
    shopt -s nocaseglob
    for f in $(space_distro_glob "$distro"); do
      [ -f "$f" ] && disks+="$f"$'\n'
    done
    [ "$had_nocase" = 1 ] || shopt -u nocaseglob
    disks="${disks%$'\n'}"
  fi
  [ -z "$disks" ] || n=$(grep -c '' <<< "$disks")
  if [ "$n" -eq 0 ]; then
    printf '%-8s %s\n' "$distro" "vhdx not found"
    return 0
  fi
  if [ "$n" -gt 1 ]; then
    printf '%-8s %s\n' "$distro" "more than one $distro disk found; not guessing which:"
    sed 's/^/           /' <<< "$disks"
    return 0
  fi
  if [ -n "${WSL_DISTRO_NAME:-}" ] && [ "${WSL_DISTRO_NAME,,}" != "${distro,,}" ]; then
    used=""
  fi
  space_file_line "$distro" "$disks" "$used"
}

# space_file_line LABEL FILE USED_BYTES -- file size, used inside, slack.
space_file_line() {
  local label="$1" f="$2" used="$3" size slack
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ -z "$used" ]; then
    printf '%-8s %9s  used: unknown\n' "$label" "$(human "$size")"
    return 0
  fi
  slack=$(( size > used ? size - used : 0 ))
  printf '%-8s %9s  used %9s  slack up to ~%s\n' \
    "$label" "$(human "$size")" "$(human "$used")" "$(human "$slack")"
}

# The `|| true` after each top-N pipeline: `head` closing early hands `sort`
# a SIGPIPE, pipefail turns that into a non-zero status, and `maint` runs
# under set -e, so the report died after its first table.

# space_top_dirs DIR DEPTH -- biggest directories under DIR, same filesystem.
space_top_dirs() {
  local dir="$1" depth="$2"
  echo "== biggest under ${dir/#$HOME/\~} (depth $depth)"
  du -xb -d "$depth" "$dir" 2>/dev/null \
    | awk -v root="$dir" '$2 != root' \
    | sort -rn | head -n "$SPACE_TOP" \
    | while IFS=$'\t' read -r b p; do
        printf '%9s  %s\n' "$(human "$b")" "${p/#$HOME/\~}"
      done || true
}

# space_docker CMD -- per-type totals, volumes and images by size.
space_docker() {
  local d="$1" json
  json=$(timeout 60 "$d" system df -v --format '{{json .}}' 2>/dev/null | tr -d '\r') || true
  if [ -z "$json" ] || ! jq -e . >/dev/null 2>&1 <<< "$json"; then
    log_warn "docker system df -v returned nothing usable"
    return 1
  fi

  echo "== docker by type"
  # `|| log_warn`, not bare: under maint's set -e a failed or timed-out df
  # ended the report here, after the header.
  timeout 60 "$d" system df 2>/dev/null | tr -d '\r' \
    || log_warn "docker system df failed; per-type totals skipped"

  echo "== docker volumes (links = containers using it)"
  jq -r '.Volumes[] | [.Size, .Links, .Name] | @tsv' <<< "$json" \
    | while IFS=$'\t' read -r s l n; do
        printf '%s\t%9s  %3s  %s\n' "$(docker_bytes "$s")" "$s" "$l" "$n"
      done | sort -rn | head -n "$SPACE_TOP" | cut -f2- || true

  echo "== docker images (unique size)"
  jq -r '.Images[] | [.UniqueSize, .Containers, (.Repository + ":" + .Tag)] | @tsv' <<< "$json" \
    | while IFS=$'\t' read -r s c n; do
        printf '%s\t%9s  %3s  %s\n' "$(docker_bytes "$s")" "$s" "$c" "$n"
      done | sort -rn | head -n "$SPACE_TOP" | cut -f2- || true
}

# space_run -- the whole report. Read-only; a missing docker is a skip.
space_run() {
  local d="" docker_used=""
  d=$(docker_cmd) || d=""
  if [ -n "$d" ]; then
    # Sum of the four per-type sizes: what the engine actually holds.
    # `|| docker_used=""`: docker_cmd only proved that `info` answers. A
    # `system df` that fails or outlives its 60 s (it sizes every layer) used
    # to hit maint's set -e in this bare assignment, before a line of the
    # report was printed and with stderr discarded: no output, exit 124.
    # Unknown is what space_vhdx_line already renders as "used: unknown".
    docker_used=$(timeout 60 "$d" system df --format '{{.Size}}' 2>/dev/null | tr -d '\r' \
      | while read -r s; do docker_bytes "$s"; done | awk '{t += $1} END {printf "%.0f\n", t}') \
      || docker_used=""
  fi

  echo "== vhdx files (file size vs data inside)"
  space_distro_line "$(space_distro_name)" "$(df -B1 --output=used / | tail -1 | tr -d ' ')"
  space_vhdx_line Docker "$SPACE_DOCKER_VHDX_GLOB" "$docker_used"
  echo "   (slack = file size - data, an upper bound: maint.bat compact, from an admin"
  echo "    prompt, frees only blocks that are entirely unused and often returns much less)"
  echo

  space_top_dirs / 1
  echo
  space_top_dirs "$HOME" 2
  echo

  if [ -n "$d" ]; then
    # A degraded daemon has already been warned about inside space_docker; it
    # must not fail the read-only report when an absent one does not.
    space_docker "$d" || true
  else
    log_warn "docker not reachable (tried: $DOCKER_CANDIDATES); skipping docker breakdown"
  fi
}
