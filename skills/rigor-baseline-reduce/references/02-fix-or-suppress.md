# 02 — Act on the classification, then refresh

Covers **Phase 3** (act per site) and **Phase 4** (refresh the
baseline). Input: the per-site classifications from
[`01-classify.md`](01-classify.md).

## Phase 3 — Act

### Real bug → fix the code

Propose the fix and offer to apply it. The fix is ordinary code work
— the value is that Rigor surfaced a defect that was latent because
the line is rarely exercised. Common shapes:

- `possible-nil-receiver` → add the missing guard (`return unless x`,
  `x&.method`, an early raise), or fix the upstream code so the value
  is never `nil` here.
- `undefined-method` typo → correct the method name.
- argument-type mismatch → pass the right type, or fix the signature.

After a real-bug fix the diagnostic is *gone*, not suppressed — the
bucket count drops on its own.

### Stylistic / safe → `# rigor:disable` with intent

The code is staying as it is; the suppression is a deliberate,
recorded decision. Place a per-line comment at the end of the
offending line:

```ruby
config.fetch(:timeout)  # rigor:disable call.possible-nil-receiver — set in initializer
```

Placement rules:

- **Per-line `# rigor:disable <rule>`** is the default. It keeps the
  suppression visible exactly where it applies, and a future reader
  sees the intent. Always name the specific rule, never `all`.
- Add a short reason after the rule — *why* the site is safe. A bare
  `# rigor:disable` rots; `# rigor:disable … — set in initializer`
  survives review.
- **Per-file `# rigor:disable-file <rule>`** only when one file has
  many sites of the same rule and they are all the same safe idiom.
  Escalate this to the user as a decision (it is coarser — it also
  silences *future* sites of that rule in the file).

A `# rigor:disable`d diagnostic is suppressed *before* the baseline
filter, so once the comment is in place the site no longer counts
toward its bucket.

### False positive → open a Rigor issue

Leave the site baselined (do not `# rigor:disable` it — that would
imply the code is the thing to live with, when actually Rigor is).
Open an issue on the Rigor project:

<https://github.com/rigortype/rigor/issues>

A useful issue includes:

- The rule id and the exact diagnostic message.
- A **minimal** code snippet that reproduces the false positive —
  reduce it to the smallest shape that still mis-fires.
- What the correct inference should be, and why.
- The `rigor version` output.

This is the feedback loop that makes the analyzer better — a false
positive reported with a minimal repro is far more actionable than
one buried in a baseline. While the issue is open the baseline keeps
the site quiet.

## Phase 4 — Refresh the baseline

After working a rule (fixes applied, `# rigor:disable` comments
added, issues filed), the live diagnostic count for the touched
buckets has dropped below the recorded count. Make the baseline
reflect reality.

First, inspect the drift:

```sh
rigor baseline drift
```

This reports each bucket as `within` / `over` / `cleared` /
`reducible`. After a reduction session you expect `cleared` (the
bucket is now empty) and `reducible` (the bucket shrank but is not
empty) rows.

Then refresh:

```sh
rigor baseline regenerate
```

`regenerate` rewrites `.rigor-baseline.yml` from a fresh `rigor
check` run — cleared buckets disappear, reducible buckets get their
new lower counts. This is the command that *banks* the session's
gains: until you regenerate, the baseline still records the old,
higher numbers.

`rigor baseline prune` is the narrower tool — it drops only the
fully-`cleared` buckets and leaves reducible ones at their old count.
Prefer `regenerate` at the end of a reduction session; it captures
both kinds of progress in one step.

Commit the updated `.rigor-baseline.yml` together with the code
fixes and `# rigor:disable` comments, so the smaller baseline and the
work that earned it land together.

## Verifying the session

Confirm the gains held:

```sh
rigor baseline drift   # expect "No drift detected" after regenerate
rigor check            # the project's gate — should still pass
```

If the project's CI uses `rigor check --baseline-strict`, the run
after `regenerate` should be clean — a stale baseline (numbers not
refreshed) is exactly the deficit drift that gate fails on.

## Output of this module — session complete

- Code fixes for the real bugs.
- Intentional, reasoned `# rigor:disable` comments for the
  stylistic-safe sites.
- Rigor issues filed for the false positives.
- A regenerated, smaller `.rigor-baseline.yml`, committed with the
  work.

Run the skill again next session to take the next rule.
