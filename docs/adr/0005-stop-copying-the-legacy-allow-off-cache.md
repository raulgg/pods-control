---
status: accepted
---

# Stop copying the legacy Allow Off cache

ADR 0002 copied
`~/Library/Caches/io.github.raulgg.airpods-control/allow-off-v1.json`
into the renamed cache directory whenever the new file was missing. A
purged cache then came back from the old file. Making that copy happen
once, safely, needed a migration larger than the cache itself, and only
a few users ran the CLI under the old name.

## Decision

The cache reads and writes only
`~/Library/Caches/io.github.raulgg.pods-control/`. Nothing reads or
deletes the old directory.

## Consequences

This supersedes the legacy-copy rule in
[ADR 0002](0002-cache-av-derived-allow-off-availability.md). The rest of
that decision is unchanged.

Someone upgrading from a version that used the old directory starts
with an empty cache. That is the existing safe miss: an explicit
`set off` probes once, and the next eligible AV read stores evidence
again. The old directory stays until the user deletes it.
