---
status: accepted
---

# Copy the legacy Allow Off cache once

Renaming the cache directory left the old file in place. ADR 0002 copied
that file whenever the new file was missing, so deleting or purging the
new cache restored the old Allow Off evidence. The new cache is
disposable. A purge has to stay a purge.

## Decision

Copy
`~/Library/Caches/io.github.raulgg.airpods-control/allow-off-v1.json`
into `~/Library/Caches/io.github.raulgg.pods-control/` only while that
new directory is absent, and only when the older directory and file
already meet the cache's ownership, mode, and regular-file checks. The
copy leaves the older file in place and records
`allow-off-v1.migrated-to-pods-control` beside it.

The new directory appears only after the copy is complete. A failed copy
removes that unpublished directory and does not record the marker, so a
later call can retry. Once the new directory or the marker exists, a
missing new cache stays a miss and is not copied again. A marker that is
present but untrusted counts as finished. A check that cannot tell
whether the marker exists leaves the new directory unpublished.

## Consequences

This supersedes the legacy-copy rule in
[ADR 0002](0002-cache-av-derived-allow-off-availability.md). The rest of
that decision is unchanged: evidence, lifetime, privacy, and HAL
behavior.

Deleting the new cache restores the pre-cache HAL behavior for this CLI.
It does not forget the older file. A binary that still reads
`io.github.raulgg.airpods-control` can still use that file.
