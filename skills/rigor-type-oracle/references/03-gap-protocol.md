# 03 — The gap protocol

Rigor answering "I don't know" is not the oracle failing. It is the
oracle telling you something the code alone would not have: precision is
lost *here*, for *this* reason. That is worth more than the annotation
you were about to write, and it is worth exactly nothing if you paper
over it.

**The rule: never convert a gap into a type.** Report it, locate it,
route it.

## Which output means which gap

### `Dynamic[top]` (erased: `untyped`)

Rigor has no class information for this expression at all. It is the
top type, and it is contagious: a `Dynamic[top]` receiver makes every
method call on it `Dynamic[top]` too, so one unresolved source can
account for a whole file of "unknown".

Common causes, in the order worth checking:

- A **method parameter** — parameters are `untyped` by design unless RBS
  or observation says otherwise. Not a defect; use call-site derivation.
- An **ivar** assigned from a parameter (`@currency = currency`) — the
  same gap, one hop later.
- A call into a **gem with no RBS** — the dominant cause on a real
  project.
- A call into a **framework Rigor is not configured for** — Rails
  without the Rails plugins enabled, say.
- The project's **own monkey-patch or DSL**, which the analyzer never saw
  defined.

### `untyped` inside an otherwise-precise type

`Array[untyped]`, `Hash[Symbol, untyped]`: the container is proven, the
element is not. Write the container. Do **not** invent the element — an
`Array[String]` you guessed is worse than the `Array[untyped]` Rigor
proved, because it will be believed.

### A method missing from `sig-gen` output — the `sig.skipped.*` reasons

Read stderr for the count, `--format=json` for the per-method reason.

| Reason | What it means | What you do |
| --- | --- | --- |
| `sig.skipped.untyped-return` | The body's last expression types as `Dynamic[top]`; emitting `untyped` would be noise. | The commonest gap. Trace the return expression back to its `Dynamic[top]` source and route *that*. Never write a return type here. |
| `sig.skipped.user-authored` | An RBS declaration already exists and `--overwrite` was not given. | Not a gap. The hand-written type is the project's answer — read `sig/`, and if it disagrees with inference, raise the disagreement rather than silently retyping. |
| `sig.skipped.unrenderable-rbs` | Rigor rendered a signature that does not parse as RBS, so it was dropped rather than written. | **A bug in Rigor**, not in the code. Report it with the method and the file. |
| `sig.skipped.complex-shape` | Reserved; the generator does not produce it today. | If you ever see one, it is worth reporting as a surprise. |
| `skipped_outside_sig_root` | A `--write` target outside the configured signature paths. | Configuration, not inference. |

`rigor explain <id>` answers each of these ids directly (the command
carries a second catalogue for the skip reasons alongside the
diagnostic rules); this table is the summary.

### `equivalent`, and silence

A `tighter-return` candidate that never appears was classified
`equivalent`: the inferred return is not a strict subtype of what `sig/`
already declares. The existing declaration stands. Silence here means
"nothing to change", not "nothing is known" — check `sig/` before calling
it a gap.

## Locating the gap before you report it

Two commands turn "somewhere upstream" into a line number.

```sh
rigor annotate FILE          # walk the #=> column upward to the first Dynamic[top]
rigor trace --format=json --line=N FILE
```

`annotate` is usually enough: the first line in the chain that reports
`Dynamic[top]` is the source, and everything below it is cascade. Use
`trace` when the loss happens *within* a line — its `bind` events name
each local and the type it received, so you can see which argument
arrived unknown.

If a diagnostic fired near the site, `rigor explain <rule>` gives its
firing conditions, which frequently name the cause outright.

## Routing table — project-side gaps have an owner

Once you know the source, the fix is almost never "write the type here".

| The gap's source | Route to | Why |
| --- | --- | --- |
| A dependency gem ships no RBS | **`rigor-rbs-setup`** | `rbs collection install` brings in community RBS; this is the single biggest `Dynamic` reduction on most projects. |
| A framework Rigor isn't configured for (Rails, RSpec, dry-rb…) | **`rigor-plugin-tune`** | The bundled plugin for it is probably just not enabled in `.rigor.dist.yml`. |
| `undefined-method` on the project's own monkey-patches | **`rigor-monkeypatch-resolve`** | Wiring the defining files into `pre_eval:` makes them visible. |
| The project's own DSL / `define_method` factory / `method_missing` | **`rigor-plugin-author`** | Rigor does not bundle per-application plugins; a project-owned plugin is the durable fix. |
| The site is protected-coverage work, not a documentation task | **`rigor-protection-uplift`** | It owns the "minimal true annotation + double gate" loop. |
| The setup itself looks wrong (zero RBS classes, config not taking) | **`rigor-doctor`** | Validate before concluding anything about inference. |
| None of the above — Rigor should have inferred this | A Rigor issue | See below. |

Offer the route; do not silently switch tasks. The user asked you to
document a class, and "the reason I cannot is X, and here is the skill
that fixes X" is the answer to that request.

## Reporting an engine-side gap

When the type is derivable from the source and Rigor still says
`Dynamic[top]`, that is a completeness gap in the engine, and it is worth
more to the project than any annotation. File it at
<https://github.com/rigortype/rigor/issues> with these five parts:

1. **The file and line** — the smallest reproduction you can get to,
   ideally a standalone snippet rather than a pointer into a private
   repo.
2. **The exact command**, as run: `rigor type-of demo.rb:12:5`,
   `rigor sig-gen --print demo.rb`.
3. **The exact output**, pasted, including the stderr skip line.
4. **What the correct type is, and what proves it** — the Ruby-level
   reasoning a reader can verify. "`Array#sum` over `Integer` elements is
   `Integer`", not "it should obviously be Integer".
5. **What the report proves** — one sentence naming the *class* of gap,
   not just the instance: "block-parameter destructuring loses the
   element type", "a keyword default of `Time.now` does not seed the
   parameter". This is the part that makes the issue actionable, because
   it says what a fix would generalise to.

Also say `rigor --version`, and note whether `sig/` and the relevant
plugins were in play — a gap that only appears without community RBS is a
different bug from one that survives it.

Inside Rigor's own tree the same report is the deliverable: the gap is
the reason not to hand-write the RBS there.
