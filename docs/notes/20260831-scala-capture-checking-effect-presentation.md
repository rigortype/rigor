# Scala 3 Capture Checking as a presentation model for Rigor's effect labels

Status: **research note, no design commitments.** An investigation of whether Rigor's implemented
effect system (ADR-103) could be *presented to users* the way Scala 3's experimental Capture
Checking presents capabilities — types decorated with capture-set-like suffixes such as
`String^{db, net}` — and what the conceptual differences between the two systems allow, forbid, or
make dishonest. It recommends a direction; it proposes no implementation.

**Date:** 2026-08-31.
**Rigor version:** master @ `bf7b6d56` (v0.3.4 line). CLI output below was produced by this tree,
inside the Nix Flake, against a two-class scratch project.
**Trigger:** [副作用の影響範囲を型で示したい — Scala 3 が模索する「Capture Checking」](https://www.m3tech.blog/entry/2026/08/31/200000)
(m3tech blog, published today), which presents Capture Checking as a lightweight, direct-style
alternative to monadic effect systems.
**Primary sources:** the [Scala 3 nightly reference — Capture Checking](https://nightly.scala-lang.org/docs/reference/experimental/capture-checking/index.html)
(the source of record for CC behaviour; the section pages `overview.html`, `basics.html`,
`polymorphism.html`, `how-to-use.html` are cited individually below);
[tanishiking, *Introduction to Scala 3's Capture Checking and Separation Checking*](https://tanishiking.github.io/posts/introduction-to-scala-3s-capture-checking-and-separation-checking/)
(secondary, covers Separation Checking); Boruch-Gruszecki, Odersky, Lee, Lhoták, Brachthäuser,
[*Capturing Types*](https://dl.acm.org/doi/10.1145/3618003), TOPLAS 45(4), 2023 (the CC<:□ calculus
behind the implementation). Rigor-side sources are the in-repo spec and corpus notes, cited inline.

Prior art check: `rg -il 'capture checking|capture set|CapSet'` over `docs/` finds nothing — the
corpus has not evaluated Capture Checking before. The one hit for "capabilit" outside the effect
corpus is Rigor's own **capability-role** machinery, which turns out to be a different concept
entirely (§ 3.4).

---

## 1. Context and question

Rigor's effect system reports what a method *does* (`io.db.read`, `nondet.time`) as a per-method
summary, surfaced through the `rigor effects` report and a committed snapshot. Capture Checking
reports what a value *can reach* as a suffix on its type (`Logger^{fs}`). The two look superficially
interchangeable — both print small brace-sets of effect-ish names next to program entities — and the
m3tech post makes CC's presentation look attractive: zero annotation burden on correct code, errors
only where a resource escapes, dependencies visible in inferred types.

The question this note answers: **could Rigor honestly show its effect labels in CC's clothing** —
e.g. `String^{db, net}` in `rigor type-of` output, sig-gen output, or diagnostics — **and what would
be lost, gained, or over-promised in the translation?**

## 2. Capture Checking in Scala 3

### 2.1 Semantics

Capture Checking modifies Scala's type system to track **references to capabilities in values**
([overview](https://nightly.scala-lang.org/docs/reference/experimental/capture-checking/overview.html)).
The moving parts, per the reference docs:

- **Capabilities are term-level values.** "An *object capability* is syntactically a method- or
  class-parameter, a local variable, or the `this` of an enclosing class" whose type carries a
  non-empty capture set ([basics](https://nightly.scala-lang.org/docs/reference/experimental/capture-checking/basics.html)).
  A capability is created from other capabilities — `val lg: Logger^{out} = new Logger(out)` — and
  the chain bottoms out at the **root capability**, spelled `any` in current nightlies (`T^` is
  shorthand for `T^{any}`; older docs, the paper, and both blog posts spell it `cap` — the rename is
  recent, one of several churn events the m3tech post flags).
- **Capturing types.** `T^{c₁, …, cᵢ}` pairs a shape type `T` with the set of capabilities a value
  may retain. `T^{}` is pure. Function arrows encode the same thing: `A => B` is impure
  (`A ->{any} B`), `A -> B` is pure, `A ->{c, d} B` captures exactly `c` and `d`.
- **Subcapturing.** A capture set is admissible where a wider one is expected along a derivation
  order: `{l} <: {fs} <: {any}` — a capability derived from `fs` is accounted for by `fs`.
- **Boxed types.** Capturing types under generic type constructors are "boxed", and box/unbox
  adaptation is inferred; this is what makes polymorphism sound ("capture tunneling") and is largely
  invisible to users (*Capturing Types* § boxing; [polymorphism](https://nightly.scala-lang.org/docs/reference/experimental/capture-checking/polymorphism.html)).
- **Escape checking.** A locally scoped capability may not appear in a capture set of an outer
  scope. The documented error is instructive for § 5:

  ```
  Found:    (f: java.io.FileOutputStream^'s1) ->'s2 () ->{f} Unit
  Required: java.io.FileOutputStream^ => () ->'s3 Unit

  Note that capability f cannot be included in outer capture set 's3.
  ```

- **Separation Checking** (newer, layered on CC) splits capabilities into exclusive and shared,
  gives mutable classes `update` methods and read-only views (`Ref` expands to `Ref^{any.rd}`,
  `Ref^` to full access), checks disjointness of the capture sets of parallel arguments, and adds
  `consume` parameters / hiding for move-like semantics (tanishiking post; reference
  `separation-checking.html`).

### 2.2 Effect polymorphism falls out of term passing

Because a capability is an ordinary value, an ordinary generic signature is already
effect-polymorphic: `def map[B](f: A => B)` "works for pure functions AND capturing functions"
with no effect variables anywhere — instantiating `B` and passing `f` carries the capture
information through ([polymorphism](https://nightly.scala-lang.org/docs/reference/experimental/capture-checking/polymorphism.html)).
Explicit capture-set parameters (`class Source[X^]`, bounded capture-set variables over the sealed
`CapSet` marker) exist for the cases implicit polymorphism cannot express — lazy collections,
listener registries — and the docs say to prefer the implicit route.

### 2.3 The user-facing surface

- **Opt-in per file**: `import language.experimental.captureChecking` on a Scala 3 nightly
  (Separation Checking via its own import, which implies CC)
  ([how-to-use](https://nightly.scala-lang.org/docs/reference/experimental/capture-checking/how-to-use.html)).
- **Users annotate boundaries, the compiler infers the middle**: parameter types get capability
  markers (`FileOutputStream^`); capture sets of closures and results are inferred and can be
  displayed with `-Vprint:cc`. Scaladoc renders capturing types in the nightly stdlib API docs.
- **Error style**: Found/Required pairs over capture sets, with a note naming the capability that
  cannot flow — the m3tech post highlights that messages propose concrete fixes, and summarizes the
  philosophy as 「正しいコードには何も要求せず、間違ったコードだけを弾く」 ("demands nothing from
  correct code; rejects only incorrect code").
- **Soundness posture**: CC is a *sound checker* over the code it checks — the capture set is a
  complete account of what a value can retain, enforced by subcapturing and escape checking. That
  completeness claim is precisely what the suffix syntax *visually asserts*, and it is load-bearing
  for § 4.3.
- **Stability**: experimental, and actively churning — the m3tech post (against Scala 3.8.3) notes
  the `cap` → `any` rename, a reorganized capability hierarchy, and the deletion of reach
  capabilities within months. Production use is not recommended by anyone involved.

## 3. Rigor's implemented effect system

### 3.1 What it is

Normative in [`docs/type-specification/effect-labels.md`](../type-specification/effect-labels.md),
produced per [`docs/internal-spec/effect-summaries.md`](../internal-spec/effect-summaries.md),
decided in [ADR-103](../adr/103-effect-labels.md). The shape:

- **Labels are dot-paths in a closed registry** (`io.db.read`, `nondet.time`, `mutate.self`),
  checked by segment-aware prefix subsumption (ADR-103 WD1-WD2). They classify *what a call does* —
  they are not names of program variables.
- **The unit is the method.** Summaries are keyed `Class#method` / `Class.method`
  (`effect-summaries.md:39-52`); reopenings union. Effects originate in a hand-audited catalogue and
  a small set of constructs (backticks, gvar/cvar/ivar writes, `define_method`, …)
  (`effect-summaries.md:69-81`); catalogue rows are **upper bounds** — `IO#write` is `io`, not
  `io.fs.write`, because the channel could be a socket (`effect-summaries.md:141`).
- **Two lanes and a bit.** A summary carries a *proven* lane (the analyzer read the code), a
  *declared* (`≤`) lane (a trusted-but-unread claim: plugin rows, `effects.attribution:`, envelopes
  at call sites), and an exhaustiveness bit tainted by a closed enum of causes (`dynamic-receiver`,
  `opaque-callable`, `unresolved-super`, …) (`effect-summaries.md:117-129`). "Taint never produces a
  finding. A non-exhaustive summary reads 'these effects, and possibly more'"
  (`effect-summaries.md:129`).
- **Propagation** is a monotone fixpoint over project call edges, per lane, with a closed-world
  override join (`effect-summaries.md:241-263`). The declared lane is a lane *of the fixpoint*,
  never joined into proven (`effect-summaries.md:251`).
- **Envelopes** (`%a{pure}`, `%a{rigor:v1:effect …}`, `.rigor.yml` convention stanzas) are declared
  upper bounds checked against the **proven lane only** (`effect.envelope-exceeded`,
  `effect.liskov-widened`, both opt-in). The **snapshot** (`.rigor-effects.yml`, `rigor effects
  update|check|diff|explain`) is the primary validation: a committed record whose reviewed diff and
  CI gate are the enforcement surface (ADR-103 WD7).

### 3.2 Where it surfaces today

The report (`docs/manual/19-effect-labels.md` § "Reading a row") prints, per method:

```
IssuesController#create: [global.read, io, mutate.instance, …] ≤ [email.send, job.enqueue, …] …? (21 reasons, --why)
```

— proven list, `≤` declared list, and ` …?` for "possibly more". Reproduced on this tree against a
two-class scratch project (`rigor effects --full`, then `--why`):

```
Greeter#greet: [nondet.time]
Greeter#initialize: [mutate.self]
Mailer#deliver: [global.read, io.fs.write] …? (1 reason, --why)
    dynamic-receiver
──
3 of 3 units printed
3 carry a proven label · 0 carry a declared (≤) one · 2 are exhaustive
```

(the `dynamic-receiver` is `$stdout.puts` — the global's type is untracked, so even a two-line
method honestly hedges). What does **not** surface effects today: `rigor type-of` prints node,
inferred type, and RBS erasure only; `sig-gen` emits no `%a{…}` (ADR-103 WD9 plans `%a{pure}` /
envelope emission "from exhaustive, undischarged summaries only" — a consumer, not yet landed);
LSP hover is deliberately effect-free until a v0.4.x slice (WD16 § 4). `rigor effects explain`
prints the shortest edge path behind a reach change.

### 3.3 The settled adjudications the presentation must respect

- **The declared lane is never judged** (WD17, [#454](https://github.com/rigortype/rigor/issues/454)):
  on redmine and mastodon, `io.db.read`/`io.db.write` appear in the proven lane **zero** times
  against thousands of declared occurrences — every Rails-meaningful label lives in the lane no
  diagnostic may read, and the enforcement surface for it is `rigor effects check` (the `≤+` drift
  marker), not an envelope.
- **A negative reading is never licensed.** `%a{pure}`'s reading is *exhaustive* proven ⊆
  `{mutate.local}`; on Redmine 262 of 4,683 units are exhaustive and ~90 % of printed rows end in
  ` …?` — "the normal, healthy state of a Rails application" (`docs/manual/19-effect-labels.md`
  § "The report").
- **Envelope-tuned, mistuned for discards.** `effect.discarded-pure-result` fired 14 times on the
  corpus, all false positives, with "no instance anywhere in the corpus of the footgun the rule is
  named for" ([`20260819-discarded-pure-result-corpus-gate.md`](20260819-discarded-pure-result-corpus-gate.md)).
- **Usefulness is bounded by receiver typing**, not by the effect machinery: an ivar assigned in a
  `before_action` in a superclass leaves `@group.save` contributing nothing
  ([#455](https://github.com/rigortype/rigor/issues/455) — 0 of redmine's 27 `#update` actions
  record a db write).
- Default-on lands at v0.4.0 behind the WD15/WD16 preconditions
  ([#409](https://github.com/rigortype/rigor/issues/409)); the ten-user-story adjudication is
  [`20260823-effect-user-stories-corpus.md`](20260823-effect-user-stories-corpus.md).

### 3.4 Rigor already has "capabilities", and they are something else

Rigor's **capability-role inference** ([`docs/type-specification/rigor-extensions.md:17`](../type-specification/rigor-extensions.md),
[`structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md)
§ "Capability roles") is the *minimum structural interface a method body requires of a parameter or
receiver* — "readable and rewindable stream behavior" as `_Reader`-shaped roles from a curated
catalog, instead of the whole nominal `IO`. It is a **shape** notion: which methods must exist on
what was passed in. Scala's object-capability discipline is an **authority** notion: which effects
the holder of this value may perform. The two touch — both reason about what a body demands of its
parameters, and a genuine capability reading of Ruby would have to start from exactly this
passed-object analysis — but a capability role says nothing about ambient authority (`File.write`
needs no parameter at all), and the body-side *requirement inference* is itself still deferred
([`control-flow-analysis.md:221`](../type-specification/control-flow-analysis.md)). Any CC-flavoured
surface would also collide with this established vocabulary: "capability" is already taken in this
repository, and it does not mean what CC means.

## 4. Conceptual mapping and mismatches

| | Scala 3 CC | Rigor effect labels |
| --- | --- | --- |
| Attaches to | types of **values** | **method** summaries |
| Set members | program **variables** in scope (capabilities) | closed **vocabulary** of classifications |
| Direction | forward: what using this value *may reach* | backward: what this code *was proven to do* |
| Completeness | asserted (sound checker; escape checking) | explicitly hedged (` …?`, taint causes) |
| Polymorphism | free, via term-passing + boxing | avoided: containment for block literals, taint for opaque callables |
| Purity claim | `T^{}` is checkable and common | licensed only by exhaustive proven ⊆ `{mutate.local}` — rare |
| Bound vs fact | one lane (checked types) | two lanes (proven / declared) + envelope as a third, author-side bound |

Four mismatches carry the argument:

**4.1 Capability vs classification.** `Logger^{fs}`'s brace-set names *values* (`fs` is a variable);
subcapturing follows the derivation of values from values. `[io.fs.write]` names a *category* in a
registry; subsumption follows the label tree. A hypothetical `String^{db, net}` would be a
capture set only typographically — there is no `db` value in the program for it to name. Worse, the
two readings point opposite ways: in CC the suffix says what the *holder may still do* with the
value; the only meaning Rigor could give it is what *producing* the value already did — an effect
history, i.e. a value-provenance analysis Rigor does not perform and nothing in ADR-103 collects.
Effects attach at method granularity by construction (`effect-summaries.md:39`); no per-value fact
exists to decorate.

**4.2 Higher-order code.** Scala's `map` is effect-polymorphic because `f` is a term whose capture
set travels with it. Rigor deliberately has no effect variables: "Block literals **always** join the
enclosing method's summary (containment) … effect polymorphism therefore needs no effect variables"
(ADR-103 WD4, `docs/adr/103-effect-labels.md:106-107`). For a block *literal* the two give the same
observable answer at the call site's enclosing method. But a capture-set presentation would
over-promise exactly where they diverge: a stored `Proc` invoked later (`opaque-callable` taint —
`effect-summaries.md:121`), a method whose effects genuinely *depend on* its block argument
(`Array#each` cannot be rendered `->{f}`-polymorphic; its catalogue row is a constant), and a
callable threaded through several frames. CC's syntax advertises parametric propagation; Rigor's
machinery answers with a hedge, and the syntax must not promise what the hedge withholds.

**4.3 Soundness asymmetry.** CC's suffix is trustworthy *because* the checker is sound over checked
code: `() ->{c1} Unit` means c2 provably cannot flow in. Rigor's standing policy is the opposite
trade — "false positives outrank worst-case static reading" (AGENTS.md; ADR-5), the proven lane is
as-strict-as-proven, and the corpus verdict is that inferred purity is unknowable in Ruby (ADR-103
§ Context). A bare `String^{db, net}` borrowed from CC visually asserts "at most these", which on
this analyzer is a claim only the rare exhaustive row can make; the honest rendering of the common
row would be `^{db, net, …?}` — at which point the presentation has stopped being CC's and become
Rigor's current one with different brackets. The asymmetry is not stylistic: WD17 shows the labels a
Rails policy cares about sit in the declared lane, so a CC-style suffix on Rails code would either
omit `io.db.*` entirely (misleadingly clean) or print claims in a syntax that connotes proof.

**4.4 Ambient authority.** CC works because Scala threading a `FileSystem` through parameters is
plausible style, and the checker makes the threading mandatory for tracked resources. Idiomatic
Ruby's authority is ambient: `File.write`, `Time.now`, `Net::HTTP.get`, globals, constants,
`Kernel#` methods on every `self`, open classes that re-route any of it at load time. There is no
capability value to name, so there is nothing for a capture set to *contain* — which is precisely
why ADR-103 chose labels-on-methods, an effect-system reading, over a capability reading. The
capability-role catalog (§ 3.4) offers footing for the parameter-shaped *fraction* of authority
(what a body demands of what was passed in) but none for the ambient remainder, and the ambient
remainder is where nearly every label originates (`effect-summaries.md:69-81`: constructs and
catalogue rows, not parameters).

What a CC-style presentation would *gain* is real but narrow: compactness (a one-glance footprint
suffix), a shared mental model with a visibly fashionable feature, and CC's adoption story — which
Rigor already has (opt-in `effects:` block, nothing required in application code, inference by
default is WD5's ladder; the m3tech post's "demands nothing from correct code" describes ADR-103's
own posture accurately).

## 5. Presentation options

**(a) Capture-set-style suffix on types in `type-of` / hover — ruled out.** Category error (§ 4.1:
no per-value effect fact exists), completeness over-claim (§ 4.3), and vocabulary collision
(§ 3.4). A suffix on the *type* of an expression would claim value-level tracking that no part of
the pipeline performs. This is the one option the conceptual differences genuinely forbid rather
than merely complicate.

**(b) Effect row in sig-gen output — the annotation-shaped surface, already decided.** ADR-103 WD9
scopes `sig-gen` emission of `%a{pure}` and envelopes to "exhaustive, undischarged summaries only" —
the honesty gate is in the decision. An envelope has the right polarity for this analyzer: it is a
*bound* (`≤`), so writing one never asserts completeness of an inference, and the checker that reads
it reads the proven lane only. `rigor effects --pure` already names the candidates (436 on Redmine).
This is the closest honest analogue to a CC annotation: author-visible, checked, and gradual.

**(c) Diagnostics-only — a mischaracterization of the status quo.** The status quo is report +
snapshot + three opt-in diagnostics, and WD17 settled that the snapshot, not a diagnostic, is the
enforcement surface for the labels teams care most about. Nothing here to change.

**(d) A dedicated report command — exists, and its row grammar is already the honest version of the
capture set.** `Key: [proven] ≤ [declared] …?` is a three-lane brace-set *on the correct carrier*
(the method key), with the hedge CC does not need and Rigor cannot drop. The improvement available
from CC is notational reach, not notation: put that same row where CC puts capture sets in Scaladoc
— i.e. the v0.4.x LSP hover slice that WD16 § 4 already reserves ("a hover that reports a method's
labels is a v0.4.x slice with its own consumer"), rendered in the report's grammar, never as a
suffix on the type.

**Recommendation.** Do not borrow CC's syntax; its semantics do not transfer (§ 4.1-4.4), and the
suffix's visual completeness claim is the one thing Rigor's adjudications forbid. Borrow CC's
*placement and posture* instead: (i) keep report + snapshot primary (settled, WD7/WD17); (ii) land
WD9's sig-gen emission as the annotation surface — it is the CC-analogous "user annotates the
boundary, analyzer checks it" loop with the polarity corrected to bounds; (iii) when the hover slice
lands, show the method's summary in the existing `[proven] ≤ [declared] …?` grammar, which is where
a CC user's "see the footprint at a glance" expectation is actually met. All three are affirmations
of decisions already made, which is itself the finding: ADR-103 independently arrived at the honest
subset of CC's presentation. A last, small caution from the m3tech post: CC's own surface renamed
its root capability and deleted a feature class within months — its notation is not yet a stable
thing to converge on even if it were semantically transferable.

## 6. Open questions

1. **A call-site variant.** `rigor type-of FILE:LINE:COL` at a *call* could print the callee's
   summary as a separate labelled line (`effects: [io.fs.write] …?`) without touching the type —
   honest, because it labels the call, not the value. It needs the effect table as a new consumer
   of a `type-of` run (cache identity per WD13), and no adjudication covers it either way.
2. **Separation Checking's read/write split.** `m.rd` vs `m` and `consume`/hiding rhyme faintly
   with `mutate.local`'s fresh-and-unescaped ownership analysis (`effect-summaries.md:94-99`).
   Nothing actionable — Rigor's ownership is syntactic and deliberately conservative — but if
   Separation Checking stabilizes it becomes the more interesting comparison, being about aliasing
   rather than authority.
3. **Verified plugin rows.** #454's declined option 3 (a plugin row *verified* against a source the
   analyzer read) is the one future in which a bound-flavoured presentation could show `io.db.*` in
   a lane a diagnostic reads. The ruling says reconsider only if that contribution kind exists; a
   presentation design should not anticipate it.
4. **Naming.** If any effect surface ever grows capability-flavoured language, it must not reuse
   "capability" — the term is occupied by capability roles (§ 3.4). "Footprint" (already the
   manual's word) is the available noun.
