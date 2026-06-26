# "From Psalm to Pzoom" — what it implies for Rigor's architecture

Status: external-reading reflection, authored 2026-06-26 against Rigor v0.2.x
(`[Unreleased]`). Records a reading of Matt Brown's article
[*From Psalm to Pzoom*](https://mattbrown.dev/articles/from-psalm-to-pzoom) and what its
central finding implies for Rigor's standing design decisions. Non-normative; the ADRs and
spec bind. This is a strategic-context note, not a change proposal.

Grounding (Rigor side): [ADR-17](../adr/17-monkey-patch-pre-evaluation.md) (`pre_eval:`),
[ADR-39](../adr/39-plugin-target-library-invocation.md) (plugins invoke their target
library's real methods), [ADR-45](../adr/45-unchanged-project-fast-path.md) (the Pundit
"plugins read project files during analysis" finding that killed the pre-analysis
fingerprint), [ADR-52](../adr/52-compiled-plugin-contribution-dispatch.md) (compiled
contribution dispatch), and the performance arc
[ADR-44](../adr/44-dispatch-allocation-churn.md) /
[ADR-45](../adr/45-unchanged-project-fast-path.md) /
[ADR-46](../adr/46-incremental-dependency-graph.md) /
[ADR-54](../adr/54-cache-slimming.md).

## The article in one paragraph

Matt Brown (author of Psalm, the PHP static analyzer) rewrote Psalm in Rust, producing
**Pzoom**. He did the ~100k-line port largely with LLMs — successive Claude models, finally
Fable 5 — using Psalm's PHP logic, his earlier Hack-targeted Rust port (Hakana), and Mago's
Rust PHP parser as raw material, and driving the work against Psalm's 5,000 + 1,500 tests as
an equivalence oracle. Cost: ~100 hours and ~$2,000 in tokens over six months. Result:
**10× faster, 99.9% of Psalm's tests passing**. Yet his own conclusion is that **most people
should not adopt it**. The reason — not the LLM story — is the substance of the article.

## The core finding, and why it lands on Rigor

The real claim is not "you can port with an LLM." It is a structural reason a faster
analyzer fails to get adopted:

> "since there's no scan-time execution of PHP scripts allowed there are limits to what it
> can do automatically."
>
> "That PHP 'magic' resolves at runtime (which a static pass can't observe)."

The chain:

1. Modern PHP frameworks lean on runtime metaprogramming (magic methods, DSLs).
2. A pure static pass can't observe that, so projects patch the gap with **plugins written
   in PHP**.
3. Psalm, being **written in PHP, can execute those plugins at scan time**.
4. Pzoom, a **compiled Rust binary, cannot execute PHP at scan time** → the plugin assets
   don't run → being 10× faster doesn't earn the switch.

This is the exact fork Rigor faced, and Rigor deliberately chose the **same side as Psalm**:

| Tool  | Analyzer language | Scan-time execution of target language | Plugins            |
|-------|-------------------|----------------------------------------|--------------------|
| Psalm | PHP               | yes                                    | PHP, runnable      |
| Pzoom | Rust              | **no**                                 | can't run          |
| Rigor | **Ruby**          | **yes**                                | **Ruby, runnable** |

Rigor's design depends on precisely the capability the article says compiled tools lack:

- **ADR-17** — project-side monkey-patch pre-evaluation (`pre_eval:`).
- **ADR-39** — plugins invoke the *real* target library's safe methods (running the actual
  `ActiveSupport::Inflector` rather than re-modeling it).
- **ADR-45** — the soundness finding that the Pundit plugin *reads project files during
  analysis*. That is "scan-time execution" in the literal sense, and it is what made a
  pre-analysis fingerprint unsound. Pzoom's whole limitation is the absence of this.
- **ADR-52** — runtime plugin-contribution dispatch, compiled once per run but still calling
  plugin code on candidate hits.

**Takeaway 1.** Pzoom is, in effect, the controlled experiment for "what would Rigor lose if
rewritten in a compiled language." It would lose scan-time execution — i.e. the plugin
ecosystem. The article is external evidence that implementing the analyzer *in the host
language* is the correct strategy for a plugin-heavy dynamic ecosystem, and it is the
standing reply to any future "rewrite Rigor in Rust/Crystal for speed" proposal.

## "Faster but unadopted" vs. Rigor's performance philosophy

> "Unless developers really need the speedup _and_ they're comfortable maintaining it
> themselves, they shouldn't take it on as a dependency."

The lesson is that maintenance burden and practical utility outrank a benchmark number. This
reframes Rigor's performance ADRs:

- Rigor gets its speed from **in-implementation optimization** — allocation hygiene
  (ADR-44), the record-and-validate cache (ADR-45), cache slimming (ADR-54), and the
  in-flight incremental dependency graph (ADR-46) — **without discarding plugin execution**.
  Pzoom bought 10× by throwing execution away; Rigor improves incrementally while keeping it.
- The article's warning is "a one-shot 10× from a language port is a trap." Rigor avoids the
  trap structurally by choosing **incremental optimization over a port**. ADR-15 (Ractor
  parallelism) and ADR-46 (incremental) are the right kind of "next big speed source":
  inside the implementation, not across a language boundary.

**Takeaway 2.** Rigor's "shave time within one implementation while honoring FP discipline"
philosophy is the answer Pzoom's outcome argues for. The value ordering — "the program
works" and "plugins run" over a benchmark — is the same ordering as Rigor's false-positive
discipline.

## The LLM-port methodology, mapped onto Rigor's existing discipline

Two reusable points from Brown's process:

- **Tests as an equivalence oracle, not a target.** Early attempts "overfitted to test
  passing." The fix is to treat the suite as *proof of equivalence*, not a goal to satisfy.
  Rigor already does a stronger version of this: its refactors gate on **byte-identical
  diagnostics over real corpora** (ADR-52 / ADR-53 / ADR-54 all require identical output on
  Mastodon / GitLab / haml / kramdown). That is "tests as equivalence oracle" hardened into
  "real-corpus output identity."
- **"90% from the LLM, the last 10% needs domain expertise to ship."**

  > "deep expertise is no longer necessary to get 90% of the way there — but it is still
  > necessary to ship."

  This is the same shape as Rigor's recurring **adjudicate-don't-assume** protocol
  (ADR-57 / ADR-62): never trust a firing or a survivor mechanically; a human adjudicates it.
  Rigor's workflow of adjudicating LLM-proposed changes against corpora and hand-probed
  shapes is the institutionalized form of "the expertise needed to ship the last 10%."

**Takeaway 3.** Rigor's verification discipline (byte-identical corpus gate + adjudication
protocol) already encodes the safety valve Brown reached empirically. The corollary is that
**Rigor is well-positioned to run LLM-driven internal refactors safely** — e.g. ADR-53
Track B's shadow-harness-gated walk consolidation is an ideal place to apply the Pzoom method
(LLM + equivalence oracle) inside Rigor, with pass/fail always anchored to corpus output
identity to avoid the overfitting failure mode.

## Concrete carries for Rigor

1. **Document the architectural justification.** "Why Rigor stays Ruby-implemented (= it can
   execute the target language at scan time)" is currently spread across ADR-17/39/45/52.
   With Pzoom as a public counter-example, this deserves a one-line consolidation as a design
   boundary (ADR-0 vicinity): "a compiled port loses scan-time execution = the plugin
   ecosystem (Pzoom, 2026)." It becomes the canned answer to "why not rewrite in Rust?"
2. **How to talk about performance.** When advertising a speedup, phrase it as "N× *while
   keeping plugin execution*," not "N×" alone — that is the differentiation the article's
   lesson points to.
3. **Where to apply LLM-driven refactor.** Areas that already have a byte-identical gate
   (walk consolidation, cache layers, catalog imports) can take the Pzoom method safely.
   Keep pass/fail on corpus output equivalence to avoid test overfitting.
4. **Self-check on adoption barriers.** Speed does not guarantee adoption; maintainability
   and utility win. Rigor's adoption drivers are FP discipline + the plugin ecosystem + DX
   (ADR-73 skills, ADR-74 offline docs). Investment should stay in that order.

## One-line summary

Pzoom empirically demonstrates that porting a dynamic-language analyzer to a compiled
language buys speed at the cost of scan-time execution — i.e. the plugin ecosystem — and is
therefore not adopted. That externally validates Rigor's choice to stay Ruby-implemented with
a strong plugin-execution model and to pursue speed through incremental in-implementation
optimization. Brown's "tests as equivalence oracle + the last 10% is expert adjudication"
porting methodology coincides with discipline Rigor already practices as byte-identical
corpus gates and the adjudicate-don't-assume protocol.
