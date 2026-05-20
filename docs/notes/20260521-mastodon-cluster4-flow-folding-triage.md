# Mastodon survey — Cluster 4 (flow-folding warnings) triage

**Date:** 2026-05-21. Closes the last untriaged cluster of the
[`20260519-oss-library-survey.md`](20260519-oss-library-survey.md)
Mastodon false-positive pass.

## Scope

`rigor check app lib` on the Mastodon checkout (≈3,180 Ruby files,
`--workers=8`) surfaces **8** flow-folding warnings —
`condition is always truthy` / `condition is always falsey`. Every
other survey cluster (1, 1b, 2, 3) was resolved earlier in the
`[Unreleased]` cycle; this note triages the remaining 8.

## Verdict

**All 8 are false positives. None is a real bug.** They split into
two engine gaps, both pre-existing and both about *mutation not
reflected in narrowing*.

### G1 — loop / retry body mutation not reflected (3 warnings)

The condition reads a variable whose only mutation happens inside a
loop / `retry` body the narrower does not fold back into the
pre-condition type.

| Site | Condition | Why it is an FP |
| --- | --- | --- |
| `lib/mastodon/snowflake.rb:19` | `raise if tries > 100` | `tries = 0`, then `tries += 1` on each `retry`; the `retry` edge is not folded, so `tries` stays `Constant[0]`. |
| `app/lib/link_details_extractor.rb:294` | `html = @html unless encoding` | `encoding = nil`, then `encoding = enc` inside a `.each` loop; the loop-body write is not reflected, so `encoding` stays `nil`. |
| `app/lib/activitypub/linked_data_signature.rb:53` | `... if context_with_security.size == 1` | the array is built with `<<` / `uniq!`; `size` is folded against the pre-mutation shape. |

This is exactly **Open Engineering Item 0** (`docs/CURRENT_WORK.md`)
— the same shape as the 3 residual `rigor check lib` warnings
(`hkt_body_parser.rb`, `hkt_registry.rb`). The fix lives in the
mutation-effect model under
`docs/type-specification/control-flow-analysis.md` § "mutation
effects"; it stays a queued medium-sized engine change. Mastodon
adds 3 more data points to the demand signal.

### G2 — ivar type taken from literal writes, not invalidated by mutation (5 warnings)

The condition reads an instance variable whose type the engine took
from a literal write (`@x = false` / `@x = []`) — or from the only
write it could see — and which is then mutated by a path the flow
does not model: an intervening method call, an in-place `<<`, or the
read-before-write `nil` state.

| Site | Condition | Why it is an FP |
| --- | --- | --- |
| `app/workers/activitypub/delivery_worker.rb:39` | `if @performed` | `@performed = false`; `perform_request` sets `@performed = true`, but the intervening call does not invalidate the `Constant[false]` binding. |
| `app/workers/activitypub/delivery_worker.rb:41` | `elsif !@unsalvageable` | `@unsalvageable` is only written (`= true`) inside `perform_request`; the call's effect on the ivar is not modelled. |
| `app/services/fetch_oembed_service.rb:69` | `return unless URL_REGEX.match?(@endpoint_url)` | `@endpoint_url` is set in a sibling method; in `cache_endpoint!` it folds to `nil`, so `Regexp#match?(nil)` constant-folds to `false`. |
| `app/lib/activitypub/activity/create.rb:185` | `return if @tags.empty? \|\| ...` | `@tags = []`; later filled with `@tags << hashtag`. `<<` is a call, not an `InstanceVariableWriteNode`, so the accumulator keeps `@tags` as the empty literal. |
| `lib/chewy/strategy/bypass_with_warning.rb:7` | `... unless @warning_issued` | `@warning_issued` is read before its only write (`= true`); the ivar accumulator unions writes only, missing the read-before-write `nil`, so it folds to `Constant[true]`. |

The unifying cause: **an instance variable's type is derived from
its literal writes and is not widened when control passes through a
mutation the flow analysis does not track** — an intervening method
call (which may touch any ivar), an in-place `<<`, or the
uninitialised-`nil` state of a read-before-write ivar. A principled
fix belongs in the same `control-flow-analysis.md` § "mutation
effects" surface as G1: after an unmodelled mutation point an ivar
binding should degrade toward the cross-method accumulator type
(plus `nil` when the ivar may be unwritten).

## Decision

- **No real bugs**, so no diagnostic-suppression or code change is
  warranted on the Mastodon side.
- **G1 + G2 stay queued** as engine improvements under the
  mutation-effect model. They are not scheduled by this note: each
  is a medium-sized change with real precision-regression risk
  (widening ivar / loop-variable types can lose legitimate
  narrowing elsewhere), and the warning is `:warning`, not `:error`.
- The Mastodon `[Unreleased]` survey cycle's diagnostic clusters are
  now **all triaged** (1, 1b, 2, 3 fixed; 4 = FP, queued).
