#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BUILT_CLI="$ROOT/build/pods-control"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  expected="$1"
  actual="$2"
  description="$3"
  [ "$actual" = "$expected" ] ||
    fail "$description: expected '$expected', got '$actual'"
}

expect_failure() {
  expected_status="$1"
  expected_output="$2"
  shift 2

  set +e
  actual_output=$("$@")
  actual_status=$?
  set -e

  assert_equal "$expected_status" "$actual_status" "exit status for $*"
  assert_equal "$expected_output" "$actual_output" "output for $*"
}

[ -x "$BUILT_CLI" ] || fail "missing executable: run make first"
VERSION=$(cat "$ROOT/version.txt")
[ -n "$VERSION" ] || fail "empty version file"

# Omitting avbypass.dylib proves these parser-only journeys finish before the
# entitlement bootstrap and private-framework lookup.
PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/airpods-control-test.XXXXXX")
trap 'rm -rf "$PROBE_DIR"' EXIT HUP INT TERM
cp "$BUILT_CLI" "$PROBE_DIR/pods-control"
CLI="$PROBE_DIR/pods-control"

"$CLI" --help >/dev/null
"$CLI" lm --help >/dev/null
"$CLI" status --help >/dev/null
"$CLI" support-report --help >/dev/null

assert_equal "$VERSION" "$("$CLI" --version)" "plain version"
assert_equal "{\"result\":\"ok\",\"version\":\"$VERSION\"}" \
  "$("$CLI" --json version)" "JSON version"

"$CLI" --debug --version >"$PROBE_DIR/debug.stdout" \
  2>"$PROBE_DIR/debug.stderr"
assert_equal "$VERSION" "$(cat "$PROBE_DIR/debug.stdout")" \
  "debug preserves stdout"
[ -s "$PROBE_DIR/debug.stderr" ] ||
  fail "debug version should emit diagnostics on stderr"

# Representative failures exercise both plain and JSON terminal output. Detailed
# parser seams stay in the Swift suite.
expect_failure 2 bad-args "$CLI" unknown-command
expect_failure 2 '{"error":"bad-args","result":"error"}' \
  "$CLI" lm get --json --json
expect_failure 2 '{"error":"bad-args","reason":"listening mode \"transparency\" is repeated in --modes; list each mode once","result":"error"}' \
  "$CLI" lm cycle --modes trans,transparency --json

printf '%s\n' 'CLI contract tests passed'
