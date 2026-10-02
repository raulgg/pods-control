#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/install-from-source.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

tmp_base=${TMPDIR:-/tmp}
tmp_base=${tmp_base%/}
TMP=$(mktemp -d "$tmp_base/install-from-source.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

expect_failure() {
	description=$1
	shift
	if "$@" >"$TMP/failure.out" 2>&1; then
		fail "$description: command unexpectedly succeeded"
	fi
}

[ -x "$SCRIPT" ] || fail "missing $SCRIPT"

(
	export CLT_CLANG=/nonexistent/clang
	export CLT_SWIFTC=/nonexistent/swiftc
	export CLT_WAIT_SECS=0
	expect_failure "install without developer tools" "$SCRIPT" --from-tree
)

# Truncated download: drop the trailing invocation so the function is never called.
truncated=$TMP/truncated.sh
sed '$d' "$SCRIPT" >"$truncated"
sh "$truncated" || fail "truncated script should be a no-op"

stub=$TMP/stub
brew_root=$TMP/brew-root
mkdir -p "$stub" "$brew_root"
cat >"$stub/brew" <<'EOF'
#!/bin/sh
if [ "$1" = list ]; then
	[ "$2" = --formula ] || exit 1
	name=$3
	for owned in ${FAKE_BREW_FORMULAS:-pods-control}; do
		[ "$name" = "$owned" ] && exit 0
	done
	exit 1
fi
if [ "$1" = --prefix ]; then
	printf '%s\n' "$FAKE_BREW_PREFIX"
	exit 0
fi
exit 1
EOF
chmod +x "$stub/brew"

assert_new_layout() {
	prefix=$1
	target=../libexec/pods-control/pods-control
	for cmd in pods-control airpods-control; do
		actual=$(readlink "$prefix/bin/$cmd") || actual=
		[ "$actual" = "$target" ] ||
			fail "$cmd symlink target in $prefix"
		got=$("$prefix/bin/$cmd" --version) ||
			fail "$cmd --version failed in $prefix"
		[ "$got" = "$expected_version" ] ||
			fail "$cmd version $got in $prefix, expected $expected_version"
	done
	[ ! -e "$prefix/libexec/airpods-control" ] ||
		fail "legacy libexec remains in $prefix"
	for page in pods-control airpods-control; do
		[ -f "$prefix/share/man/man1/$page.1" ] ||
			fail "missing $page man page in $prefix"
	done
}

assert_removed() {
	prefix=$1
	for leftover in \
		bin/pods-control \
		bin/airpods-control \
		libexec/pods-control \
		libexec/airpods-control \
		share/man/man1/pods-control.1 \
		share/man/man1/airpods-control.1; do
		[ ! -e "$prefix/$leftover" ] ||
			fail "uninstall left $leftover in $prefix"
	done
}

PREFIX="$TMP/nested install"
mkdir -p "$PREFIX"
expected_version=$(tr -d '[:space:]' <"$ROOT/version.txt")

repo_binary=$ROOT/build/pods-control
repo_binary_existed=0
before_sum=
if [ -f "$repo_binary" ]; then
	repo_binary_existed=1
	before_sum=$(cksum <"$repo_binary")
fi

BREW="$stub/brew" FAKE_BREW_PREFIX="$brew_root" \
	"$SCRIPT" --from-tree --prefix "$PREFIX" >/dev/null 2>&1
assert_new_layout "$PREFIX"

if [ "$repo_binary_existed" -eq 1 ]; then
	after_sum=$(cksum <"$repo_binary")
	[ "$before_sum" = "$after_sum" ] ||
		fail "installer clobbered $repo_binary"
else
	[ ! -f "$repo_binary" ] ||
		fail "installer created $repo_binary"
fi

old_prefix=$TMP/old-layout
mkdir -p "$old_prefix/bin" "$old_prefix/libexec/airpods-control"
printf '%s\n' '#!/bin/sh' "printf '%s\\n' 0.0.1" \
	>"$old_prefix/libexec/airpods-control/airpods-control"
chmod +x "$old_prefix/libexec/airpods-control/airpods-control"
ln -s ../libexec/airpods-control/airpods-control \
	"$old_prefix/bin/airpods-control"
output=$(BREW="$stub/brew" FAKE_BREW_PREFIX="$brew_root" \
	"$SCRIPT" --from-tree --prefix "$old_prefix" 2>&1) ||
	fail "old-layout upgrade failed: $output"
printf '%s\n' "$output" | grep -q 'upgraded from 0.0.1' ||
	fail "old-layout upgrade did not report the previous version: $output"
assert_new_layout "$old_prefix"

# Upgrade over an owned install whose binary cannot report a version.
mv "$PREFIX/libexec/pods-control/pods-control" \
	"$PREFIX/libexec/pods-control/pods-control.real"
printf '#!/bin/sh\nexit 1\n' >"$PREFIX/libexec/pods-control/pods-control"
chmod +x "$PREFIX/libexec/pods-control/pods-control"
output=$(BREW="$stub/brew" FAKE_BREW_PREFIX="$brew_root" \
	"$SCRIPT" --from-tree --prefix "$PREFIX" 2>&1) ||
	fail "upgrade aborted when old --version failed: $output"
got=$("$PREFIX/bin/pods-control" --version) ||
	fail "repaired binary did not run"
[ "$got" = "$expected_version" ] ||
	fail "repaired binary reported $got, expected $expected_version"

for name in pods-control airpods-control; do
	foreign=$TMP/foreign-$name
	mkdir -p "$foreign/bin"
	printf 'nope\n' >"$foreign/bin/$name"
	expect_failure "foreign $name command" \
		"$SCRIPT" --from-tree --prefix "$foreign"
	[ "$(cat "$foreign/bin/$name")" = nope ] ||
		fail "installer changed a foreign $name command"
done

for formula in pods-control airpods-control; do
	FAKE_BREW_FORMULAS=$formula BREW="$stub/brew" \
		FAKE_BREW_PREFIX="$brew_root" \
		expect_failure "Homebrew-owned $formula" \
		"$SCRIPT" --from-tree --prefix "$brew_root"
	[ ! -e "$brew_root/bin/pods-control" ] ||
		fail "Homebrew $formula conflict installed pods-control"
	[ ! -e "$brew_root/bin/airpods-control" ] ||
		fail "Homebrew $formula conflict installed airpods-control"
done

rm -f "$PREFIX/libexec/pods-control/pods-control.real"
(
	export CLT_CLANG=/nonexistent/clang
	export CLT_SWIFTC=/nonexistent/swiftc
	export CLT_WAIT_SECS=0
	export BREW="$stub/brew"
	export FAKE_BREW_PREFIX="$PREFIX"
	"$SCRIPT" --from-tree --prefix "$PREFIX" --uninstall >/dev/null 2>&1
) || fail "uninstall consulted install-only prerequisites"
assert_removed "$PREFIX"

echo "ok: install-from-source fixtures"
