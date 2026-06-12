# App / network corpora survey (general-code Dynamic-fall + FP hunt)

2026-06-13. Read-only engine-behaviour survey across eight real-world
application / networking / concurrency libraries under
`/Users/megurine/repo/ruby/rigor-survey/`. **No `lib/` (rigor) changes.**
Sibling of the 2026-06-12 trio (`20260612-cruby-stdlib-survey.md`,
`20260612-algorithm-corpora-survey.md`,
`20260612-rails-monorepo-survey.md`); this round targets *idiomatic
gem* Ruby — callback registries, parsers, graph mixins, FFI wrappers —
where the user's trustworthiness criterion bites. Methodology follows
the stdlib survey's standing lesson: **every radius is
sample-adjudicated against the source before it is sized.**

Targets (READ-ONLY, `lib/`): mail, net-ssh, faraday, concurrent-ruby,
textbringer, tdiary-core, rgl, protobuf (`ruby/lib`).

Invocation: cwd=target, `BUNDLE_GEMFILE=<rigor>/Gemfile`, flake-wrapped
`bundle exec exe/rigor {coverage|check --no-cache} lib`.

**Perf note (good news):** the file-count scaling wall the Rails survey
flagged is **gone** — the landed run-scoped return memo + consult-gate
fix (`4b476918`) holds. Whole-`lib` `check` finished in ≤3.6 s wall for
every target including mail (111 files) and concurrent-ruby (178). No
sharding needed.

## Per-repo table

| repo | files | coverage (precise) | errors | warnings | top class | verdict |
| --- | --- | --- | --- | --- | --- |
| mail | 111 | 0.977\* | 6 | 19 | `flow.unreachable-branch` (11) | \*ratio inflated by generated Ragel parsers; real general files 0.32–0.37. Errors = AS core-ext / nilable-lookup, mostly needs-RBS/known |
| net-ssh | 97 | 0.514 | 17 | 14 | `call.possible-nil-receiver` (12) | **N1 callback-ivar swap → always-falsey + for-nil**; rest C3 nilable-return / needs-RBS |
| faraday | 33 | 0.442 | 8 | 0 | `call.undefined-method` (5) | **N4 `respond_to?` guard** (2) + Struct-subclass `self.class` singleton (4) + `URI.find_proxy` RBS gap |
| concurrent-ruby | 178 | 0.505 | 11 | 17 | `def.override-visibility-reduced` (15) | **N2 `0?`/`Dynamic?` ivar in `<=`** (2) + Enumerator-metaprog + Monitor/Float catalog gaps |
| textbringer | 77 | 0.656 | 28 | 17 | `call.undefined-method` (23) | **N1 (for-nil) + N3 `&.`-on-nil firing + N2 `Dynamic?` `<`**; module-singleton cross-file residual (13 `Utils.message`) |
| tdiary-core | 69 | 0.525 | 3 | 244 | `call.unresolved-toplevel` (234) | plugin-DSL toplevel idiom (EXCUSED, ADR-17); 3 genuine-conservative possible-nil |
| rgl | 28 | 0.434 | 0 | 13 | `flow.always-truthy-condition` (13) | **N5 overridable-method literal-fold** (`directed?` mixin) — entire warning set |
| protobuf | 24 | 0.547 | 4 | 0 | `call.possible-nil-receiver` (2) | Struct-subclass singleton (`from_hash`/`new` on `Struct`) + nilable-return `<` |

`refined`/`dynamic_specific` ~0 everywhere (no RBS, no refinements in
these trees). `dynamic_top` 24–57 %; the high end is param-sourced M3
gradual typing (excused) + the ivar mechanisms below.

\* **mail coverage is a measurement artifact.** `address_lists_parser.rb`
alone is 255 548 of mail's 422 116 expressions — a machine-generated
Ragel state table the constant-folder types precisely, dragging the
whole-repo precise ratio to 0.977. The hand-written mail files
(`address.rb` 0.32, `part.rb` 0.34, `common_address_field.rb` 0.34) are
the real signal and sit with the rest of the corpus. Read repo coverage
off the worst-files list, not the generated-parser-inflated summary.

## NEW-mechanism bucket table

All probed to a minimal standalone repro (or noted where it did not
isolate). Radius = sample-adjudicated firing sites across the eight repos.

| Bucket | Snippet (minimal repro) | Sample-adjudicated radius | Verdict | Difficulty | FP-risk of fix |
| --- | --- | --- | --- | --- | --- |
| **N1. Multiple/parallel-assignment ivar target dropped from the class-ivar union** | `old, @cb = @cb, block` (net-ssh `channel.rb`); `@i, @o, @stderr, @wait_thr = Open3.popen3(c)` (textbringer). The ivar then types as pure `nil` (or constant-nil) → `if @cb` folds **always-falsey**, and `@wait_thr.alive?` is **undefined-for-nil** | **~21+** (net-ssh: 6 channel always-falsey + state/key_factory + the 13 textbringer `for nil` ride this) | **ARTIFACT — engine gap (top NEW priority)** | low–medium (extend the `ScopeIndexer` ivar-write collector to recurse into `MultiWriteNode`/`MultiTargetNode` ivar targets — the same node family as the stdlib destructure-crash fix) | **low** (collecting a real write only *adds* a constituent; removes spurious nil) |
| **N2. Declaration-sourced ivar nil/`Dynamic` taints an `argument-type-mismatch` context** | `@lines = lines` (untyped param) then `while n < @lines` → `got Dynamic[top]?`; `@length = 0; … while k <= @length` → `got 0?`. Bare `Dynamic[top]`/`Integer` would be gradual-consistent; the `?` (read-site nil from a non-definitely-assigned ivar) is what rejects | **~9** (textbringer floating_window 5× `< @lines`; concurrent priority-queue 2× `<= @length`; scattered) | **ARTIFACT — ADR-58 coverage gap** | medium (extend ADR-58 "declaration-sourced nil ≠ diagnostic fuel" from `possible-nil` to `argument-type-mismatch`, or swallow the nil constituent of a `Dynamic[top]?` operand in a gradual-consistency check) | low–medium (must not mask a *flow-live* nil; gate on declaration-provenance like ADR-58 WD1) |
| **N3. Safe-navigation `&.m` fires `undefined-method` when the receiver types as exactly `nil`** | `@t = nil; … @t&.alive?` → `undefined method 'alive?' for nil` | ~the textbringer `for nil` cluster overlaps N1 (only reachable because N1 left the ivar pure-nil), but the `&.` firing is **independently wrong** | **ARTIFACT — engine bug** (safe-nav must never raise undefined-method; on a definitely-nil receiver the call is statically skipped) | low (suppress the existence check on the nil-receiver edge of a `&.` call) | **none** (sound — `&.` is exactly the nil-skip operator) |
| **N4. `x.respond_to?(:m)` truthy edge does not narrow `x` non-nil** | `url = "./#{url}" if url.respond_to?(:start_with?) && url.start_with?('//')` → possible-nil on the `&&` rhs | ~3 (faraday `connection.rb` 2; duck-typed guards elsewhere) | **ARTIFACT — missing narrowing predicate** | low (add `respond_to?` to the truthy-narrowing predicates; `nil.respond_to?(:m)` is `false` so the truthy edge soundly proves non-nil — ideally also narrow to a structural shape carrying `m`) | **low** (narrowing-only) |
| **N5. Implicit-self call to an *overridable* method whose base def returns a literal is constant-folded** | `module Graph; def directed?; false; end; … def reverse; return self unless directed?; end` — `directed?` folds `false` (ADR-57 adoption), making `unless directed?` always-true / `if directed?` always-falsey, **ignoring that concrete subclasses override `directed?` to `true`** | **13** (rgl `adjacency`/`base`/`dot`/`transitivity`/… — the entire rgl warning set) | **ARTIFACT — ADR-57 adoption over-reach on open methods** | medium (don't fold a self-call return to a constant when the method is open/overridable — has subclasses/includers that redefine it; the adoption is sound for the *value* but unsound as a *flow constant* for a template-method) | **medium** (must keep folding genuinely-final self-calls; over-conservatism re-opens a Dynamic source) |

## Known-bucket tally (one line each — re-confirmations, not new)

- **C3 / G2 over-nilable builtin / method return consumed bare** (`<`,
  `%`, `[]`): net-ssh `buffer.rb` `read_bignum → T?` then `d % (p-1)`
  (4), ed25519, password `type`, forward `shutdown`/`close`,
  protobuf/mail/tdiary scattered possible-nil. ~20 sites.
  Genuine-conservative / catalog precision; demand-gated per prior notes.
- **C2 / G4 cross-method ivar state-join → nil/Dynamic** (the
  `Dynamic[top]?` half feeding N2): same mechanism as ipaddr `@mask_addr`
  (ADR-58 WD3 landed the ctor-definite-assignment subset). The N2 row is
  the *new diagnostic-rule surface* of this, not a new root.
- **M5 / C5 ivar-value constant-fold over-eagerness** (`if @callback`,
  `if @size == 1`): subsumed by N1 here (the fold is *correct* once you
  accept the dropped write; N1 is the actual bug). Pure-M5 (non-multi-assign)
  always-truthy/falsey appears in mail (6) / textbringer (6) — known,
  FP-validate-vs-Mastodon-gated per prior notes.
- **Module-singleton `def self.x` / `module_function` resolution**:
  textbringer `Utils.message`/`foreground` (13) fired but **did not
  isolate** — minimal 2-file nested `module_function` + `Util.message`
  cross-file repros are all clean on this engine; the firing is a
  cross-file discovery-order interaction in the full tree. Logged as a
  residual of the landed module-singleton bucket, not a new mechanism.
- **Struct-subclass `self.class` / `Struct.new(...)` singleton dispatch**:
  faraday `Options < Struct` (`self.class.member_set`/`options_for`, 4),
  protobuf (`from_hash`/`new` on `Struct`, 2). `self.class` of a Struct
  subclass instance types as generic `Class`/`Struct`, missing
  user-defined `def self.x`. Struct-metaprog-adjacent; borderline-excused.
- **M3 untyped-param → whole-method Dynamic**: the 0.43–0.55 floor on
  graph algos (rgl dijkstra/bellman_ford/transitivity 0.19–0.25),
  parsers, FFI wrappers. EXCUSED (gradual entry point).
- **`call.unresolved-toplevel` plugin/script idiom**: tdiary-core 234
  (every `NN<name>.rb` plugin defines toplevel helper `def`s + calls the
  tdiary plugin DSL at toplevel). EXCUSED — ADR-17 `pre_eval:` territory.
- **needs-RBS catalog gaps**: mail `Hash#symbolize_keys` /
  `File.makedirs` (AS-core-ext monkeypatch absent here), faraday
  `URI.find_proxy`, concurrent `Float#strftime` / `Monitor#from` (no
  RBS), `Numeric#to_f`-family (G3, already queued). NEEDS-RBS.
- **`def.override-visibility-reduced`** (concurrent 15): framework
  override-visibility, known/benign.
- **`flow.dead-assignment`**: net-ssh socks5 `hostname`/`portnum` (3),
  mail (2), tdiary (3) — GENUINE catches (real dead locals), keep.

## Ranked attack order — NEW general-code mechanisms only

1. **N1 — collect multiple/parallel-assignment ivar targets into the
   class-ivar union.** Highest NEW radius (~21+ across net-ssh +
   textbringer), root-causes a whole cluster of always-falsey + for-nil
   FPs on the ubiquitous callback-registry (`old, @cb = @cb, block`) and
   capture-the-popen-tuple (`@i,@o,@e,@thr = Open3.popen3`) idioms.
   FP-safe (adds a real write), low–medium difficulty, reuses the
   `MultiWriteNode`/`MultiTargetNode` handling already added for the
   stdlib destructure fix. **Do first.**
2. **N3 — suppress the existence check on the nil-receiver edge of
   `&.m`.** Independently a soundness/FP bug (safe-nav must never raise
   undefined-method). Tiny, zero FP-risk; partly overlaps N1's surface
   but worth fixing on its own merits so any pure-nil receiver under `&.`
   is silent. Cheap, do alongside N1.
3. **N4 — `respond_to?(:m)` as a non-nil (and ideally structural)
   narrowing predicate.** Low difficulty, narrowing-only (sound:
   `nil.respond_to?` is false), removes a clean duck-typing FP slice.
   Cheap independent win.
4. **N2 — extend ADR-58 declaration-sourced-nil-is-not-fuel from
   `possible-nil` to `argument-type-mismatch`** (the `Dynamic[top]?` /
   `0?` operand in `<`/`<=`). Medium; gate on declaration-provenance
   exactly as ADR-58 WD1, FP-validate vs Mastodon/haml. ~9 sites.
5. **N5 — don't constant-fold a self-call return for an *overridable*
   method** (base def returns a literal but subclasses/includers
   redefine it). Removes the entire rgl warning set (13) and the
   template-method false-folding class. Medium difficulty + medium
   FP-risk (must preserve folding of genuinely-final self-calls — gate
   on "no override of this method in any discovered subclass/includer").
   The one ADR-57-adoption-tightening of the round.

**Headline.** The dominant NEW general-code FP across this app/network
corpus is **N1 — parallel-assignment ivar writes silently dropped**,
which pure-nils the ubiquitous callback-registry and popen-tuple-capture
idioms and cascades into always-falsey (`if @cb`), undefined-for-nil
(`@thr.alive?`), and safe-nav firings (N3). It is FP-safe and cheap. N5
(overridable-method literal-fold) is the highest single-file radius (all
13 rgl warnings) and the one place the otherwise-good ADR-57 adoption
gate over-reaches on template-method mixins. Everything else
re-confirms the C2/C3/M3/module-singleton/needs-RBS buckets from the
2026-06-12 trio. The file-count scaling wall is confirmed closed.
