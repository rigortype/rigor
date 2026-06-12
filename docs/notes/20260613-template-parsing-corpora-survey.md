# Template-engine / parser corpora survey (general-code Dynamic-fall + FP hunt)

2026-06-13. Read-only engine-behaviour survey across eight real-world
template-engine and parser gems under
`/Users/megurine/repo/ruby/rigor-survey/`. **No `lib/` (rigor) changes.**
Fourth campaign sibling, after the [CRuby-stdlib](20260612-cruby-stdlib-survey.md),
[algorithm-corpora](20260612-algorithm-corpora-survey.md), and
[Rails-monorepo](20260612-rails-monorepo-survey.md) surveys. These libs
all ship in production and run every render, so each `error` is an
FP candidate unless it catches a genuine bug. Metaprogramming and heavy
generics are excused per the mission framing; the value is **new mechanisms**
on plain general code, deduped against the three prior surveys + the
2026-06-12 arcs in `docs/CURRENT_WORK.md` (ADR-57/58 landed,
module-singleton done, case/else exhaustion done, regex-globals = ~0 FP
measurement-artifact, method-return genuine-conservative nil = demand-gated
WD1b).

Methodology follows the standing **"sample-adjudicate radius before sizing"**
lesson: every bucket below was confirmed by reading the firing site (and
minimal repros where a new mechanism was suspected), not inferred from counts.

Invocation per repo: cwd=`<repo>`, `BUNDLE_GEMFILE=<rigor>/Gemfile`,
flake-wrapped `bundle exec exe/rigor {coverage|check --no-cache} lib`,
default config (no `.rigor.yml`, no plugins). **No scaling wall here** —
every repo's whole-`lib` `check` finished in <2.2 s (these libs are small;
contrast the Rails-monorepo perf finding). **Excluded files:** none. The
`parser` gem's racc-generated lexer/grammar (`lexer-*.rb`, `ruby*.rb`) is
**not shipped in this checkout's `lib/`** (built at gem-build time); the
`lib/parser/lexer/*.rb` present are hand-written helpers, surveyed normally.

## Per-repo table

| repo | files | coverage (precise) | errors | warnings | top class | verdict |
| --- | --- | --- | --- | --- | --- | --- |
| liquid | 64 | 0.480 | 10 | 3 | undefined-method (cross-file `rescue Const`) | 1 NEW mechanism + known |
| slim | 27 | 0.538 | 2 | 4 | possible-nil (`[]` on regex local) + heterogeneous ivar | known + genuine catches |
| hamlit | 61 | 0.510 | 12 | 1 | possible-nil (`MatchData`/ivar) + `html_safe` (no AS plugin) | known + excused |
| erubi | 3 | 0.471 | 3 | 0 | `last_match` in `scan` block + runtime `extend` | known + excused |
| jbuilder | 12 | 0.414 | 1 | 2 | `deep_merge` (no AS plugin) + genuine heterogeneous ivar | excused + genuine catch |
| parser | 56 | 0.442 | 25 | 4 | possible-nil (one `loc(token)` trailing-`if` return, 25 sites) | known (method-return transit, WD1b) |
| rubocop-ast | 99 | 0.577 | 2 | 4 | possible-nil (`case`-no-`else` nilable) + heterogeneous ivar | known + genuine catches |
| herb | 42 | 0.589 | 5 | 6 | undefined-method `singleton(Herb)` (native C-ext) + `compact` return | 1 NEW mechanism + needs-RBS |

Mean precise ratio **~0.50** — the same band as the Rails sub-gems. The
floor is set by the same M3 untyped-param Dynamic (excused): every template
compiler / parser builder is a tree of `def compile(node)` / `def loc(token)`
methods over unannotated parameters, so the worst files are all the big
compiler/builder bodies (`parser/builders/default.rb` 0.276 over 4641 exprs,
`herb/engine/compiler.rb` 0.399, `hamlit/haml_attribute_builder.rb` 0.344,
`jbuilder_template.rb` 0.316). jbuilder reports **2 parse_errors** (two
`.rb` files the engine couldn't parse — genuine-broken-script catch, not
surveyed further).

## NEW-mechanism bucket table

Only mechanisms **not** already covered by the three prior surveys' buckets.
Each was reduced to a minimal repro.

| Bucket | Snippet | Radius (sample-adjudicated) | Verdict | Difficulty | FP-risk of fix |
| --- | --- | --- | --- | --- | --- |
| **T1. Cross-file `rescue <Const>` resolves to core class, not the enclosing-module sibling** | `M::SyntaxError = Class.new(Error)` in file A; in file B `rescue SyntaxError => e; e.line_number = 1` → resolves to core `::SyntaxError` → `undefined method 'line_number=' for SyntaxError` | **liquid 4** (`parser_switching.rb`); the only corpus with a core-shadowing module-namespaced error class used in a cross-file `rescue`. Minimal repro confirmed: single-file is **clean**, two-file fires — so it is specifically the cross-file const-discovery miss in the rescue exception-class position | **ARTIFACT — engine bug (FP on running code)** | low–medium (route `rescue`-clause exception-const resolution through the same discovery index every other const ref already uses; the local `class`-form already resolves, only the `Const = Class.new(...)` cross-file form in a `rescue` head falls through to the core class) | **low** (narrowing a const to the discovered same-namespace class is strictly more correct; only risk is a project that genuinely rescues the core class under a shadowed name — rare, and `::SyntaxError` spells that explicitly) |
| **T2. `Array#compact` does not strip `nil` from the element type** | `#: () -> Array[Node]` / `def compact_child_nodes; child_nodes.compact; end` where `child_nodes : Array[Node?]` → inferred `Array[Node?]` → `def.return-type-mismatch` | **herb 1** confirmed (`ast/node.rb:114`); generalises to every `arr.compact` whose receiver is `Array[T?]` (the engine folds `Tuple#compact` on constant elements in `shape_dispatch.rb:894` but the generic `Array[T?]` path falls to RBS, whose `compact: () -> Array[T]` keeps `T = Node?`) | **ARTIFACT — catalog gap** | **low** (add an `Array#compact` / `compact!` element-type projection that strips the `nil` constituent from `T`, mirroring the existing `Tuple#compact` fold and the ADR-47-era empty-removal projections) | **low** (compact provably removes nil; narrowing-only, additive) |
| **T3. `respond_to?(sym)` truthy edge does not narrow receiver non-nil** | `variable = cond ? evaluate(...) : nil; if variable.respond_to?(:count); variable.count` → possible-nil on `variable.count` | **liquid 1** (`tags/render.rb:78`); small. Real because `nil` only responds to a fixed core set — a truthy `respond_to?(:count)` proves `variable` non-nil | **ARTIFACT — narrowing gap** | low–medium (in the truthy edge of `recv.respond_to?(sym)` narrow `nil` out of `recv`'s type when `sym` is not in NilClass's method set; the conservative floor — always drop `nil` on any `respond_to?`-truthy edge — is sound because `nil.respond_to?(x)` is false for every method nil lacks) | **low** (narrowing-only; never promotes a non-nil type, only removes the `nil` constituent) |

## Known-bucket tally (one line each — re-reports, counted not re-analysed)

- **Method-return `T | nil` from a trailing-`if`/`case`-no-`else` body, consumed
  bare via a local** — the dominant FP across the corpus. `parser`'s 25
  possible-nil all trace to **one** method: `def loc(token); token[1] if token && token[0]; end`,
  whose `Source::Range | nil` return is consumed as `loc(t).with(...)` / `.join` /
  `.adjust` / `.end_pos` at 25 sites. Genuine-conservative (`loc` really can
  return nil for a tNL/nil token) = the demand-gated **WD1b method-return-transit**
  bucket. Same shape: rubocop-ast `parser_class(...)` (`case`-no-`else` → `new` for nil, 2),
  hamlit `@next_line`/`shift` loop-carried nilable (1). **~28 sites, all WD1b.**
- **`Regexp#match` / `Regexp.last_match` nilable MatchData consumed bare** —
  hamlit `match = pattern.match(s); match[4]` inside a `gsub!` block (5);
  erubi `match = Regexp.last_match; match.begin(0)` inside a `scan` block (2).
  The match provably succeeds (block-iteration / post-`gsub!`) but `.match` /
  `last_match`-in-a-block has no proven-match edge. = stdlib **C1** / Rails **G1**
  follow-up slice 5 (`.match`/block-`last_match` as narrowing predicates),
  demand-gated. **~7 sites.**
- **AS core_ext on core types without `rigor-activesupport-core-ext` loaded** —
  hamlit `"...".html_safe` (3), jbuilder `Hash#deep_merge` (1). Survey ran
  plugin-free by design; these resolve with the plugin. **Excused / config. ~4 sites.**
- **Native / C-extension module functions with no Ruby body** — herb
  `singleton(Herb)#diff` / `#leak_check` / `#arena_stats` (the gem is a
  Rust/C native extension; these are FFI-bound). = stdlib **C8** expected
  boundary, resolve via RBS. **~5 sites.** (herb also emits `rbs.coverage.missing-gem`.)
- **Genuinely-heterogeneous ivar writes (correct catches)** — jbuilder
  `@attributes` Hash→Array→`Jbuilder::Blank` (2); slim `@tab_re` Regexp→String (1)
  + `@translator` Static→Dynamic subclass union (1); rubocop-ast `@cur_index`
  Symbol→Integer (1). These are real worst-case flows the engine should keep
  flagging — **GENUINE-conservative, leave firing. ~5 sites.**
- **`flow.always-truthy/falsey` from constant-folded ivar/local guards** —
  scattered (parser 4, liquid 3, rubocop-ast 3, slim 2). Same family as
  stdlib **C5** / algorithm **M5** (mutated-ivar value folded inside a
  method body); FP-risky to "fix", FP-validate vs Mastodon/haml first.
  **~12 sites.**
- **Toplevel implicit-self / override-substitutability** — herb
  `unresolved-toplevel` `gemfile`/`source` (ADR-17 `pre_eval:` territory, 2);
  herb `override-param-narrowed` `initialize` (2) + `def.return-type-mismatch`
  `load` declared `bool` (1); hamlit `override-visibility-reduced` (1). Excused
  script idiom / genuine substitutability findings. **~6 sites.**
- **Runtime `extend` adds singleton methods** — erubi `CGI = Object.new;
  CGI.extend(...); CGI.escapeHTML(...)` (1). Metaprog-excused. **1 site.**

## Ranked attack order — NEW general-code mechanisms only

1. **T2 — `Array#compact` element-type nil-strip.** Smallest, cheapest,
   fully self-contained catalog fix; mirrors the existing `Tuple#compact`
   fold and the ADR-47-era empty-removal projections. Turns a genuine
   `def.return-type-mismatch` on the ubiquitous `xs.compact` idiom into a
   precise return. Low difficulty, low FP-risk, additive. **Good warm-up slice;
   radius is broader than the herb single hit — any `Array[T?]#compact` benefits.**
2. **T1 — cross-file `rescue <Const>` resolution.** Engine bug: the rescue
   exception-class const should resolve through the same module-namespaced
   discovery index every other const ref uses, instead of falling to the
   core same-named class. FP on running code; idiomatic in any gem that
   defines `XxxError = Class.new(Base)` siblings (Liquid's whole `errors.rb`,
   and a very common pattern). Low–medium difficulty, low FP-risk.
3. **T3 — `respond_to?(sym)` truthy-edge non-nil narrowing.** Narrowing-only,
   sound floor available (`nil.respond_to?(x)` is false for any method nil
   lacks, so drop `nil` on the truthy edge). Small measured radius (1 here)
   but a clean idiom (`x.respond_to?(:each) && x.each`) and FP-pure. Nice-to-have.

**Cross-corpus confirmation (not new work):** the demand-gated **WD1b
method-return-transit nil** is, once again, the single largest FP class —
28 sites here, dominated by one `parser` helper (`loc(token)` × 25). This
fourth corpus re-confirms that the highest-radius remaining general-code FP
is method-return `T | nil` consumed bare via a local, exactly the bucket the
ADR-58 arc adjudicated as genuine-conservative (the callee really can return
nil) and deferred. If WD1b is ever revisited, `parser`'s `loc` is the
canonical justification shape: a private helper with a `token[1] if …`
trailing-conditional return, called dozens of times on provably-non-nil
tokens. Everything else is excused (M3 untyped-param Dynamic, AS-plugin,
native C-ext, runtime `extend`), a correct catch (heterogeneous ivars,
broken jbuilder scripts), or the known C1/G1 regex-match-in-block follow-up.
