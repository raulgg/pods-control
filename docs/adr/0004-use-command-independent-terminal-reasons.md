---
status: accepted
---

# Use command-independent CLI terminal reasons

Every deliberately handled CLI termination has a typed, command-independent
terminal reason, and each normal terminal reason has exactly one numeric exit
code. Semantic clarity takes precedence over preserving an ambiguous historic
mapping. Surviving reasons keep their existing numbers, while the newly split
reasons follow the accepted logical ordering at codes `7` and `8`. Plain and
JSON presentation remain separate from the reason, and caught Unix signals
retain `128 + signal`.

## Decision

| Code | Terminal reason |
| ---: | --- |
| `0` | `success` |
| `1` | `no-device` |
| `2` | `bad-args` |
| `3` | `no-op` |
| `4` | `unsupported` |
| `5` | `read-error` |
| `6` | `unavailable` |
| `7` | `state-uncertain` |
| `8` | `ambiguous-device` |

When multiple candidates remain, both an unavailable chooser and a displayed
chooser that the user declines terminate as `ambiguous-device`; there is no
`cancelled` outcome. Caught signals form a separate typed family in the
conventional signal namespace. Crashes, forced termination, and uncaught
signals are outside this deliberately handled contract. A `--help` or `-h`
request takes precedence over otherwise malformed arguments and succeeds after
rendering contextual help; version output remains successful only for a valid
version invocation.

### Structured presentation

The existing JSON schema remains authoritative; no `terminalReason` field is
added. `success` maps to `"result":"ok"` without `error`, and `no-op` maps to
`"result":"no-op"` without `error`. Every other normal reason maps to
`"result":"error"` with `error` set to the canonical terminal-reason token.
Caught signals retain `"result":"interrupted"` plus the numeric `signal` and
omit `error`. A caught signal remains the terminal reason even when the command
cannot confirm restoration; that uncertainty stays in the detailed report.
Command-specific data fields remain unchanged. A classified parse failure
may add `reason` with the same sentence written to stderr. `error` stays
`bad-args`.

### Mutation classification

An absent control path, a property reported as not settable, or an explicit
setter rejection before a side effect is accepted is `unavailable`. `no-op` is
reserved for a setter-accepted request whose requested feature state cannot be
verified and that leaves no separate required final-state invariant unresolved.
Failure to confirm a required final state after side effects is
`state-uncertain` instead.

### Plain presentation

Plain output is not derived from the numeric code. Parser and
individual-resource failures use their canonical tokens, while `status` and
`support-report` retain their established detailed prose and report rendering. A
`state-uncertain` support report keeps its restoration details. A declined
chooser uses the canonical `ambiguous-device` failure presentation. The
implementation chooses a terminal reason from typed state and never infers it by
parsing output.

## Consequences

This is a breaking scripting-contract change for outcomes split from the old
selection and no-op buckets. `no-device` remains `1`; ambiguous selection and a
declined chooser move from `1` to `ambiguous-device` code `8`; and failed
restoration moves from `3` to `state-uncertain` code `7`. A uniquely resolved
support-report candidate whose product identity is missing or unrecognized now
produces a successful partial report instead of exiting `1`; identity is report
data rather than a prerequisite for the report. An identity gap does not by
itself disable explicitly consented write tests: eligibility continues to come
from the captured runtime plan and its existing verification and restoration
safeguards. The release documentation must include a complete migration table
and identify the change as breaking. The repository does not add a changelog;
the canonical migration stays in the CLI documentation and is carried into the
GitHub release notes when the release is created. Numeric codes are stable
identifiers, not a severity ordering; adding a future normal reason changes the
public CLI contract.
