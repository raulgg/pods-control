# Contributing

Bug reports, compatibility findings, documentation fixes, and focused pull
requests are welcome.

## Before opening an issue

- Search existing issues first.
- For a compatibility report, connect exactly one compatible AirPods or Beats
  device and run `pods-control support-report`. Review the local report
  before deciding whether to open the GitHub form.
- Beats reports are welcome, but we have not verified support.
- Check the [device compatibility matrix](docs/compatibility.md) for verified
  capabilities and candidates that still need testing.
- For a bug, include the macOS version, device model, command, expected result,
  actual result, and exit code.
- Re-run the command with `--debug` when possible and attach stderr. Redact
  device names and other personal information.
- Report security concerns through
  [private vulnerability reporting](https://github.com/raulgg/pods-control/security/advisories/new).
  Do not disclose sensitive vulnerability details in a public issue.

This project uses an undocumented macOS API, so an update can break
compatibility. Report these regressions with the same details as other bugs.

## Development

You need:

- macOS 14 or newer to run Swift Testing. Production builds still target
  macOS 12.
- Command Line Tools or Xcode with Swift 6
- `make`, `clang`, `swiftc`, `lipo`, and `codesign`

### Development setup

Install [mise](https://mise.jdx.dev/). From the repository root, run:

```sh
mise install
```

This installs the development tools and versions listed in `mise.toml`. The
build still needs the macOS Command Line Tools or Xcode listed above.
`mise.lock` pins their download URLs and checksums. Use `mise use` or
`mise upgrade` to change tool versions; mise updates `mise.lock` as needed. If
you edit `mise.toml` manually, run `mise lock` before committing. Commit both
files together when either changes.

You can run the full test suite with `mise run test`. It calls `make test`.

Build and run the device-independent test suite:

```sh
make clean
make test
```

`make test` builds both architectures when the installed toolchain supports
them. It then runs the shell CLI contract tests, the C signal-monitor race test,
and the Swift unit tests. Tests must not require AirPods or write device
settings. Production Swift is compiled in Swift 5 mode with warnings treated
as errors. The SwiftPM package remains in Swift 5 mode and applies the same
warnings-as-errors check to its test targets. Production C and the signal
monitor race test compile with `-Wall -Wextra -Wpedantic -Werror`.

For runtime-bypass changes, launch the built CLI and confirm the interpose
reports active. This stays out of `make test` because it depends on the
installed macOS:

```sh
make verify-runtime
```

Check the product-name catalog against the pairings macOS itself publishes:

```sh
make verify-catalog
```

This reads `public.bluetooth-vendor-product-id` from the system's CoreTypes
bundles and reports Apple audio devices known to macOS but missing from
`Sources/AirPodsControl/AppleAudioProducts.swift`. It stays out of `make test`
because the result depends on the installed macOS version. Run it when adding
hardware or after a major system upgrade. The catalog supplies readable names
for support reports; capability is always read from the device at runtime.

Test changes to live private-API behavior on supported hardware. Follow the
[hardware testing guide](docs/hardware-testing.md) before merging a discovery
change. State the macOS version and device in the pull request. Automated tests
must not write device settings. Update
[`docs/compatibility.md`](docs/compatibility.md) when a hardware check changes a
device or capability status.

### Source layout

- `Sources/AirPodsControl` contains the single Swift executable module.
  `SupportReportDocument` contains the data shared by the terminal and GitHub
  renderers. Keep capture, verdict classification, privacy filtering, and
  restoration interpretation out of the renderers.
- `Sources/AVBypass` contains the C source for the interpose dylib, which is
  built separately.
- `Sources/BypassProbe` contains the linked C probe that verifies the interpose
  after re-execution.
- `Sources/SignalMonitor` contains the C termination monitor linked into the
  executable and its Clang module header.
- `Tests/AirPodsControlTests` mirrors the Swift module's interfaces.
  All Swift tests and their helpers live directly in this folder and use
  Swift Testing.
- `Tests/CLIOutputTests` compiles a small device-free Swift fixture to check
  CLI output contracts.
- `Tests/CLIContractTests` verifies the built executable's output and exit
  codes.
- `Tests/SignalMonitorTests` verifies cross-thread signal teardown directly in
  C.
- `Tests/ReleasePleaseTests` verifies that a Release Please pull request body
  still parses.
- `Tests/ResolvePrefixTests` verifies install-prefix path rules.
- `Tests/InstallFromSourceTests` verifies the source install script.
- `Tests/VerifyRuntimeTests` verifies the DYLD interpose on a built CLI.
- `version.txt` is the single source for the CLI and release version. The
  Makefile generates the corresponding Swift constant under `build/`.

The names follow Swift target conventions. The Makefile is the source of
truth for builds: it compiles architectures the toolchain supports, ad-hoc
signs both artifacts, and installs them together.

### Contributor ownership

Keep changes with the layer that owns them:

- Runtime adapters and system API calls live in `PrivateAudio.swift`,
  `IOBluetoothAudio.swift`, `IOBluetoothInventory.swift`,
  `CoreAudioRoutingBackend.swift`, and `HALListeningModeTransport.swift`.
- `AudioRouting.swift` owns route contracts and observation.
- `ListeningModeCoordinator.swift` owns provider selection and session assembly.
- `BluetoothListeningModeMapping.swift` owns shared numeric values.
- `CLIOutput.swift` owns serialization.
- `ListeningModePreflight.swift` owns pure availability and cycle policy.
- `ListeningModeAllowOffCache.swift` owns the cache facade;
  `ListeningModeAllowOffCachePolicy.swift` owns evidence decisions;
  `ListeningModeAllowOffCacheStorage.swift` owns persistence and file I/O;
  and `ListeningModeAllowOffCacheLegacyMigration.swift` owns the one-time
  legacy copy.

Files this list does not name follow the same rule: keep a change in the
file that already owns its concern.

### Formatting

`mise install` installs the formatter versions pinned in `mise.toml`.

```sh
mise run format-check
mise run format
mise run swift-lint
```

These aggregate tasks check or format Swift and Markdown. SwiftFormat covers
`Package.swift`, `Sources/AirPodsControl`, `Tests/AirPodsControlTests`, and
`Tests/CLIOutputTests`, and skips generated files. The rules normalize line
endings, ensure a final newline, and remove trailing whitespace. They keep
two-space indentation.
`swift-lint` runs SwiftFormat's pinned `unusedArguments` check separately and
reports unused closure arguments without rewriting protocol or
Objective-C-facing declarations.

Use `mise run markdown-check` or `mise run markdown-format` when working on
Markdown only.

Keep formatter upgrades and whitespace cleanup separate from behavior changes.
Run `make test` after formatting. CI checks formatting and the Swift lint task
on pull requests and pushes to `main`.

Each local clone needs its own Git hook installation. After cloning the
repository, run:

```sh
mise exec -- pre-commit install
```

To run every hook against the repository without making a commit, run:

```sh
mise exec -- pre-commit run --all-files
```

### Documentation

Markdown files in the repository follow rumdl's standard 80-column wrapping.
Do not wrap GitHub pull request descriptions. rumdl never sees them. Use
the focused Markdown tasks above when needed. The optional Git hooks also
format and check Markdown.

## Pull requests

- Use a [Conventional Commit](https://www.conventionalcommits.org/) pull request
  title. The repository squash-merges pull requests, so that title becomes the
  commit used to generate versions and release notes. `feat`, `fix`, `perf`,
  and `revert` titles appear in those notes. Other types, including `ci`,
  `chore`, `test`, and `docs`, do not. Retitle a GitHub revert pull request
  to `revert:` and say what the wearer loses.
- Use `chore:` for formatter-only pull requests; `style:` is unsupported by the
  PR title check.
- Fill the pull request template. Do not wrap the description to 80 columns.
- Keep changes focused and explain the user-visible reason for them.
- Add or update tests for behavior changes.
- Update CLI help and the affected user-facing documentation when the interface
  changes.
- Preserve the script-friendly stdout and exit-code contract.
- Avoid new runtime dependencies unless they are essential.

Maintainers should follow [RELEASING.md](RELEASING.md) for releases and Homebrew
formula updates.

By contributing, you agree to license your contribution under the repository's
[MIT License](LICENSE).
