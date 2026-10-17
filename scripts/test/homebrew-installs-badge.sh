#!/bin/sh
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$DIR/../homebrew-installs-badge.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "$SCRIPT" ] || fail "missing executable script: $SCRIPT"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/homebrew-installs-badge.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/analytics.json" <<'EOF'
{
  "start_date": "2026-07-19",
  "end_date": "2026-10-17",
  "total_items": 2,
  "items": [
    {"formula": "raulgg/tap/airpods-control", "count": "12"},
    {"formula": "raulgg/tap/pods-control", "count": "6"}
  ]
}
EOF

badge_message() {
  "$SCRIPT" --analytics-file "$TMP/analytics.json" "$@" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["message"])'
}

got=$(badge_message)
[ "$got" = "6/90d" ] ||
  fail "default formula counted $got, expected 6/90d"

got=$(badge_message --formula raulgg/tap/airpods-control)
[ "$got" = "12/90d" ] ||
  fail "explicit old formula counted $got, expected 12/90d"

echo "ok: homebrew install badge counts pods-control"
