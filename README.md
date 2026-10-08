# pods-control

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/airpods-control-banner-dark.png">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/airpods-control-banner-light.png">
    <img alt="pods-control: AirPods and Beats, controlled from your macOS terminal." src=".github/assets/airpods-control-banner-light.png" width="100%">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/raulgg/pods-control/actions/workflows/macos-validation.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/raulgg/pods-control/macos-validation.yml?branch=main&amp;style=flat-square&amp;label=CI"></a>&nbsp;
  <a href="https://github.com/raulgg/pods-control/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/raulgg/pods-control?style=flat-square&amp;color=0a0a0c"></a>&nbsp;
  <a href="#compatibility"><img alt="Tested on macOS Golden Gate 27" src="https://img.shields.io/badge/tested-macOS%20Golden%20Gate%2027-0a0a0c?style=flat-square&amp;logo=apple&amp;logoColor=white"></a>&nbsp;
  <a href="#install"><img alt="Homebrew" src="https://img.shields.io/badge/brew-raulgg%2Ftap%2Fpods--control-FBB040?style=flat-square&amp;logo=homebrew&amp;logoColor=black"></a>&nbsp;
  <a href="https://formulae.brew.sh/analytics/install/90d/"><img alt="Homebrew install events, last 90 days" src="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/raulgg/pods-control/badges/homebrew-installs.json&amp;style=flat-square"></a>&nbsp;
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square"></a>
</p>

Control AirPods and Beats listening modes (`off`, `transparency`, `adaptive`,
`noise-cancellation`) and Conversation Awareness on macOS. The command was
formerly `airpods-control`.

```console
$ pods-control status
My AirPods Pro:
  Listening mode: transparency
  Conversation Awareness: off
  Selected as audio output: yes
  Selected as audio input: no
  Left ear placement: in-ear
  Right ear placement: out-of-ear
$ pods-control listening-mode set noise-cancellation
ok
```

A successful write means the selected macOS provider reports the requested
state within a bounded readback window; it is not a direct accessory
acknowledgement. Each operational command performs one operation and exits.
The CLI does not poll in the background or automate the UI.

## Features

- Read, set, list, or cycle the `off`, `transparency`, `adaptive`, and
  `noise-cancellation` listening modes.
- Read or set Conversation Awareness.
- Report listening mode, Conversation Awareness, left/right ear placement, and
  whether each eligible connected AirPods or Beats device represented by Core
  Audio is selected as the macOS audio output or input with one `status`
  command.
- Select a compatible output device by exact name.
- Use it from scripts, hotkeys, Stream Decks, Shortcuts, or `launchd`.
  Operational commands have stable stdout, documented exit codes, JSON output,
  and opt-in debug diagnostics.

## Requirements

- macOS only.
- A compatible AirPods or Beats device connected over Bluetooth. Operational
  listening-mode commands can use either the selected private AV output-device
  interface or an eligible mapped Core Audio HAL output endpoint. Conversation
  Awareness and `support-report` still require the private AV interface
  described in [device compatibility](docs/compatibility.md).
- Command Line Tools (`clang` and `swiftc`). Install them with
  `xcode-select --install`; full Xcode is not required. Homebrew and source
  installs both compile on your Mac.

## Install

Homebrew is the recommended path. The
[formula](https://github.com/raulgg/homebrew-tap/blob/main/Formula/pods-control.rb)
downloads the tagged source and compiles the native architecture with your
Command Line Tools.

```sh
brew install raulgg/tap/pods-control
brew install airpods-control
brew upgrade pods-control
brew uninstall pods-control
```

`brew install airpods-control` and `brew upgrade airpods-control` stay on
the old formula and print a deprecation. They do not create the
`pods-control` keg. To switch, uninstall `airpods-control`, then run
`brew install --formula raulgg/tap/pods-control`.

`airpods-control` on `PATH` is the same binary as `pods-control` and prints
nothing extra. `man airpods-control` shows the same page. This project is not
CocoaPods and not Kubernetes. It runs on macOS only: not iOS, Windows, Linux,
or Android, and not through Control Center or Accessibility.

See the [security and trust model](SECURITY.md) before installing.

### From source

If you do not use Homebrew, a tagged install script fetches that same release,
ensures Command Line Tools, compiles, and installs. Re-running it replaces an
existing install from this project at the same prefix. Pin the tag in the URL
so the script and the software stay matched (`--version latest` is opt-in).
This one-liner works only after a release that contains the script. Replace
`vVERSION` with that tag. Do not pin `main`.

```sh
base=https://raw.githubusercontent.com/raulgg/pods-control/vVERSION
curl -fsSL "$base/scripts/install-from-source.sh" | sh -s -- \
  --prefix "$HOME/.local"
```

Omit `--prefix` to install to `/usr/local` (may prompt for `sudo` only when
copying files). Uninstall with the same `--prefix` used to install:

```sh
base=https://raw.githubusercontent.com/raulgg/pods-control/vVERSION
curl -fsSL "$base/scripts/install-from-source.sh" | sh -s -- \
  --prefix "$HOME/.local" --uninstall
```

Contributors who already have a clone can compile it directly:

```sh
git clone https://github.com/raulgg/pods-control
cd pods-control
make
sudo make install
```

`make install` defaults to `/usr/local` and honors `PREFIX` and `DESTDIR`.
The build produces an ad-hoc-signed executable and `avbypass.dylib`.

## Quick start

```sh
# Read or change the listening mode
pods-control listening-mode get
pods-control listening-mode set noise-cancellation

# List supported modes or cycle between them
pods-control listening-mode list
pods-control listening-mode cycle

# Read or change Conversation Awareness
pods-control conversation-awareness get
pods-control conversation-awareness set off

# Read status for every eligible device represented by Core Audio
pods-control status

# Target a device or request structured output
pods-control --device "My AirPods Pro" listening-mode get
pods-control status --device "My AirPods Pro" --json
```

`listening-mode` can be shortened to `lm`, and `conversation-awareness` to `ca`;
`status` has no alias. Without `--device`, `status` reports every eligible
AirPods or Beats record derived from the currently available Core Audio device
list, even when it is not the selected audio output. The individual resource
commands retain their documented adapters. Listening-mode commands combine AV
and eligible HAL representations into logical targets, select one target
automatically, and prompt in a fully interactive terminal when several remain.
Declining the chooser, automated ambiguity, and duplicate exact names all report
`ambiguous-device` (exit `8`). Multiple selected HAL targets fail closed when
ambiguity remains; leftover AV records do not enter the HAL chooser. On systems
where HAL control is entirely unavailable, a single compatible AV output is
selected; multiple outputs are ambiguous. Run `pods-control --help` for
built-in help. The [complete CLI reference](docs/cli.md) covers aliases, JSON
output, diagnostics, write verification, and exit codes. After installation, you
can also run `man pods-control`.

## Documentation

- [CLI reference](docs/cli.md)
- [Device compatibility](docs/compatibility.md)
- [Hardware testing](docs/hardware-testing.md)
- [Security and trust model](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

## How it works

Conversation Awareness uses the private `AVOutputDevice` control object in
`AVRouting.framework`. This object is macOS's per-endpoint audio control
surface. Listening-mode commands use that same provider when a
command-ready AirPods endpoint is selected, and the mapped BTAudio HAL
(Core Audio's hardware abstraction layer) exposes `lstm`/`lsms` properties
when the device is unselected. For a Bluetooth device group with several Core
Audio outputs, the HAL provider targets an output that exposes `lstm`; that
control endpoint may differ from the named sibling used for display. Provider
selection and
all pre-write state, capability, setter, and bounded readback operations are
sticky for one command. The CLI never changes the default route or starts an
audio stream. `status` remains a separate read-only Core Audio adapter.

HAL's supported-mode mask does not expose the user-configured Allow Off
setting. After the exact output endpoint advertises Off in an eligible AV
availability read, or an AV-backed `get` reports current Off, the CLI can reuse
that positive observation for HAL-backed `list`, `set off`, and explicit cycles
containing Off. The observation expires after seven days and is not refreshed
by use; the default cycle always excludes Off. On a cache miss, only an explicit
`set off` or explicit cycle containing Off may perform one HAL probe. A
setter-accepted definitive non-Off readback records target-specific denial and
reports `unsupported`; rejection is `unavailable`, while an unreadable or
timed-out final state is `no-op` and records no denial. See
[the CLI reference](docs/cli.md#cached-allow-off-availability) and
[ADR 0002](docs/adr/0002-cache-av-derived-allow-off-availability.md) for the
evidence and invalidation rules, and
[ADR 0005](docs/adr/0005-copy-the-legacy-allow-off-cache-once.md) for the
one-time legacy copy.

The inventory starts with macOS's public list of available Core Audio devices.
It accepts an ordinary, nonaggregate classic-Bluetooth endpoint when the
endpoint is alive and ready, has an audio stream, and maps to an
`IOBluetoothDevice`. An undocumented HAL property identifies Apple audio
hardware. If that property is unavailable, `status` falls back to an allowlisted
Apple or Beats manufacturer. Input and output endpoints form one record only
when their mapped objects compare equal in both directions. The output endpoint
supplies the preferred name. Names are for display and `--device` matching, not
identity.

Input and output selection are checked independently. For each direction,
`status` maps the ordinary default Core Audio endpoint and compares the result
with the record's mapped Bluetooth object. Aggregate routes and known unrelated
transports produce `no`. Bluetooth LE, USB, unknown transports, missing
properties, and unavailable mappings produce `unknown`. A failed read or mapper
call is reported as a read error. This includes failures while reading the
default route, device class, or transport.

An inactive endpoint may still expose its current listening mode through an
undocumented HAL property. The mapped Bluetooth object is the fallback when the
HAL property is unavailable or neutral, or when its read fails. The active AV
endpoint has the highest priority when it can be joined safely to the default
output. Unknown AV or HAL values, and conflicting HAL values, leave the mode
`unknown` rather than falling back.

The active-output join translates
`AVOutputContext.associatedAudioDeviceID` through Core Audio and compares the
result with the stable default output. That output's mapped Bluetooth object
must match the status record. The probe also samples `AVOutputDevice.deviceID`
before and after to catch a route change. Conversation Awareness is `unknown`
when this join is unavailable.

When macOS exposes the runtime-gated ear-detection properties, `status` also
reports `leftEarPlacement` and `rightEarPlacement` as `in-ear`, `out-of-ear`, or
`in-case`. The read is one-pass and read-only; missing placement properties omit
the fields, while unknown or conflicting evidence is rendered as `unknown` (or
JSON `null`). This status path does not scan BLE advertisements or change
Conversation Awareness.

Core Audio handles and the identifiers used by the enrichment probe stay inside
the process. The CLI does not parse or log them. Status inventory and target
selection do not read Bluetooth addresses, Core Audio UIDs, or private route
identifiers, and raw HAL values are not emitted. After target selection, Allow
Off cache correlation reads the exact public Core Audio UID transiently and
persists a random per-cache salt, a salted full SHA-256 digest, and the
observation time. The raw UID is never persisted; the raw UID, digest, and salt
are never printed or logged. `support-report` accesses neither this cache nor
the status path.

To reach the shared system audio context used by feature controls, the
`pods-control` process loads the small interpose library in
[`Sources/AVBypass/bypass.c`](Sources/AVBypass/bypass.c). The library satisfies
one private entitlement check inside that process and passes every other
entitlement query through unchanged. It does not elevate privileges or affect
other processes.

Source builds ad-hoc-sign the executable and companion dylib. Review the
[security documentation](SECURITY.md) before choosing an installation path.

## Compatibility

Apple can change or remove this private API in any macOS update. Compatibility
varies by device, firmware, and macOS version; see the [device and capability
matrix](docs/compatibility.md) for current results. Reports are welcome, but a
report does not by itself establish support.

To share compatibility details:

1. Connect exactly one compatible AirPods or Beats device as a macOS output
   device.
2. Run `pods-control support-report`.
3. Choose whether to run the consented write tests when asked.
4. Review the report, add any safe optional notes, complete the privacy
   confirmation, and submit the GitHub issue if you choose to open it.

`support-report` builds the report locally and prints it before offering to open
GitHub. It never reads the customizable device name, firmware version, serial
numbers, Bluetooth/MAC addresses, account data, or raw system dumps and logs. It
does not enumerate the Core Audio status inventory, query selected audio routes,
call the selection mapper, run active-output enrichment, or read routing
identifiers. It does not use the clipboard, send telemetry, or submit a report.
Opening the prefilled form is your choice, and GitHub still requires you to
review and submit the issue.

The optional write tests run only with your consent (the interactive question or
`--with-write-tests`). They temporarily switch through the advertised listening
modes recognized by this CLI, toggle Conversation Awareness, and then try to
restore the captured initial settings. The tests may be disruptive: mode
switches are audible and noise control changes while the device is worn. Do not
run them during a call. Consent only if you accept this. Without consent,
`support-report` does not change device settings or intentionally interrupt
audio.

The [CLI reference](docs/cli.md#contributor-compatibility-report) documents the
exact report contents and privacy rules, and its
[write-test section](docs/cli.md#consented-write-tests) covers the plan, skip
rules, verdict vocabulary, restoration behavior, and exit codes.

## Credits

[NoiseBuddy](https://github.com/insidegui/NoiseBuddy) by Guilherme Rambo
documented the AVFoundation technique used by this project.

`pods-control` is an independent tool and is not endorsed by Apple.
AirPods and AirPods Pro are trademarks of Apple Inc. Beats is a trademark of
Beats Electronics, LLC.

## License

MIT. See [LICENSE](LICENSE).
