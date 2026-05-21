# Redmine per-commit detection probe — does Rigor catch real bugs?

**Date:** 2026-05-21. **Rigor:** v0.1.9 (`master`).
**Target:** `redmine/redmine`, the `6.0.0 → 6.1.2` window.

Companion to the [Redmine release-tag sweep](20260521-redmine-6.x-regression-sweep.md).
That sweep — like the [Mastodon one](20260521-mastodon-v4.5-regression-sweep.md)
— measured baseline **stability** over released tags. Released tags
are a post-spec-gate population, so a release-tag sweep *cannot*
measure Rigor's **bug-detection** power (the
[`rigor-regression-sweep`](../../.claude/skills/rigor-regression-sweep/SKILL.md)
SKILL § "Phase 1" records this). This probe samples finer — at
**bug-introducing commits** — to ask the detection question
directly.

## Method

For a known bug-fix commit, check out its **parent** (the buggy
state), run `rigor check`, and see whether Rigor flagged a
diagnostic at the bug. Detectable bug class = what Rigor's rules
target: `NoMethodError` / nil-receiver / missing-method / arity /
argument-type.

## The candidate pool is thin — itself a finding

The window has **555 commits**. Searching commit messages for the
`NoMethodError` bug class, restricted to commits touching
`app/**/*.rb` or `lib/**/*.rb`, yields **2**:

- `3712ecb01` — *Fix NoMethodError in IssuePriority#high and #low
  when no default or active priorities exist (#42066).*
- `41ed48fd7` — *NoMethodError when creating a user with an invalid
  email address and domain restrictions are enabled (#42584).*

Broadening with a diff pickaxe (commits whose `app`/`lib` `.rb` diff
added `&.` / `.nil?` / `return if` / `presence` and whose message
says "fix") surfaced four more — but all four are logic / rendering
bugs (broken footnote refs, SVG icon display), not nil-receiver type
bugs, plus one pure RuboCop cleanup. **Most of a release window's
fixes are logic / UI / feature work, structurally outside Rigor's
detection scope.** A larger detection study would need diff-shape
heuristics and a much bigger corpus; message-grep alone gives a
denominator of 2 here.

## Result — 0 of 2 caught

Both bugs are genuine nil-receiver `NoMethodError`s — squarely
Rigor's `call.possible-nil-receiver` rule's target class — and
**Rigor flagged neither** at the pre-fix commit (`rigor check
app lib`, 0 diagnostics in the affected file in both cases).

### C1 — `IssuePriority#high?` / `#low?`

```ruby
def high?
  position > self.class.default_or_middle.position   # NoMethodError
end
```

`default_or_middle` (a `def self.` class method) returns `nil` when
no default/active priority exists; `nil.position` raises. **Missed**
because Rigor types the `self.class.default_or_middle` call as
`Dynamic` — it does not infer the class method's return as
`IssuePriority | nil` — so `.position` on it has no nil arm to flag.

### C2 — `EmailAddress.domain_in?`

```ruby
def self.domain_in?(domain, domains)
  domain = domain.downcase   # NoMethodError when domain is nil
```

`domain` is a method parameter that a caller passes `nil`.
**Missed** because, per the [ADR-5 robustness
principle](../adr/5-robustness-principle.md), Rigor types parameters
**leniently** and does not assume a parameter is `nil` without
call-site flow proving it.

## Interpretation

The two misses are **not random** — each traces to a deliberate
Rigor design choice:

- C1 → unresolved method returns fall back to `Dynamic` (gradual
  typing's last resort).
- C2 → parameters are typed leniently (ADR-5 clause 2).

This is the **flip side of the false-positive discipline**
([`overview.md`](../type-specification/overview.md) § "False-positive
discipline"). The release-tag sweeps showed Rigor does not *frighten*
working code — surfaced stayed at/near zero across two projects'
release lines. This probe shows the cost of that same leniency:
**low recall on the latent-`NoMethodError` bug class.** The honest
combined picture — Rigor's delivered value is **precision** (few
false positives on working code), not **recall** (catching every
latent crash). It is a lint that respects working code, not an
exhaustive crash-finder.

## Caveats

- **Tiny sample (n=2).** The result is qualitative — "Rigor misses
  this bug shape, and here is the design reason" — not a calibrated
  detection rate.
- Message-grep misses bugs not labelled `NoMethodError`. A real
  detection-rate study needs diff-shape bug-class heuristics, a
  larger window, and a second project (Mastodon).

## Follow-up worth considering

- **C1 is potentially in reach.** A `def self.m` whose body returns
  a nilable value is statically analysable; inferring its return as
  `T | nil` (and threading that through `self.class.m`) would let
  the nil-receiver rule fire. Adjacent to the ADR-24 self-method
  resolution work. Queued as a precision-recall question, not
  scheduled.
- **C2 should stay missed.** Flagging a leniently-typed parameter as
  nil-risky would contradict ADR-5 and re-introduce exactly the
  defensive-code pressure the false-positive-discipline value
  forbids. Catching C2 safely would need call-site nil-flow into
  the parameter — higher FP risk; not worth trading the discipline
  for.

## Reproduction

`~/repo/ruby/rigor-survey/redmine/` (the cloned checkout) +
`~/repo/ruby/rigor-survey/_redmine-sweep/rigor-no-as.yml`. For each
commit `C`: `git checkout C~1`, then `rigor check --config
rigor-no-as.yml app lib`.
