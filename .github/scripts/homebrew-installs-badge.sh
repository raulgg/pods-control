#!/bin/sh
# Build a Shields.io endpoint badge from Homebrew's public install analytics.
# The count is anonymous brew install events, not unique users.

set -eu

# Homebrew reports this formula separately from the deprecated
# raulgg/tap/airpods-control formula.
DEFAULT_FORMULA=raulgg/tap/pods-control
DEFAULT_PERIOD=90d
DEFAULT_LABEL='brew installs'

usage() {
	die 2 "usage: $0 --analytics-file FILE [--formula NAME] [--period 90d] [--label TEXT] [--output FILE]"
}

die() {
	code=$1
	shift
	printf '%s\n' "$*" >&2
	exit "$code"
}

analytics_file=
formula=$DEFAULT_FORMULA
period=$DEFAULT_PERIOD
label=$DEFAULT_LABEL
output=

while [ "$#" -gt 0 ]; do
	case $1 in
		--analytics-file)
			[ "$#" -ge 2 ] || usage
			analytics_file=$2
			shift 2
			;;
		--formula)
			[ "$#" -ge 2 ] || usage
			formula=$2
			shift 2
			;;
		--period)
			[ "$#" -ge 2 ] || usage
			period=$2
			shift 2
			;;
		--label)
			[ "$#" -ge 2 ] || usage
			label=$2
			shift 2
			;;
		--output)
			[ "$#" -ge 2 ] || usage
			output=$2
			shift 2
			;;
		-h | --help)
			usage
			;;
		*)
			usage
			;;
	esac
done

[ -n "$analytics_file" ] || usage
[ -f "$analytics_file" ] || die 1 "error: analytics file not found: $analytics_file"
case $period in
	30d | 90d | 365d) ;;
	*)
		die 2 "error: period must be 30d, 90d, or 365d"
		;;
esac

command -v python3 >/dev/null 2>&1 || die 1 "error: python3 is required"

badge=$(FORMULA=$formula PERIOD=$period LABEL=$label python3 - "$analytics_file" <<'PY'
import datetime
import json
import os
import sys

PERIOD_DAYS = {"30d": 30, "90d": 90, "365d": 365}
WINDOW_TOLERANCE_DAYS = 3

path = sys.argv[1]
formula = os.environ["FORMULA"]
period = os.environ["PERIOD"]
label = os.environ["LABEL"]


def parse_date(payload, key):
    raw = payload.get(key)
    if not isinstance(raw, str):
        raise SystemExit("error: analytics JSON must contain %s" % key)
    try:
        return datetime.date.fromisoformat(raw)
    except ValueError as exc:
        raise SystemExit("error: invalid %s: %s" % (key, raw)) from exc


def parse_count(raw):
    if isinstance(raw, bool):
        raise SystemExit("error: invalid install count: %r" % (raw,))
    if isinstance(raw, int):
        return raw
    if isinstance(raw, str):
        digits = raw.replace(",", "").strip()
        if not digits.isdigit():
            raise SystemExit("error: invalid install count: %s" % raw)
        return int(digits)
    raise SystemExit("error: invalid install count: %r" % (raw,))

try:
    with open(path, encoding="utf-8") as fh:
        payload = json.load(fh)
except json.JSONDecodeError as exc:
    raise SystemExit(f"error: invalid analytics JSON: {exc}") from exc
except OSError as exc:
    raise SystemExit(f"error: cannot read analytics file: {exc}") from exc

if not isinstance(payload, dict):
    raise SystemExit("error: analytics JSON must be an object")

start_date = parse_date(payload, "start_date")
end_date = parse_date(payload, "end_date")
window_days = (end_date - start_date).days
expected_days = PERIOD_DAYS[period]
if abs(window_days - expected_days) > WINDOW_TOLERANCE_DAYS:
    raise SystemExit(
        "error: analytics window %s to %s (%d days) does not match --period %s"
        % (start_date, end_date, window_days, period)
    )

items = payload.get("items")
if not isinstance(items, list):
    raise SystemExit("error: analytics JSON must contain an items array")

# Homebrew may drop the long tail of low-count formulae, so a formula absent
# from a truncated list is not necessarily at zero installs.
total_items = payload.get("total_items")
truncated = (
    isinstance(total_items, int)
    and not isinstance(total_items, bool)
    and len(items) < total_items
)

found = False
total = 0
for item in items:
    if not isinstance(item, dict):
        raise SystemExit("error: analytics items must be objects")
    name = item.get("formula")
    if not isinstance(name, str):
        continue
    if name != formula and not name.startswith(formula + " "):
        continue
    if "count" not in item:
        raise SystemExit("error: analytics item for %s has no count" % name)
    found = True
    total += parse_count(item["count"])

if found:
    message = "%d/%s" % (total, period)
elif truncated:
    message = "<1/%s" % period
else:
    message = "0/%s" % period

badge = {
    "schemaVersion": 1,
    "label": label,
    "message": message,
    "color": "FBB040",
    "namedLogo": "homebrew",
    "logoColor": "black",
    "cacheSeconds": 3600,
}
json.dump(badge, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
)

if [ -n "$output" ]; then
	printf '%s\n' "$badge" >"$output"
else
	printf '%s\n' "$badge"
fi
