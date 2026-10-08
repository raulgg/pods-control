# Domain context

## Glossary

**Command execution**
: Evaluates a parsed CLI invocation and produces a command outcome. It requests
  compatible audio devices from the runtime adapter only when the command needs
  them. Commands needing one target use single-or-exact selection; aggregate
  status uses all-or-exact selection. Either policy reports multiple exact
  matches as ambiguous. Execution does not parse arguments, render
  output, or terminate the process.

**Command outcome**
: Everything produced by command execution: its terminal reason, corresponding
  exit code, plain output, and structured JSON payload.

**Terminal reason**
: A command-independent semantic explanation for any deliberately handled CLI
  termination, including caught signals but excluding crashes and forced or
  uncaught termination. Each normal terminal reason has exactly one exit code
  and remains distinct from command-specific plain or JSON presentation.

**Normal terminal reasons**
: The closed set `success`, `bad-args`, `no-device`, `ambiguous-device`,
  `no-op`, `state-uncertain`, `unsupported`, `unavailable`, and `read-error`.
  Caught Unix signals use a separate typed `128 + signal` namespace.

**Successful terminal reason**
: The terminal reason used when the CLI fulfilled its primary contract without
  violating a safety invariant. Optional work may be skipped or report
  negative results; failed restoration is not successful.

**Device terminal reasons**
: `no-device` means the command resolved no target under its device contract;
  `ambiguous-device` means several possible targets remain, including when an
  interactive chooser is unavailable or declined. There is no separate
  cancellation reason. Missing or unrecognized
  support-report product identity is report data, not a terminal reason: the
  command emits a partial report from the safe observations it can collect and
  remains successful.

**No-op terminal reason**
: A setter accepted the request, but the command did not verify the requested
  feature state and no separate required final-state invariant remains
  unresolved. A setter that explicitly rejects the request is `unavailable`,
  not `no-op`.

**State-uncertain terminal reason**
: The command cannot confirm a required final device state after side effects,
  including restoration after support-report write tests when no caught signal
  owns termination. It is distinct from an unverified requested feature state
  and from a failed primary information read; a caught signal retains its
  conventional terminal reason while the report carries restoration details.

**Read-error terminal reason**
: The command attempted its primary information read but produced no usable
  result. A read failure that instead prevents confirmation of a required final
  state after side effects is `state-uncertain`; a successfully read unresolved
  observation is not a read error.

**Unresolved observation**
: A successful read whose value the CLI cannot interpret or prove. Read-only
  commands may report it as `unknown` and remain successful; a mutation that
  requires a concrete value is `unavailable` before side effects begin.

**Unsupported terminal reason**
: Authoritative, target-specific evidence definitively excludes the requested
  operation. Valid negative Allow Off evidence qualifies; missing or unresolved
  evidence does not.

**Unavailable terminal reason**
: The CLI cannot currently establish or access a prerequisite, catalog,
  provider, capability, or control path required to attempt an operation. It is
  also the result when an invoked setter explicitly rejects the request or
  reports that it is not settable before accepting a side effect. It is not
  evidence that the target definitively excludes the operation.

**Status snapshot**
: A read-only observation of selection, listening mode, Conversation Awareness,
  and left/right ear placement for one compatible device. One invocation reads
  the available Core Audio inventory and shares the same input and output route
  observations across all records. A field contains a value,
  proven-unsupported result, unresolved result, or read error. Unresolved fields
  and read errors are displayed as `unknown`; read errors also name the affected
  field. Unsupported feature fields are omitted. Records follow the adapter's
  deduplicated inventory order, with output endpoints preferred, but that order
  is not a stable interface.

**Status device inventory**
: The status-only inventory from public `kAudioHardwarePropertyDevices`. An
  endpoint must be ordinary and nonaggregate, use classic Bluetooth, be alive,
  have an audio stream, and map through
  `IOBluetoothAudioManager.bluetoothDevice:` to an `IOBluetoothDevice`. An
  undocumented HAL property identifies Apple audio hardware. An allowlisted
  Apple or Beats manufacturer is checked only when that property is unavailable.
  Endpoints form one record when their mapped objects compare equal in both
  directions. The output endpoint is preferred. A Core Audio name supplies the
  heading and `--device` target but is not used as identity. Because the
  inventory is independent of the selected defaults, input-only and unselected
  devices remain visible.

**Selected audio device**
: A device whose identity exactly matches the macOS default route for ordinary
  audio input or output at the moment of a status snapshot; membership in a
  composite route does not qualify. Selection excludes the system-alert output
  route and does not imply active playback or recording.
  Avoid: current audio device, active audio device, system output device.

**Audio-device selection observation**
: A selected, not-selected, unresolved, or read-error result for one device and
  one direction. Not-selected requires proof: a composite route, a known
  unrelated transport, or a different mapped classic-Bluetooth device.
  Bluetooth LE, USB, unknown transports, missing properties, and unavailable or
  nil mappings are unresolved. A failed default-route, class, transport, or
  mapper read is a read error. Both unresolved and read-error results display as
  `unknown`, but a read error also names the affected field.

**Endpoint-to-Bluetooth-device mapping**
: The system operation that maps an ordinary classic-Bluetooth Core Audio
  endpoint to an `IOBluetoothDevice`. Inventory uses the result to form records;
  selection maps the ordinary default and compares the two objects in both
  directions. Neither path compares a name, model, Bluetooth/MAC address, Core
  Audio UID, private route ID, or discovery position. Aggregate routes do not
  select their members, and a known unrelated transport proves non-selection.
  Bluetooth LE, USB, unknown transports, missing properties, and unavailable or
  nil mappings remain unresolved. A failed mapper call is a read error.

**Active-output feature enrichment**
: An optional status probe for Conversation Awareness and active listening mode.
  It joins the active AV endpoint to an inventoried device through the stable
  default Core Audio output. The probe asks Core Audio to translate the bounded
  `AVOutputContext.associatedAudioDeviceID`, then compares the result with the
  default output device ID. It samples the private `AVOutputDevice.deviceID`
  before and after to reject an endpoint change. These identifiers are not used
  as Bluetooth identity or selection evidence, and they are never logged,
  rendered, or included in a support report. Conversation Awareness remains
  unresolved without this exact join.

  Listening mode uses the first safe recognized value in this order: active AV,
  one consistent HAL current mode, then the mapped Bluetooth object. An unknown
  active AV value stops the lookup. A future or unknown nonzero HAL value, or
  conflicting HAL values, does the same. The mapped object is tried only when
  HAL is unavailable or neutral, or when a HAL read fails. That failure is
  retained. If the fallback cannot resolve the mode, the field is `unknown` with
  a Listening mode read error.

**Listening mode**
: A canonical user-facing AirPods state: `off`, `transparency`, `adaptive`,
  or `noise-cancellation`, in Cycle order. Parsing, aliases, listing,
  cycling, and write-result interpretation use these names. The default
  cycle leaves `off` out. An explicit cycle includes `off` only when its
  set names `off` and the device supports it. `--modes` selects a cycle
  set. A current mode outside the set advances from its place in the
  Cycle order. `--explicit-order` cycles those modes in the order given.
  An unknown mode, or a current mode outside the set, starts at the
  first mode in that order. Cycling skips a mode the device does not
  support. Support-report write tests probe Cycle order in reverse. Raw
  private AVFoundation or system HAL values are not listening modes until
  their adapter translates them.

**Compatible audio device**
: The device interface used by command execution. It provides typed status-field
  observations, supported features, current canonical states, and observed write
  results without exposing Objective-C selectors or private AVFoundation values.
  It also provides the device name unless the adapter was asked not to read it.

**Private Audio adapter**
: The production adapter used by individual resource commands and compatibility
  reporting. It discovers AVFoundation objects, translates private values,
  invokes selectors, and observes asynchronous writes through the main run
  loop.

**Status Core Audio adapter**
: The production adapter for status. It starts with the public list of available
  Core Audio devices, maps eligible classic-Bluetooth endpoints to
  `IOBluetoothDevice` objects, and deduplicates only when those objects compare
  equal in both directions. A runtime-gated HAL property is the primary Apple
  audio compatibility signal. An allowlisted manufacturer is used only when
  that property is unavailable. HAL current-mode state can populate inactive
  records, with the mapped Bluetooth object as a fallback.

  For each direction, the adapter reads the ordinary Core Audio default and its
  transport, rejects composite routes, rules out known unrelated transports,
  and compares the mapped default with the record. Bluetooth LE, USB, unknown
  transports, missing properties, and unavailable or nil mappings remain
  unresolved. Failed route, class, transport, or mapper reads are read errors.
  Active-output enrichment cannot change selection. The adapter does not expose
  raw HAL values or routing and Bluetooth identifiers to command execution. When
  macOS exposes the runtime-gated `iesb`, `pris`, and `iede` properties, it also
  captures a typed left/right ear-placement pair during status inventory. The
  placement observation is one-pass and read-only; missing or disabled
  properties are unsupported, while unknown or conflicting evidence remains
  unresolved. BLE advertisements are not used as an identity fallback.

**Support report document**
: Compatibility data built from a pre-write device snapshot and optional
  write-test results. Product identity is optional: missing, rejected, or
  unrecognized identity produces a successful partial document from the safe
  observations that remain. Identity does not decide write-test eligibility;
  the captured runtime plan, explicit consent, bounded verification, and
  restoration rules do. Listening-mode write tests probe advertised modes in
  reverse Cycle order, so an Off fallback to Transparency cannot make the
  Transparency write already-current. The document contains
  one result row per attempted write and omits unresolved values instead of
  turning them into prose. The terminal and GitHub renderers format the
  document and choose how to describe absent values; they do not inspect raw
  device or write-test behavior.

**Device write observation**
: What a compatible audio device reports after a write attempt: whether the
  underlying setter accepted the request and which final state was observed
  within the bounded settling window.

## Persistence-cache discovery

**Allow Off availability observation**
: A successful observation that a device's active AV control surface did or did
  not advertise Off at a particular time. It is evidence about that observation
  time, not a perpetual statement of the device's current configuration. Off
  establishes positive evidence; omission invalidates older positive evidence
  but does not establish target-specific denial.

**Cache-eligible AV observation**
: A successful live AV availability read for an availability list, `set off`,
  or a cycle whose explicit mode set contains Off, after the observation has
  been joined to the exact device. A successful live AV current-mode read is
  also eligible when, and only when, it returns Off; other current modes do not
  establish Allow Off availability. No operation adds an AV read solely to warm
  the cache.

**Allow Off evidence invalidation**
: Removal of older positive evidence after a later AV availability observation
  omits Off. An internal ordering tombstone prevents delayed older positive
  work from restoring that evidence, but is exposed as a cache miss rather than
  a target-specific denial.

**Allow Off denial evidence**
: An accepted Off request followed by definitive known non-Off readback. It is
  affirmative target-specific evidence for `unsupported` on a probe and blocks
  later probes until it expires or newer positive evidence supersedes it.
  Setter rejection, timeout, failed read, and unknown final state establish no
  denial.

**Cache-authorized Off mismatch**
: An Off write authorized by positive evidence whose definitive final state is
  non-Off. The current invocation reports no-op, includes the actual final mode
  in JSON, replaces the positive with denial evidence, and stops without
  retrying a provider, applying a fallback, or advancing a cycle again.

**Cached availability provenance**
: Metadata emitted only when cached Off evidence is consumed. Plain operational
  output remains unchanged. Additive JSON identifies the cache source and its
  observation and expiry times; debug output is limited to hit, miss, and age.
  The raw UID, digest, and salt are never rendered, logged, or included in a
  support report.

**Cached Allow Off availability**
: The last persisted positive evidence, denial evidence, or internal ordering
  tombstone associated with one resolved device. Evidence remains usable for
  seven days from observation; cache reads never extend that deadline. Positive
  evidence can add Off to a HAL list or authorize an Off write. Denial evidence
  prevents a repeated probe. An internal tombstone only orders observations
  and appears as a miss. `get`, `list`, and the default cycle never probe; an
  explicit Off request may probe on a miss. A selector or read failure leaves
  evidence unchanged.
  _Avoid_: Current Allow Off state, cached capability

**Cache correlation key**
: A local pseudonymous value that associates a previously resolved device with
  its cache entry. It neither selects nor merges devices and is not device
  identity for routing or command targeting. Its settled representation is a
  per-cache salted, full SHA-256 digest of the exact joined output endpoint's
  case-sensitive Core Audio device UID. The raw UID exists only transiently for
  correlation and is never persisted, logged, or exposed.
  _Avoid_: Device identity, device name

**Ambiguous cache correlation**
: A non-unique or conflicting correlation between cache records and current
  exact device groups. It is treated only as a cache miss: HAL listing omits
  Off, cache evidence authorizes no write, and the CLI neither guesses, merges,
  selects a device, nor emits an ambiguity error solely because of the cache.
  It does not prevent the current explicit probe, but no reusable evidence can
  be persisted without unique correlation.

**Allow Off cache store**
: The deliberately disposable, per-user, backup-excluded file at
  `~/Library/Caches/io.github.raulgg.pods-control/allow-off-v1.json`. While
  that directory is absent, a trusted
  `~/Library/Caches/io.github.raulgg.airpods-control/allow-off-v1.json` is
  copied once and `allow-off-v1.migrated-to-pods-control` is recorded
  beside the older file. That copy-or-stamp decision holds
  `allow-off-v1.migration.lock` in the legacy directory. The copy is
  published by renaming a private directory, so the new directory appears
  only with its cache file and deny markers. The marker is written after
  that rename. A failed copy removes the private directory and does not
  write the marker. The older cache file is left in place. Once the new
  directory or the marker exists, absence, a failed copy, or removal by
  cache cleanup is a cache miss, not an operational error.

**Stale availability gap**
: The interval after Allow Off changes outside this CLI and before a later live
  observation refreshes or invalidates the cached observation. During this gap,
  HAL-only behavior may reflect the last observation instead of current state.
