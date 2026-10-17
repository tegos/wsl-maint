#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./assert.sh
. ../wsl/lib/common.sh
. ../wsl/lib/config.sh
. ../wsl/lib/space.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- docker_bytes: Docker prints SI units ---
assert_eq "16860000000" "$(docker_bytes 16.86GB)" "GB"
assert_eq "235200000" "$(docker_bytes 235.2MB)" "MB"
assert_eq "155400" "$(docker_bytes 155.4kB)" "kB"
assert_eq "88" "$(docker_bytes 88B)" "bare bytes"
assert_eq "0" "$(docker_bytes 0B)" "zero"

# --- space_vhdx_line ---
head -c 4096 /dev/zero > "$TMP/fake.vhdx"
out=$(space_vhdx_line Ubuntu "$TMP/*.vhdx" 1024)
assert_contains "$out" "compact could return ~3.0K" "slack = file size - used"
out=$(space_vhdx_line Ubuntu "$TMP/*.vhdx" 999999)
assert_contains "$out" "~0.0" "used above file size never goes negative"
out=$(space_vhdx_line Docker "$TMP/*.vhdx" "")
assert_contains "$out" "used: unknown" "no docker total reported as unknown"
out=$(space_vhdx_line Ubuntu "$TMP/nope/*.vhdx" 1)
assert_contains "$out" "vhdx not found" "missing vhdx is reported, not fatal"

# --- space_top_dirs: sorted, root itself excluded, capped at SPACE_TOP ---
mkdir -p "$TMP/tree/big" "$TMP/tree/small" "$TMP/tree/mid"
head -c 300000 /dev/zero > "$TMP/tree/big/f"
head -c 1000 /dev/zero > "$TMP/tree/small/f"
head -c 50000 /dev/zero > "$TMP/tree/mid/f"
out=$(SPACE_TOP=2 space_top_dirs "$TMP/tree" 1)
assert_contains "$out" "$TMP/tree/big" "biggest dir listed"
assert_fails "echo \"\$out\" | grep -q '/small$'" "SPACE_TOP caps the list"
assert_fails "echo \"\$out\" | grep -qE '  $TMP/tree\$'" "root dir itself is not a row"
first=$(echo "$out" | sed -n 2p)
assert_contains "$first" "/big" "largest first"

# Regression: head closing early SIGPIPEs sort; under pipefail + set -e (as in
# maint) that used to kill the whole report after the first table.
rc=0
( set -e; SPACE_TOP=1 space_top_dirs "$TMP/tree" 1 >/dev/null ) || rc=$?
assert_eq "0" "$rc" "top-N pipeline survives set -e"

# --- docker section via a shim; the real daemon is never reached ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2 ${3:-}" in
  "info  ") exit 0 ;;
  "system df -v")
    echo '{"Images":[{"Repository":"mysql","Tag":"8","UniqueSize":"1.12GB","Containers":"0"},{"Repository":"alpine","Tag":"latest","UniqueSize":"88.02kB","Containers":"0"}],"Volumes":[{"Name":"small-vol","Size":"207.8MB","Links":"0"},{"Name":"big-db-data","Size":"16.86GB","Links":"1"}],"Containers":[],"BuildCache":[]}'
    ;;
  "system df --format") printf '7.334GB\n0B\n21.86GB\n0B\n' ;;
  "system df ") echo "TYPE  TOTAL" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/docker"
PATH="$TMP/bin:$PATH"

assert_eq "docker" "$(DOCKER_CANDIDATES=docker docker_cmd)" "live client picked"
assert_fails "DOCKER_CANDIDATES=no-such-docker docker_cmd" "no client -> non-zero"

out=$(space_docker docker 2>&1)
vols=$(echo "$out" | sed -n '/volumes/,/images/p')
assert_contains "$(echo "$vols" | sed -n 2p)" "big-db-data" "volumes sorted by bytes, not by string"
imgs=$(echo "$out" | sed -n '/images/,$p')
assert_contains "$(echo "$imgs" | sed -n 2p)" "mysql:8" "images sorted by unique size"

# --- whole report through the CLI: read-only, exit 0 ---
export SPACE_DISTRO_VHDX_GLOB="$TMP/*.vhdx" SPACE_DOCKER_VHDX_GLOB="$TMP/*.vhdx"
# The real reg.exe is never asked: a missing one means the glob fallback.
export SPACE_REG=no-such-reg.exe WSL_DISTRO_NAME=Alpine
export DOCKER_CANDIDATES=docker HOME="$TMP/tree"
# Not the checkout's own maint.conf: the run must not depend on the box.
: > "$TMP/maint.conf"
export WSL_MAINT_CONFIG="$TMP/maint.conf"
rc=0
out=$(../wsl/maint space 2>&1) || rc=$?
assert_eq "0" "$rc" "maint space exits 0"
assert_contains "$out" "compact could return" "report has the vhdx section"
assert_contains "$out" "big-db-data" "report reaches the docker section"
assert_contains "$out" "Alpine " "vhdx line labelled with the running distro, not Ubuntu"
unset SPACE_DISTRO_VHDX_GLOB SPACE_REG WSL_DISTRO_NAME

# --- distro disk from the Lxss registry (reg.exe stubbed, never the real one) ---
# The stub checks its arguments, prints $TMP/reg.out and exits with the code
# in $TMP/reg.rc.
cat > "$TMP/bin/fake-reg" <<SHIM
#!/usr/bin/env bash
[ "\$1" = query ] || exit 9
[ "\$2" = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss' ] || exit 9
[ "\$3" = /s ] || exit 9
cat "$TMP/reg.out"
exit "\$(cat "$TMP/reg.rc")"
SHIM
chmod +x "$TMP/bin/fake-reg"
export SPACE_REG=fake-reg MAINT_MNT_BASE="$TMP/mnt"
echo 0 > "$TMP/reg.rc"
# reg_entry GUID NAME BASEPATH [VHDFILENAME] -- one subkey, CRLF like reg.exe.
reg_entry() {
  printf '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss\\{%s}\r\n' "$1"
  printf '    State    REG_DWORD    0x1\r\n'
  printf '    DistributionName    REG_SZ    %s\r\n' "$2"
  printf '    BasePath    REG_SZ    %s\r\n' "$3"
  [ -z "${4:-}" ] || printf '    VhdFileName    REG_SZ    %s\r\n' "$4"
  printf '    Version    REG_DWORD    0x2\r\n'
}
reg_head() {
  printf '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss\r\n'
  printf '    DefaultVersion    REG_DWORD    0x2\r\n'
}
mkdir -p "$TMP/mnt/d/WSL/My Debian" "$TMP/mnt/c/Store/Ubuntu/LocalState" "$TMP/glob/Pkg.Ubuntu/LocalState"
head -c 8192 /dev/zero > "$TMP/mnt/d/WSL/My Debian/ext4.vhdx"
head -c 4096 /dev/zero > "$TMP/mnt/c/Store/Ubuntu/LocalState/ext4.vhdx"
head -c 2048 /dev/zero > "$TMP/glob/Pkg.Ubuntu/LocalState/ext4.vhdx"
export SPACE_DISTRO_VHDX_GLOB="$TMP/glob/*/LocalState/ext4.vhdx"
export WSL_DISTRO_NAME=

# Imported non-Ubuntu distro on D: (path with a space), next to a Store Ubuntu.
{ reg_head
  reg_entry 1111 Ubuntu 'C:\Store\Ubuntu\LocalState'
  reg_entry 2222 Debian 'D:\WSL\My Debian'
} > "$TMP/reg.out"
out=$(space_distro_line Debian 1024)
assert_contains "$out" "Debian " "line labelled with the distro"
assert_contains "$out" "8.0K" "imported distro on D: found through the registry"
assert_contains "$out" "compact could return ~7.0K" "used vs registry disk"
out=$(space_distro_line debian 1024)
assert_contains "$out" "8.0K" "distro name matched case-insensitively, as on Windows"
out=$(space_distro_line Ubuntu 1024)
assert_contains "$out" "4.0K" "registry wins over the glob for Ubuntu too"

# \\?\ long-path prefix stripped; VhdFileName honoured over ext4.vhdx.
mkdir -p "$TMP/mnt/e/Distros/Arch"
head -c 16384 /dev/zero > "$TMP/mnt/e/Distros/Arch/disk.vhdx"
{ reg_head; reg_entry 3333 Arch '\\?\E:\Distros\Arch' disk.vhdx; } > "$TMP/reg.out"
out=$(space_distro_line Arch 1024)
assert_contains "$out" "16.0K" "long-path prefix stripped and VhdFileName used"

# Two registry entries with the same name: refuse and list both, exit 0.
{ reg_head
  reg_entry 1111 Debian 'C:\Store\Ubuntu\LocalState'
  reg_entry 2222 Debian 'D:\WSL\My Debian'
} > "$TMP/reg.out"
rc=0; out=$(space_distro_line Debian 1024) || rc=$?
assert_eq "0" "$rc" "two matches are reported, not fatal"
assert_contains "$out" "more than one Debian disk" "two matches refused"
assert_contains "$out" "$TMP/mnt/d/WSL/My Debian/ext4.vhdx" "first match listed"
assert_contains "$out" "$TMP/mnt/c/Store/Ubuntu/LocalState/ext4.vhdx" "second match listed"
assert_fails "echo \"\$out\" | grep -q 'compact could return'" "no size line on a guess"

# Registered, but the BasePath names no file (a non-ASCII profile path comes
# through reg.exe in the console codepage, mangled): glob fallback.
{ reg_head; reg_entry 4444 Ubuntu 'C:\Users\Iv?n\AppData\Local\Packages\Pkg.Ubuntu\LocalState'; } > "$TMP/reg.out"
out=$(space_distro_line Ubuntu 1024)
assert_contains "$out" "2.0K" "registry disk missing falls back to the glob"
out=$(SPACE_DISTRO_VHDX_GLOB="$TMP/none/*.vhdx" space_distro_line Ubuntu 1024)
assert_contains "$out" "vhdx not found" "registry and glob both miss: not found"

# Distro not registered at all: glob fallback.
{ reg_head; reg_entry 2222 Debian 'D:\WSL\My Debian'; } > "$TMP/reg.out"
out=$(space_distro_line Ubuntu 1024)
assert_contains "$out" "2.0K" "unregistered distro falls back to the glob"

# reg.exe missing: glob fallback.
out=$(SPACE_REG=no-such-reg.exe space_distro_line Ubuntu 1024)
assert_contains "$out" "2.0K" "reg.exe missing falls back to the glob"

# reg.exe failing (even with output): glob fallback.
{ reg_head; reg_entry 2222 Ubuntu 'D:\WSL\My Debian'; } > "$TMP/reg.out"
echo 1 > "$TMP/reg.rc"
out=$(space_distro_line Ubuntu 1024)
assert_contains "$out" "2.0K" "reg.exe failing falls back to the glob"
echo 0 > "$TMP/reg.rc"

# CRLF plus UTF-16-ish NULs after every byte (some locales/codepages).
{ reg_head; reg_entry 2222 Debian 'D:\WSL\My Debian'; } | sed 's/./&\x0/g' > "$TMP/reg.out"
out=$(space_distro_line Debian 1024)
assert_contains "$out" "8.0K" "NUL-padded CRLF reg.exe output parsed"

# Glob fallback with two matches: refused too.
mkdir -p "$TMP/glob/Pkg.Ubuntu2/LocalState"
head -c 2048 /dev/zero > "$TMP/glob/Pkg.Ubuntu2/LocalState/ext4.vhdx"
out=$(SPACE_REG=no-such-reg.exe space_distro_line Ubuntu 1024)
assert_contains "$out" "more than one Ubuntu disk" "two glob matches refused"

# Which distro: config `distro` when set, else the running one, else Ubuntu.
assert_eq "Kali" "$(CFG_DISTRO=Kali CFG_DISTRO_SET=1 WSL_DISTRO_NAME=Debian space_distro_name)" "config distro wins"
assert_eq "Debian" "$(CFG_DISTRO=Ubuntu CFG_DISTRO_SET= WSL_DISTRO_NAME=Debian space_distro_name)" "running distro when config is default"
assert_eq "Ubuntu" "$(CFG_DISTRO=Ubuntu CFG_DISTRO_SET= WSL_DISTRO_NAME= space_distro_name)" "Ubuntu when nothing says otherwise"

# Another distro's disk: df / measures this one, so used is unknown.
{ reg_head; reg_entry 2222 Debian 'D:\WSL\My Debian'; } > "$TMP/reg.out"
out=$(WSL_DISTRO_NAME=Ubuntu space_distro_line Debian 1024)
assert_contains "$out" "used: unknown" "another distro's disk: used unknown"
unset SPACE_REG MAINT_MNT_BASE SPACE_DISTRO_VHDX_GLOB WSL_DISTRO_NAME

echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
