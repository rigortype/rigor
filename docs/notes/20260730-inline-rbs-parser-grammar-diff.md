# Inline RBS: `rbs-inline` gem vs `RBS::InlineParser` — grammar diff

Date: 2026-07-30. Against `rbs` 4.1.0 (`references/rbs` at the 4.1.0 tag) and `rbs-inline` 0.14.0,
the versions this repo resolves.

Status: **measurement note.** Answers question 1 of
[#229](https://github.com/rigortype/rigor/issues/229) — *are the two parsers' accepted grammars the
same today, or already diverged?* — which the issue asked be settled against a corpus rather than the
docs. The design commitment it feeds is an ADR-32 amendment, not made here.

---

## Method

Both parsers run over the same snippets, normalised to the surface Rigor consumes — the declared
`(class, kind, member, type)` tuples — so AST-shape differences do not count as divergence:

- gem: `RBS::Inline::Parser.parse` → `Writer.write` → RBS text → `RBS::Parser.parse_signature`
- built-in: `RBS::InlineParser.parse(buffer, prism)` → `Result#declarations` (+ `#diagnostics`)

Two probe-fidelity corrections were needed before any row could be trusted, and both had produced
false divergence first time round:

- The two trees name declarations differently (`name` vs `class_name` / `module_name`). Reading only
  `name` made **every** row differ for no reason.
- Snippets of my own invention are not evidence. A trailing `#: (Integer) -> String` on a `def` line
  is malformed in both dialects; it looked like divergence until the corpus was rebuilt from each
  implementation's own documentation (`references/rbs/docs/inline.md`, the gem's `README.md`).

## The result: divergence is bidirectional

Not "the gem lags upstream". Each accepts constructs the other does not.

### Both, identically

| construct | result |
| --- | --- |
| `@rbs (Integer) -> String` leading method type | identical |
| `#: (Integer, Integer) -> Integer` leading | identical |
| `def each_address(&block) #: void` trailing return | identical — `() ?{ (?) -> untyped } -> void` |
| `@rbs skip` | identical |
| **`def self.foo` singleton definitions** | **identical** |
| **`# @rbs @ivar: T` under `class`/`module`** | **identical** |

The last two matter for #229's framing: the issue lists them among rbs 4.1's new built-in features
that "Rigor cannot ingest today". Measured, the gem handles both. Of the three cited features only
**`module-self`** is genuinely built-in-only.

### Gem only — what switching would lose

| construct | gem | built-in |
| --- | --- | --- |
| `@rbs generic T` | `class Box[T]` | type params dropped, `AnnotationSyntaxError` |
| `@rbs!` embedded RBS block | declarations emitted | `AnnotationSyntaxError`, nothing emitted |
| `@rbs inherits Object` | accepted | `AnnotationSyntaxError` |
| `private` visibility | preserved | dropped, member emitted public |
| **`class << self`** | `def self.name` | **`name` as an INSTANCE method, no diagnostic** |

### Built-in only

| construct | built-in | gem |
| --- | --- | --- |
| `@rbs module-self: Comparable` | `module Sortable : Comparable` | silently ignored |
| `include A, B` | `MixinMultipleArguments` diagnostic | silently accepted |
| top-level `def` | two diagnostics naming the cause | silently drops |

Plus the surfaces the issue's grounding comment identified, which the diff does not contradict: a
typed `diagnostics` array, `type_fingerprint` per declaration, and the non-ASCII parsing speedup
(ruby/rbs#2950).

## The `class << self` row is the one that decides it

Every other divergence is a *rejection* — the annotation is dropped and, on the built-in side, a
diagnostic says so. `class << self` is different:

```
built-in member: DefMember name=name kind=instance singleton?=false
built-in diagnostics: []
```

The singleton method is declared as an **instance** method, silently. For Rigor specifically that is
not a missing feature but a wrong fact injected into the environment: calls to the real singleton
method become `call.undefined-method` false positives, and the fabricated instance method suppresses
genuine ones. `docs/inline.md` lists "The `class << self` syntax is not supported" under Current
Limitations — empirically, unsupported here means misattributed rather than ignored.

[ADR-5](../adr/5-robustness-principle.md) puts false positives above worst-case static reading, and
[ADR-93](../adr/93-default-rbs-inline-ingestion.md) default-wires this plugin, so the blast radius is
every user with `rbs-inline` resolvable — not an opt-in group.

## Question 3 — what the plugin relies on, and whether the built-in has it

| the plugin needs | built-in |
| --- | --- |
| `opt_in:` magic-comment mode (`require_magic_comment: true`) | **absent** — `parse(buffer, prism)` takes no such option, and no `rbs_inline:` directive handling exists in `lib/rbs/inline_parser.rb` |
| annotation-presence probe backing ADR-93's gating | **absent as such** — would be rebuilt on `CommentAssociation`. Not cosmetic: the ungated mode measured 26 → 42 diagnostics on mail |
| a writer producing RBS text | **absent by design** — it yields declarations for `Environment#add_source` |

The writer's absence is arguably an improvement (it skips Rigor's render→reparse round trip), but it
means a different integration path from the `virtual_rbs` pipeline. A move is a rewrite of the
plugin's spine, not a parser swap.

## Question 4 — the floor is not the blocker

Confirmed as [#229's grounding comment states](https://github.com/rigortype/rigor/issues/229#issuecomment-5115257662):
`rbs-inline` 0.14.0 itself declares `rbs (~> 4.0)`, so every user ADR-93's auto-wire can activate for
is already on rbs 4.x. The floor objection that
[ADR-94](../adr/94-rbs-inline-reader-and-the-rbs-3x-floor.md) turned on does not apply here. It simply
is not what stops the move.

## Recommendation

**Stay on the gem, and do not treat the built-in as a future-proofing move yet.** The built-in is not a
superset: it would trade generics, `@rbs!`, `inherits` and visibility for `module-self`, and would
introduce one silent misattribution in a default-wired plugin.

What the issue's real worry — users writing against upstream's docs and having Rigor drop it — argues
for is *not* switching but two cheaper things, neither of which needs a dialect decision:

1. Forward the parse failures the plugin currently swallows, so a dropped annotation is visible.
   Today's ADR-32 WD6 path reports a synthesis *error*; an annotation the gem simply ignores
   (`module-self`) reports nothing at all.
2. Document which dialect Rigor reads, in the plugin's README, naming `module-self` as the known gap.

Re-open when the built-in parser gains generics, `@rbs!`, and correct `class << self` handling —
that is the parity bar, and the third item is a correctness precondition rather than a feature.

## Limitations

- 16 corpus snippets covering the documented grammar of both, not a scrape of real-world annotated
  code. A construct neither doc describes was not exercised.
- Divergence is compared at the declaration surface. Two parsers agreeing there could still differ in
  location data or comment attachment, which Rigor does not currently consume.
- `rbs-inline` 0.14.0 only. Upstream intent (question 2) is unchanged from what
  [ADR-94](../adr/94-rbs-inline-reader-and-the-rbs-3x-floor.md) recorded — soutaro called the gem a
  prototype whose implementation would be merged into `rbs` — so the direction of travel is not in
  doubt, only its arrival.
