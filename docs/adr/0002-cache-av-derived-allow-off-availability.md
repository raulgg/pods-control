---
status: accepted
---

# Cache AV-derived Allow Off availability for HAL commands

The BTAudio HAL `lsms` property describes the supported non-Off listening
modes, but it does not expose the separate user-configured Allow Off setting.
The active AV provider does expose Off in its available-mode inventory when
Allow Off is enabled. A device can later remain connected and controllable
through HAL after it stops being the selected audio output, so the CLI can
reuse a recent AV observation without changing the route or starting audio.

This is deliberately a weak cache. A positive record means only that the exact
output endpoint recently advertised or reported Off. A denial record means an
accepted Off request ended with definitive known non-Off readback. Neither
record is a current read of the AirPods setting, a durable device identity, or a
protocol acknowledgement.

## Decision

The route-aware coordinator may cache a positive AV observation of Allow Off
and consume it only for HAL-backed listening-mode commands. The transport
selection and stickiness rules in
[ADR 0001](0001-route-aware-listening-mode-control.md) remain unchanged.

### Evidence and updates

An active AV availability read is cache-eligible only when that read is
already required for:

- `listening-mode list`;
- `listening-mode set off`; or
- an explicit `listening-mode cycle --modes ...` set that contains Off.

A successful eligible availability read that advertises Off writes or
refreshes the positive record. A successful eligible read that omits Off
invalidates older positive evidence but does not establish target-specific
denial. An internal tombstone preserves observation ordering so an older
in-flight positive read cannot restore stale evidence. A selector failure, read
failure, or unavailable AV endpoint leaves the record unchanged.

An AV-backed `listening-mode get` may also write or refresh the positive record
when its result is Off. A non-Off current-mode result is not an availability
observation and does not delete the record. Incidental current-mode reads made
by other operations do not warm the cache. The coordinator never performs an
extra AV read solely to warm or refresh it, and a HAL current-mode observation
never updates it. Fresh, successful AV evidence takes precedence over cached
evidence in the same command.

Any accepted Off request can establish denial when its full bounded readback
ends in a known non-Off mode. The coordinator replaces older positive evidence
with that denial whether the request used AV, cached HAL authorization, or the
explicit HAL probe described below. A rejected setter, timeout, failed read, or
unknown final state creates no denial.

### Correlation and privacy

The cache key is the full SHA-256 digest of a random per-cache salt followed by
the exact, case-sensitive public Core Audio UID of the joined output endpoint.
The cache persists the salt, digest, and observation time. The raw UID exists in
memory only long enough to correlate the already-selected AV and HAL
representations and derive the digest, and is never persisted. The CLI never
prints or logs the raw UID, digest, or salt.

This correlation is downstream of target selection. It must never select a
device, merge records, disambiguate names, or change AV/HAL routing. If the
selected target cannot be correlated to exactly one output endpoint, the
lookup is a silent cache miss. It cannot prevent the current explicit probe,
but the probe cannot persist reusable evidence without unique correlation.

### Storage and lifetime

Positive records, denial records, and internal ordering tombstones are stored
in:

```text
~/Library/Caches/io.github.raulgg.pods-control/allow-off-v1.json
```

A missing file is copied from
`~/Library/Caches/io.github.raulgg.airpods-control/allow-off-v1.json`
when that older directory and file already meet the cache's ownership,
mode, and regular-file checks. The older file is not deleted in this
version. A failed copy is a miss.

[ADR 0005](0005-copy-the-legacy-allow-off-cache-once.md) supersedes this
legacy-copy rule.

Each positive or denial record expires seven days after its observation. The
lifetime is non-sliding: consuming a record does not refresh it. Internal
tombstones only order observations and are exposed as a miss, not a denial. New
evidence replaces older state for that endpoint; macOS version changes do not
extend or invalidate it. Missing, expired, unreadable, or malformed cache data
is a miss. The file is disposable cache data and should be
excluded from backups; deleting it safely restores the pre-cache behavior. The
cache directory and files are restricted to the current user, and updates use
atomic replacement so an interrupted write becomes a miss rather than partial
trusted evidence. If a negative update cannot obtain the bounded shared mutation
lock, it appends a digest-keyed deny marker beside the cache; lookups honor that
marker before using positive evidence. A failed negative write while holding the
lock removes the disposable cache instead of retaining stale positive evidence.

### HAL behavior

When a valid positive record is consumed for the exact HAL target:

- `listening-mode list` adds Off to the modes derived from `lsms`;
- `listening-mode set off` may attempt the normal HAL write; and
- an explicit cycle set containing Off may include it.

The default cycle continues to exclude Off, even on a cache hit. HAL `list`
omits Off on a miss. An explicit `set off` or explicit cycle containing Off may
make one setter attempt as a probe when there is neither positive evidence nor
a cached denial. `get`, `list`, and the default cycle never probe.

The probe is classified from the evidence it produces. Accepted, definitive
Off readback succeeds. Accepted, definitive known non-Off readback is
`unsupported` and persists denial. A missing or rejecting provider or setter is
`unavailable`. Accepted but unreadable, unknown, or timed-out final state is
`no-op` and creates no denial. A cached denial prevents another probe until it
expires or newer positive evidence supersedes it.

Provider stickiness, deadlines, readback, and the prohibition on route changes
or raw AACP access are unaffected. An accepted positive-evidence-authorized Off
write must still complete the normal bounded HAL readback. If the definitive
final state is known non-Off, that invocation reports `no-op` with the actual
state and persists denial for later invocations. It does not retry through AV,
fall back to inferred Transparency, or choose another cycle target.

### Output and diagnostics

Plain output is unchanged. JSON adds cache provenance only when cached evidence
was actually consumed:

```json
{
  "allowOffAvailability": {
    "expiresAt": "2030-01-08T12:00:00.000Z",
    "observedAt": "2030-01-01T12:00:00.000Z",
    "source": "cached-av-observation"
  }
}
```

Live AV evidence and cache misses do not add this object. Debug diagnostics may
report only the bounded cache outcome (`hit` or `miss`) and record age. They do
not expose the UID, digest, salt, cache key, or cache contents. `support-report`
does not access the cache or include its data.

## Consequences

HAL-backed commands can honor a recently observed Allow Off setting while the
AirPods are connected but not selected as the macOS output. The evidence can be
stale during the interval after the setting changes and before another eligible
AV observation or a definitive HAL write mismatch corrects it. Therefore a
cache hit is always described as cached AV-derived availability, never as a
live device query.

This decision supersedes ADR 0001's interim Off limitation and its own earlier
cache-miss prohibition on explicit Off attempts. It does not
change target selection, provider routing, transport stickiness, or the meaning
of a matching macOS readback. The stale gap can end through a newer AV
availability observation or an accepted Off write with definitive non-Off
readback; only the latter establishes reusable denial.
