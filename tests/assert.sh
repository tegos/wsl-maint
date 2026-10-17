#!/usr/bin/env bash
# Minimal assertion helpers. No external deps.
ASSERT_PASS=0
ASSERT_FAIL=0

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" = "$actual" ]; then
    ASSERT_PASS=$((ASSERT_PASS + 1))
  else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "  FAIL ${msg}: expected [$expected] got [$actual]" >&2
  fi
}

assert_ok() {
  local msg="${2:-}"
  if eval "$1"; then
    ASSERT_PASS=$((ASSERT_PASS + 1))
  else
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "  FAIL ${msg}: expected success from [$1]" >&2
  fi
}

assert_fails() {
  local msg="${2:-}"
  if eval "$1"; then
    ASSERT_FAIL=$((ASSERT_FAIL + 1))
    echo "  FAIL ${msg}: expected failure from [$1]" >&2
  else
    ASSERT_PASS=$((ASSERT_PASS + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) ASSERT_PASS=$((ASSERT_PASS + 1)) ;;
    *)
      ASSERT_FAIL=$((ASSERT_FAIL + 1))
      echo "  FAIL ${msg}: [$haystack] does not contain [$needle]" >&2
      ;;
  esac
}
