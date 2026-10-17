#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./assert.sh
. ../wsl/lib/common.sh
. ../wsl/lib/rules.sh
. ../wsl/lib/browsers.sh
. ../wsl/lib/state.sh
. ../wsl/lib/audit.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export STATE_FILE="$TMP/state"

assert_eq "" "$(state_get missing)" "unset key is empty"
state_set foo 123
assert_eq "123" "$(state_get foo)" "set then get"
state_set foo 456
assert_eq "456" "$(state_get foo)" "overwrite, not append"
assert_eq "1" "$(grep -c '^foo=' "$STATE_FILE")" "one row per key"

# value containing '=' round-trips intact
state_set eqval "a=b=c"
assert_eq "a=b=c" "$(state_get eqval)" "value with embedded = survives get"

assert_ok "state_is_stale clean 7" "never run counts as stale"
state_mark_run clean
assert_fails "state_is_stale clean 7" "just ran is not stale"
state_set "lastrun.clean" "$(( $(date +%s) - 8 * 86400 ))"
assert_ok "state_is_stale clean 7" "8 days old is stale"

# audit table
mkdir -p "$TMP/cache/junk"
head -c 4096 /dev/zero > "$TMP/cache/junk/blob"
cat > "$TMP/rules.conf" <<EOF
$TMP/cache      purge   -   yes
EOF

out=$(audit_run "$TMP/rules.conf")
assert_contains "$out" "$TMP/cache" "audit lists the path"
assert_contains "$out" "purge" "audit lists the policy"
assert_contains "$out" "TOTAL" "audit prints a total row"

# first run: no previous measurement, so the data row's delta column
# must carry the "-" placeholder, not a computed value.
row1=$(echo "$out" | grep -F "$TMP/cache")
delta1=$(echo "$row1" | awk '{print $(NF-1)}')
assert_eq "-" "$delta1" "first audit's data row has no-previous-measurement placeholder"

# grow the fixture on disk so the second audit has something real to
# compare against, then compute the expected delta the same way the
# implementation is documented to (human(), '+' prefix when non-negative)
# so this assertion is checking real behaviour, not a hardcoded guess.
size_before=$(dir_bytes "$TMP/cache")
head -c 4096 /dev/zero > "$TMP/cache/junk/blob2"
size_after=$(dir_bytes "$TMP/cache")
diff_bytes=$(( size_after - size_before ))
expected_delta=$(human "$diff_bytes")
if [ "$diff_bytes" -ge 0 ]; then expected_delta="+$expected_delta"; fi
# sanity: the fixture growth must actually move the measured size,
# otherwise this assertion could pass without ever exercising the
# delta math.
assert_ok "[ $diff_bytes -ne 0 ]" "fixture growth actually changed measured size"

out2=$(audit_run "$TMP/rules.conf")
row2=$(echo "$out2" | grep -F "$TMP/cache")
delta2=$(echo "$row2" | awk '{print $(NF-1)}')
assert_eq "$expected_delta" "$delta2" "second audit's data row shows the real computed delta"

# third run: shrink the fixture. human() shells out to `numfmt --to=iec`,
# which reads a leading "-<digit>" as an unrecognised option rather than
# a negative number, so a naive `human $(( size - prev ))` on a shrink
# silently falls through to human()'s raw-byte fallback (e.g. "-8092B"
# instead of "-7.9K"). Prove the shrink path renders a real IEC value.
size_before3=$(dir_bytes "$TMP/cache")
rm -f "$TMP/cache/junk/blob2"
size_after3=$(dir_bytes "$TMP/cache")
diff_bytes3=$(( size_after3 - size_before3 ))
assert_ok "[ $diff_bytes3 -lt 0 ]" "fixture shrink actually reduced measured size"
expected_delta3="-$(human $(( -diff_bytes3 )))"

out3=$(audit_run "$TMP/rules.conf")
row3=$(echo "$out3" | grep -F "$TMP/cache")
delta3=$(echo "$row3" | awk '{print $(NF-1)}')
assert_eq "$expected_delta3" "$delta3" "third audit's data row shows a correctly formatted negative delta"

echo "RESULT $ASSERT_PASS $ASSERT_FAIL"
