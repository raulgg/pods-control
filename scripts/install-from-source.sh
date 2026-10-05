#!/bin/sh
# Fetch, compile, and install (or replace) pods-control from a Git tag.
# Wrap work in a function so a truncated curl | sh download does nothing.

install_from_source() {
	set -eu

	REPO_HTTPS=https://github.com/raulgg/pods-control.git
	RELEASES_LATEST=https://github.com/raulgg/pods-control/releases/latest
	FORMULA_NAME=pods-control
	LEGACY_FORMULA_NAME=airpods-control
	NEW_SYMLINK=../libexec/pods-control/pods-control
	LEGACY_SYMLINK=../libexec/airpods-control/airpods-control
	CLANG=/usr/bin/clang
	SWIFTC=/usr/bin/swiftc
	LIPO=/usr/bin/lipo
	CODESIGN=/usr/bin/codesign
	CLT_CLANG=${CLT_CLANG:-$CLANG}
	CLT_SWIFTC=${CLT_SWIFTC:-$SWIFTC}
	CLT_WAIT_SECS=${CLT_WAIT_SECS:-300}

	SCRIPT_VERSION=0.6.0 # x-release-please-version

	E_USAGE=2
	E_CLT=3
	E_BREW=4
	E_FOREIGN=5
	E_FETCH=6
	E_BUILD=7
	E_PREFIX=8
	E_VERSION=9

	die() {
		code=$1
		shift
		printf '%s\n' "$*" >&2
		exit "$code"
	}

	usage() {
		die "$E_USAGE" "usage: install-from-source.sh [--version vX.Y.Z|latest] [--prefix DIR] [--from-tree] [--uninstall]"
	}

	version_arg=
	prefix_arg=/usr/local
	from_tree=0
	do_uninstall=0

	while [ "$#" -gt 0 ]; do
		case $1 in
			--version)
				[ "$#" -ge 2 ] || usage
				version_arg=$2
				shift 2
				;;
			--prefix)
				[ "$#" -ge 2 ] || usage
				prefix_arg=$2
				shift 2
				;;
			--from-tree)
				from_tree=1
				shift
				;;
			--uninstall)
				do_uninstall=1
				shift
				;;
			-h | --help)
				usage
				;;
			*)
				usage
				;;
		esac
	done

	script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || script_dir=
	repo_root=
	if [ -n "$script_dir" ] && [ -f "$script_dir/../version.txt" ]; then
		repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
	fi
	resolve_prefix=
	if [ -n "$repo_root" ] && [ -x "$repo_root/scripts/resolve-prefix.sh" ]; then
		resolve_prefix=$repo_root/scripts/resolve-prefix.sh
	fi
	if [ "$from_tree" -eq 1 ]; then
		[ -n "$repo_root" ] ||
			die "$E_USAGE" "error: --from-tree requires a clone (cannot run from a pipe)"
	fi

	plain_version() {
		printf '%s\n' "$1" | sed 's/^v//'
	}

	is_semver() {
		printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
	}

	resolve_latest_tag() {
		url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$RELEASES_LATEST") ||
			die "$E_FETCH" "error: could not resolve latest release"
		tag=${url##*/}
		printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
			die "$E_VERSION" "error: latest redirect was not a stable tag: $tag"
		printf '%s\n' "$tag"
	}

	if [ -z "$version_arg" ]; then
		version_arg=v$(plain_version "$SCRIPT_VERSION")
	fi
	case $version_arg in
		latest)
			tag=$(resolve_latest_tag)
			;;
		v*)
			tag=$version_arg
			;;
		*)
			tag=v$version_arg
			;;
	esac
	requested=$(plain_version "$tag")
	is_semver "$requested" ||
		die "$E_VERSION" "error: invalid version: $version_arg"

	workdir=
	src_tree=
	build_dir=
	host_arch=

	ensure_workdir() {
		[ -n "$workdir" ] && return 0
		tmp_base=${TMPDIR:-/tmp}
		tmp_base=${tmp_base%/}
		workdir=$(mktemp -d "$tmp_base/airpods-control-install.XXXXXX")
		workdir=$(CDPATH= cd -- "$workdir" && pwd)
		cleanup() { rm -rf "$workdir"; }
		trap cleanup EXIT HUP INT TERM
	}

	print_clone_err() {
		if [ -n "$workdir" ] && [ -s "$workdir/clone.err" ]; then
			cat "$workdir/clone.err" >&2
		fi
	}

	fetch_tagged_src() {
		ensure_workdir
		mkdir -p "$workdir/src"
		# Fetch the tag ref only. `git clone -b` prefers a branch named vX.Y.Z.
		if GIT_TERMINAL_PROMPT=0 git -C "$workdir/src" init --quiet \
			>/dev/null 2>"$workdir/clone.err" &&
			GIT_TERMINAL_PROMPT=0 git -C "$workdir/src" remote add origin \
				"$REPO_HTTPS" >/dev/null 2>>"$workdir/clone.err" &&
			GIT_TERMINAL_PROMPT=0 git -C "$workdir/src" fetch --quiet --depth 1 \
				origin "refs/tags/${tag}:refs/tags/${tag}" \
				>/dev/null 2>>"$workdir/clone.err" &&
			GIT_TERMINAL_PROMPT=0 git -C "$workdir/src" \
				-c advice.detachedHead=false checkout --quiet --detach \
				"refs/tags/${tag}" >/dev/null 2>>"$workdir/clone.err"; then
			src_tree=$workdir/src
			return 0
		fi
		print_clone_err
		die "$E_FETCH" "error: git fetch of $tag failed"
	}

	require_installer_in_tree() {
		if [ -x "$src_tree/scripts/resolve-prefix.sh" ] &&
			[ -f "$src_tree/Makefile" ]; then
			return 0
		fi
		die "$E_PREFIX" "error: this installer is not in $tag; pass --version after it is released, or use --from-tree / Homebrew"
	}

	developer_tools_ok() {
		[ -x "$CLT_CLANG" ] && [ -x "$CLT_SWIFTC" ] || return 1
		# /usr/bin/clang and /usr/bin/swiftc are Apple trampolines; they stay
		# executable when Command Line Tools are not installed.
		if [ "$CLT_CLANG" = "$CLANG" ] || [ "$CLT_SWIFTC" = "$SWIFTC" ]; then
			xcode-select -p >/dev/null 2>&1 || return 1
			xcrun --find clang >/dev/null 2>&1 || return 1
			xcrun --find swiftc >/dev/null 2>&1 || return 1
		fi
		return 0
	}

	ensure_clt() {
		if developer_tools_ok; then
			return 0
		fi
		printf 'Command Line Tools not found.\n' >&2
		if [ "$CLT_WAIT_SECS" -gt 0 ]; then
			printf 'Opening the Command Line Tools installer.\n' >&2
			xcode-select --install >/dev/null 2>&1 || true
		fi
		elapsed=0
		while [ "$elapsed" -lt "$CLT_WAIT_SECS" ]; do
			if developer_tools_ok; then
				return 0
			fi
			sleep 2
			elapsed=$((elapsed + 2))
		done
		die "$E_CLT" "error: Command Line Tools missing. Install them, then retry. xcode-select --install"
	}

	ensure_resolver() {
		if [ -z "$resolve_prefix" ]; then
			resolve_prefix=$src_tree/scripts/resolve-prefix.sh
		fi
		[ -x "$resolve_prefix" ] ||
			die "$E_PREFIX" "error: missing resolve-prefix.sh"
	}

	refuse_foreign_command() {
		owned_command "$prefix/bin/pods-control" "$NEW_SYMLINK"
		owned_command "$prefix/bin/airpods-control" "$NEW_SYMLINK" "$LEGACY_SYMLINK"
	}

	owned_command() {
		command_path=$1
		shift
		if [ ! -e "$command_path" ] && [ ! -L "$command_path" ]; then
			return 0
		fi
		if [ -L "$command_path" ]; then
			actual=$(readlink "$command_path")
			for allowed in "$@"; do
				if [ "$actual" = "$allowed" ]; then
					return 0
				fi
			done
		fi
		die "$E_FOREIGN" "error: refusing to replace command not owned by this package: $command_path"
	}

	can_write_install_prefix() {
		mkdir -p "$prefix/bin" "$prefix/libexec/pods-control" \
			"$prefix/share/man/man1" 2>/dev/null && [ -w "$prefix/bin" ]
	}

	can_write_uninstall_prefix() {
		if [ -d "$prefix/bin" ]; then
			[ -w "$prefix/bin" ]
		elif [ -d "$prefix" ]; then
			[ -w "$prefix" ]
		else
			return 0
		fi
	}

	run_make() {
		use_sudo=$1
		target=$2
		if [ -n "$build_dir" ]; then
			set -- -C "$src_tree" \
				"PREFIX=$prefix" \
				"ARCHS=$host_arch" \
				"BUILD_DIR=$build_dir" \
				"CLANG=$CLANG" \
				"SWIFTC=$SWIFTC" \
				"LIPO=$LIPO" \
				"CODESIGN=$CODESIGN" \
				"$target"
		else
			set -- -C "$src_tree" \
				"PREFIX=$prefix" \
				"CLANG=$CLANG" \
				"SWIFTC=$SWIFTC" \
				"LIPO=$LIPO" \
				"CODESIGN=$CODESIGN" \
				"$target"
		fi
		if [ "$use_sudo" -eq 1 ]; then
			command -v sudo >/dev/null 2>&1 ||
				die "$E_PREFIX" "error: $prefix is not writable. Pass --prefix DIR or install sudo."
			sudo make "$@" || return $?
		else
			make "$@" || return $?
		fi
	}

	run_privileged() {
		target=$1
		if [ "$target" = uninstall ]; then
			if can_write_uninstall_prefix; then
				run_make 0 uninstall || return $?
			else
				run_make 1 uninstall || return $?
			fi
		elif can_write_install_prefix; then
			run_make 0 "$target" || return $?
		else
			run_make 1 "$target" || return $?
		fi
	}

	if [ "$do_uninstall" -eq 1 ]; then
		if [ -n "$repo_root" ] && [ -f "$repo_root/Makefile" ]; then
			src_tree=$repo_root
		else
			fetch_tagged_src
			require_installer_in_tree
		fi
		ensure_resolver
		prefix=$("$resolve_prefix" "$prefix_arg") || exit "$E_PREFIX"
		refuse_foreign_command
		run_privileged uninstall
		printf 'uninstalled prefix=%s\n' "$prefix"
		return 0
	fi

	ensure_clt
	ensure_workdir
	build_dir=$workdir/build
	host_arch=$(uname -m)
	if [ "$from_tree" -eq 1 ]; then
		src_tree=$repo_root
	else
		fetch_tagged_src
		require_installer_in_tree
	fi

	tree_version=$(tr -d '[:space:]' <"$src_tree/version.txt")
	[ "$tree_version" = "$requested" ] ||
		die "$E_VERSION" "error: version.txt is $tree_version, expected $requested"

	ensure_resolver
	prefix=$("$resolve_prefix" "$prefix_arg") || exit "$E_PREFIX"

	BREW=${BREW:-brew}
	if command -v "$BREW" >/dev/null 2>&1; then
		owned_formula=
		for candidate in "$FORMULA_NAME" "$LEGACY_FORMULA_NAME"; do
			if "$BREW" list --formula "$candidate" >/dev/null 2>&1; then
				owned_formula=$candidate
				break
			fi
		done
		if [ -n "$owned_formula" ]; then
			brew_prefix=$("$BREW" --prefix)
			if brew_prefix=$("$resolve_prefix" "$brew_prefix"); then
				if [ "$prefix" = "$brew_prefix" ]; then
					die "$E_BREW" "error: Homebrew already owns $owned_formula at $brew_prefix. Use: brew upgrade $FORMULA_NAME or brew upgrade $LEGACY_FORMULA_NAME"
				fi
				printf 'warning: Homebrew has %s; installing to %s anyway\n' \
					"$owned_formula" "$prefix" >&2
			fi
		fi
	fi

	refuse_foreign_command

	run_make 0 all ||
		die "$E_BUILD" "error: build failed"

	command_path=$prefix/bin/pods-control
	legacy_command=$prefix/bin/airpods-control
	old_version=unknown
	if [ -x "$command_path" ]; then
		old_version=$("$command_path" --version 2>/dev/null) || old_version=unknown
	elif [ -x "$legacy_command" ]; then
		old_version=$("$legacy_command" --version 2>/dev/null) || old_version=unknown
	fi

	run_privileged install ||
		die "$E_BUILD" "error: install failed"

	installed=$("$command_path" --version 2>/dev/null) ||
		die "$E_BUILD" "error: installed binary did not run"
	[ "$installed" = "$requested" ] ||
		die "$E_VERSION" "error: installed version is $installed, expected $requested"

	printf 'installed %s prefix=%s\n' "$installed" "$prefix"
	if [ "$old_version" != unknown ] && [ "$old_version" != "$installed" ]; then
		printf 'upgraded from %s\n' "$old_version"
	fi
	case ":$PATH:" in
		*":$prefix/bin:"*) ;;
		*)
			printf 'note: %s/bin is not on PATH. Add it to run pods-control by name.\n' \
				"$prefix"
			;;
	esac
}

install_from_source "$@"
