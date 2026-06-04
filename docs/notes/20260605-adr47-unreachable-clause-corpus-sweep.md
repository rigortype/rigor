# ADR-47 `flow.unreachable-clause` — corpus FP sweep (WD4)

**Status:** research note, no design commitments. The ADR-47 WD4 false-positive gate run.
**Date:** 2026-06-05.
**Rigor version:** working tree (master @ `cf8ee0fe`, ADR-47 WD1 + WD2 + WD3a landed).

**Why:** ADR-47 ships `flow.unreachable-clause` at `:info` in the default
(balanced) profile and `:warning` only under `strict`, "pending the
regression-corpus FP gate before any balanced→`:warning` promotion"
(WD4). This note runs that gate: sweep real OSS corpora, triage every
firing, and decide whether to promote.

**Method.** For each target, from `cwd=<target>` with
`BUNDLE_GEMFILE=<rigor>/Gemfile` (per
[`reference_survey_external_projects`]), ran
`bundle exec <rigor>/exe/rigor check <paths> --no-cache` and grepped the
output for `flow.unreachable-clause`. Targets live under
`~/repo/ruby/rigor-survey/` (plus `~/repo/ruby/gitlab-foss`).

## Results

| Corpus | Scope | `unreachable-clause` firings |
| --- | --- | --- |
| Mastodon | `app lib` | 0 |
| Redmine | `app lib` | 0 |
| parser | `lib` | 0 |
| rubocop-ast | `lib` | 0 |
| kramdown | `lib` | 0 |
| mail | `lib` | 0 |
| liquid | `lib` | 0 |
| haml | `lib` | 0 |
| hamlit | `lib` | 0 |
| herb | `lib` | 0 |
| slim | `lib` | 0 |
| oj | `lib` | 0 |
| ox | `lib` | 0 |
| protobuf | `lib` | 0 |
| textbringer | `lib` | 0 |
| rgl | `lib` | 0 |

**16 corpora, zero firings.** No false positives — and no true positives.

**GitLab FOSS: aborted, not counted.** `app/models app/services
app/controllers lib --no-cache` was killed after >52 min CPU at 100% (the
`lib` tree is enormous and `--no-cache` re-analyses everything). It is not
a reachability-rule problem — the same scope is slow for any rule — so it
is excluded rather than reported as a zero. A bounded GitLab scope can be
swept later if a firing is ever wanted from it.

## Why zero is the expected result

The rule's envelope is deliberately narrow (WD1): it fires only on a
`case <local>` whose subject is a **narrowing local** of a **concrete**
(non-`Dynamic`, non-`Bot`) type, with **class/module-constant**
`when`/`in` conditions, outside loops/blocks. Real-world `case` subjects
are overwhelmingly *method-call results* or *parameters* (which infer to
`Dynamic`, so the gradual guarantee suppresses the rule) or *value /
symbol* matches (`when :active`, `when 200`), which are not class
patterns. The shape the rule catches — a local of a statically-known
concrete class matched against a disjoint or already-covered class — is
one programmers rarely write, precisely because it is obviously
redundant. The synthetic spec cases (`x = 1; case x; when String`) prove
the rule fires; real code simply does not contain the bug at the only
shape the conservative envelope admits.

## Decision

**Keep balanced at `:info`; do not promote to `:warning`.**

The ADR's promotion criterion — "triage every hit to zero net false
positives" — is *vacuously* met (zero hits ⇒ zero false positives), but a
vacuous pass is **absence of evidence, not evidence of safety**: with no
real-world firing to inspect, there is no positive signal that a louder
default is warranted, and the false-positive discipline ("never frighten
working code") argues against promoting a rule whose wild behaviour has
never been observed. `:info` already surfaces the diagnostic for anyone
scanning; `strict` keeps `:warning` for opt-in users. A future promotion
should wait until a real corpus firing exists to triage.

This also lowers the priority of **WD3b** (deconstructing / value /
variable-catch-all pattern exhaustiveness): if the broad WD1/WD2/WD3a
surface fires zero times across 16 corpora, the marginal real-world yield
of the much larger WD3b is unlikely to repay its complexity and FP risk
soon. It stays deferred behind concrete demand.
