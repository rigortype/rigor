# L2 伝(a) — Ruby-only reader lens review (2026-07-11)

**Lens:** a working Ruby programmer who knows `String` / `Array` /
`Hash` / `Data` as real classes, has hit `NoMethodError` on `nil`,
but has **no type-declaration mental model** and conflates "type"
with "class." No RBS, TypeScript, or Sorbet background.

**Scope:** handbook chapters 01–12 only. The appendices
(`appendix-typescript`, `-mypy`, `-steep`, `-rust`, `-type-theory`,
etc.) are each explicitly written *for* a reader who already owns a
static-type-checker mental model — the exact reader this lens
simulates the absence of — so they are out of scope for this lens
and were not reviewed line-by-line. The finding that matters for
this reader lives entirely in the numbered chapters.

## Findings

| Location (file:line + quote) | The stumble | Severity | Proposed minimal fix |
| --- | --- | --- | --- |
| `07-rbs-and-extended.md` is where RBS is first taught, but RBS *signature syntax* is load-bearing from ch1 onward. Sharpest instance: `05-methods-and-blocks.md:50-56` — the whole `call.argument-type-mismatch` section turns on reading `def normalise: (::String id) -> ::String` (the `def name:` colon form, `::String`, the `->` return arrow) with no gloss. | This reader does not know RBS. The README's non-goals (`README.md:263-264`) declare "RBS basics — all assumed," but the "Who this is for" reader (`README.md:8-17`, a Rubyist who hits `NoMethodError on nil`) plausibly has *never written RBS* — RBS is not common knowledge among working Rubyists. So the one signature language the whole diagnostic model rests on is treated as known from ch1, and the reader must parse `(::String) -> ::String` to follow ch5's flagship diagnostic, four chapters before ch7 explains the syntax. They can *guess* "takes a String, returns a String," but every `.rbs` block up to ch7 is a small decoding tax. | FRICTION | In ch1 (near `01-getting-started.md:79`, the first `sig/*.rbs` mention) add one sentence: "RBS is Ruby's signature language — `def foo: (String) -> Integer` reads 'foo takes a String and returns an Integer'; ch7 covers it. If you have never written RBS, skim ch7 first." That one gloss unblocks the reader for every intervening `.rbs` block. |
| `02-everyday-types.md:44-45` — "square brackets hold type parameters, exactly as in RBS — `Nominal[String]`, `Hash[K, V]`, `Dynamic[top]`." | The reader knows `Hash` the class but not that `Hash[K, V]` is a *parameterised type* with `K`/`V` standing for the key and value types — that is the generics idea, a type-declaration concept this reader lacks. It is introduced as pure notation ("exactly as in RBS"), i.e. assumed-known, in the very chapter meant to build the model from scratch. | FRICTION | Add half a sentence: "`Hash[K, V]` means a Hash whose keys are type `K` and values type `V` — the brackets carry the element types, the way `Array[String]` is 'an array of strings.'" |
| `01-getting-started.md:189-199` — the "no annotations" section shows `assert_type(":int \| :str \| nil", kind(7))` and the comment `# Constant<"Hello, ">` … `# String?  (RBS-declared)` … "literal-string carrier … provably source-derived." | Chapter 1 previews the full carrier notation (`Constant<…>`, the `A \| B \| nil` union spelling, `String?`, the `literal-string` refinement) before chapter 2 introduces *any* of it. For a reader with no type-value vocabulary, `Constant<"Hello, ">` (a value shown as a type) and `:int \| :str \| nil` are opaque exactly at the motivational moment they are meant to impress. | FRICTION | The examples are fine; add one forward-pointer line after the block: "Don't worry about the exact spellings (`Constant<…>`, `A \| B`) yet — chapter 2 introduces every one. Here just notice: no annotations were written." |
| `01-getting-started.md:194` — `name = ARGV.first  # String?  (RBS-declared)` | `String?` (the trailing `?` = "or nil") is a type-declaration notation used here with no gloss; it is only explained one chapter later at `02-everyday-types.md:72` ("RBS says `String?` — String \| nil"). First-use precedes the explanation. | nitpick | Pull the ch2 gloss forward inline: `# String?  (String or nil — RBS-declared)`. |
| `04-tuples-and-shapes.md:228-291` — the `pick_of`/`omit_of`/`partial_of`/`required_of`/`readonly_of` section, "They mirror TypeScript's `Pick` / `Omit` / `Partial` / `Required` / `Readonly` utility types," with a "TypeScript analogue" column and an `%a{rigor:v1:return: pick_of[...]}` RBS directive at `:256`. | Two smaller snags compound: (a) the section anchors on TypeScript utility types this reader has never seen — though the "What it does" column *does* carry the meaning independently, so TS stays a bonus aside, not a block; (b) it shows an `%a{rigor:v1:…}` RBS::Extended directive three chapters before ch7 introduces that syntax. The bigger issue is altitude: derived-shape projections are an advanced surface landing in an "everyday structures" chapter. | FRICTION | No rewrite needed for (a) — the plain-English column already does the work. For (b)/(altitude), add a one-line lead-in: "This is an advanced surface — skip it until you have a `HashShape` you actually want to reshape. The `%a{rigor:v1:…}` syntax is chapter 7." |
| `12-lightweight-hkt.md:1-9` — opening paragraph: "there is no way to spell a recursive sum type without quantifying over a type constructor," then `:24-28` "defunctionalised encoding of higher-kinded types in the Yallop & White 2014 / fp-ts style." | A reader routed here by the chapter's own stated entry point ("where does `JSON.parse` get its type from?", `:311-313`) hits "recursive sum type," "quantifying over a type constructor," and "defunctionalised higher-kinded types" *before* the "this is the most advanced chapter, most readers need only the first two sections" signpost at `:30-35`. The impenetrable jargon comes first; the reassurance comes after. | FRICTION | Move the `:30-35` "most advanced chapter / read only the first two sections" note to immediately after the `JSON.parse` code block at `:19`, before the type-theory sentence. Reader gets the escape hatch before the jargon. |
| `08-understanding-errors.md:113-114` — `def.override-return-widened` "widens the inherited return (covariance)"; `def.override-param-narrowed` "narrows an inherited parameter type (contravariance)." | "covariance" / "contravariance" are unglossed in the rule table. This reader has no idea what they mean. | nitpick | Low-cost because the plain-English "widens the inherited return" / "narrows an inherited parameter" already carries each row — the Greek is a redundant label. Either drop the parenthetical or leave it; no reader is blocked. Listed only for completeness. |
| `02-everyday-types.md:220-237` — `Dynamic[top]` "the gradual carrier"; `Dynamic[T]` "the static facet behaves like `T`"; `:225` "shortened to `untyped` for the RBS-erased view." | "top," "gradual carrier," "static facet," "RBS-erased view" are four pieces of type-system jargon in one section. Most are softened — `Dynamic[top]` is glossed "could be any Ruby value" (`:222`), which is the load-bearing meaning — but "static facet" and "RBS-erased view" are bare. | nitpick | The `:222` gloss does the essential work; the reader gets "any value." Optionally gloss "static facet" as "the type it behaves like when Rigor does know something." Not blocking. |

## Verdict

The handbook does its single most important job — bridging this
reader's "type ≈ class" reflex — **well and early**. Chapter 2's
opening section, *"Why 'type' is too coarse a word"*
(`02-everyday-types.md:9-40`), is the cleanest-reading passage in
the whole book for this lens: it names the exact
class-vs-value-subset confusion this reader carries and dissolves
it in three examples before introducing a single carrier.
Chapter 3 (narrowing) is the next-cleanest — it defines its own
term and builds every rule from Ruby predicates the reader already
uses (`empty?`, `is_a?`, `nil?`), assuming nothing. Chapters 1–3
as a unit are a genuinely gentle on-ramp.

The friction is concentrated in two seams. First, and most
pervasive: **RBS signature syntax is load-bearing from chapter 1
but only taught in chapter 7**, and while the README formally
declares "RBS basics assumed," the target reader — a Rubyist who
hits `NoMethodError`, not a typing enthusiast — likely doesn't have
them; a single early gloss on "what an RBS sig reads like" would
pay for itself across five chapters, with chapter 5's
`call.argument-type-mismatch` the sharpest pinch point. Second, the
**advanced surfaces sit at their heaviest right where a first-time
reader is least ready**: chapter 4's shape-projection functions and
chapter 12's HKT opening both front-load their most theoretical
material (TypeScript utility types; "recursive sum type,"
"defunctionalised higher-kinded types") before their own
"skip-this-for-now" signposts. Neither truly *blocks* the reader —
there is no hard stuck-point in the core path — but both would read
noticeably smoother if the reassurance came before the jargon.
Chapters needing the most work by this lens: **12** (reorder the
skip-note ahead of the theory) and **4** (flag the projection
section as advanced); the RBS-gloss fix is a one-line addition to
**1** that improves **5** and everything in between.
