# ADR-95 — Homebrew distribution: deferred behind the single binary

Status: **Proposed (deferred, trigger-gated), 2026-07-17.** Nothing is implemented and
nothing is planned. Rigor does not ship a Homebrew formula — not in homebrew-core (it
would not clear notability today) and not as a third-party tap (the tap is cheap to
write and expensive to keep alive, for a reason that disappears on its own if
[ADR-27](27-tool-distribution-model.md) WD5 lands). This ADR exists because the question
was live and the corpus had **no answer at all**: ADR-27 enumerated the distribution
channels in 2026-05 and never mentioned Homebrew, so each time it is asked the research
is redone. Recorded here with its re-evaluation triggers so the next asking is cheap.

Grounding:
[`docs/notes/20260717-install-channel-evaluation.md`](../notes/20260717-install-channel-evaluation.md)
§ 5 (the Homebrew findings; the note also carries the mise / Bundler evaluation that ran
alongside).

## Context

ADR-27 settled that Rigor installs outside the analyzed project's bundle and ranked its
channels: a version manager first, a CI template, a container, a future single binary,
and a retained `gem install`. Homebrew is absent from that list — not rejected, simply
never considered. It is nonetheless the first thing a macOS user reaches for, and
"should we offer a tap?" is a reasonable question with a non-obvious answer.

Two facts frame it:

- **Rigor pins `required_ruby_version = ">= 4.0.0", "< 4.1"`** — narrow, and deliberately
  so (ADR-27 WD7 rejected lowering the floor).
- **Homebrew's `ruby` formula tracks latest.** The two are on a collision course by
  construction.

## Decision

**Criterion: a distribution channel is worth owning only if its recurring cost is bounded
by our own release cadence.** A channel whose upkeep is driven by a third party's
unrelated release schedule is not a channel, it is a subscription to someone else's
breakage — however cheap it is to create.

A brew formula depending on `ruby` fails this. Authoring is trivial (`ruby-lsp`'s formula
is the pattern: `depends_on "ruby"`, `GEM_HOME=libexec`, `bin.env_script_all_files`) and
per-release bumps automate with `brew bump-formula-pr`. The cost is elsewhere: every
Homebrew `ruby` bump can strand a formula built against the previous one — Homebrew's own
Cookbook requires `revision` bumps of dependents when a dependency moves incompatibly —
and against a `< 4.1` cap the collision is scheduled, not hypothetical. This is exactly
the CocoaPods "installed with a different Ruby than the one invoking it" failure class,
which we would be importing on purpose. Our existing channels already isolate the
interpreter: mise's `gem:` backend gives each tool a private gem directory and an
executable pinned to its install-time Ruby, and no user's `brew upgrade` can reach it.

So: **no formula while it must depend on brew's `ruby`.** The condition is the whole
decision — ADR-27 WD5's single binary removes `depends_on "ruby"` and, with it, the only
reason to say no. Homebrew is not a competing distribution strategy to evaluate against
the single binary; it is a *consequence* of it, and sequencing the two the other way
round buys years of formula maintenance to deliver what WD5 delivers once.

Homebrew-core is separately closed for now: its notability bar is ≥30 forks / ≥30
watchers / ≥75 stars, **tripled for self-submission** (≥90/≥90/≥225), which rigortype
does not clear. The ecosystem agrees with the shape of that judgement — **no Ruby
static-analysis tool is in homebrew-core at all** (no `rubocop`, `steep`, `typeprof`,
`sorbet`, `brakeman`); what is there is `fastlane`, `cocoapods`, `ruby-lsp`. A tap is
therefore the only near-term brew option, and it is the one this ADR declines.

## Re-evaluation triggers

Any one of these re-opens it:

1. **ADR-27 WD5 ships a single binary** ([tebako](https://github.com/tamatebako/tebako)
   is the only maintained 2026 packager — ruby-packer is abandoned, traveling-ruby
   dormant). A binary-bottle formula has no `ruby` dependency and no churn, and this ADR
   flips to a yes. **This is the expected path.**
2. **The `< 4.1` cap widens far enough to track brew's `ruby`.** Unlikely — ADR-27 WD7
   and ADR-79 both keep Rigor pinned to the latest toolchain on purpose.
3. **Demonstrated demand that the existing channels genuinely cannot serve** — not "brew
   would be nicer", but a user for whom mise / `gem install` / container / Nix all fail.
4. **rigortype clears homebrew-core's self-submission notability** (≥90/≥90/≥225), which
   changes the question from "maintain a tap" to "hand it to core".

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| Ship a third-party tap now, `depends_on "ruby"` | Fails the criterion — upkeep is driven by Homebrew's `ruby` cadence, not ours, against a `< 4.1` cap that guarantees collision |
| Vendor Ruby into the formula (`resource`-install a 4.0 interpreter) | Re-implements the single binary in Homebrew's DSL, for one platform, without WD5's benefits elsewhere |
| Submit to homebrew-core now | Does not clear self-submission notability; no Ruby analysis tool is in core |
| Generate a formula with `brew-gem` | Same `ruby` coupling with less control; and a generated stub is not a channel we could support |
| Leave it unrecorded | The status quo, and the reason this ADR exists — an unrecorded non-decision is re-researched every time it is raised |

## Consequences

- **Positive.** macOS users are routed to mise, which the same evaluation measured as
  the channel that *cannot* mix Ruby versions. No maintenance is taken on. The
  single-binary work gains a concrete second payoff, which strengthens WD5's case.
- **Negative.** `brew install rigortype` does not work, and it is what a macOS user tries
  first. We absorb that discovery cost until WD5 lands.
- **Carry-over.** If WD5 stays unscheduled indefinitely and trigger 3 fires anyway, the
  honest options narrow to a tap with a documented "may break on `brew upgrade ruby`"
  caveat — which is worth naming now so it is a choice later, not a surprise.

## Relationship to other ADRs

- [ADR-27](27-tool-distribution-model.md) — the parent. This fills a gap in its channel
  enumeration; its WD5 is this ADR's trigger 1 and its WD7 is why trigger 2 is unlikely.
- [ADR-79](79-rbs-version-range-over-pinned-determinism.md) — the fidelity stance that
  keeps Rigor tracking the latest toolchain, i.e. the same force behind the narrow cap.
- [ADR-31](31-contribution-and-supply-chain-policy.md) — a tap is a supply-chain surface;
  any future formula is in scope for its policy.
