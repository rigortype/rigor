# CRuby stdlib survey (Dynamic-fall + FP hunt, post-ADR-55/56/57)

2026-06-12. Read-only engine-behaviour survey against CRuby's own
standard library. **No `lib/` (rigor) changes.** The target tree
(`/Users/megurine/local/src/ruby/lib`, 626 `.rb` files) is READ-ONLY and
works by definition, so every `error` diagnostic is a false-positive
candidate. Sibling of `20260612-dynamic-fall-pattern-survey.md` (the
probe-corpus survey); that note's mechanisms B1/B3/B4 (block/loop content
write-back) and the ADR-57 adoption gate are now LANDED — this survey
re-measures against *real* stdlib code rather than synthetic probes.

## Methodology + coverage

Full run, default config (no `.rigor.yml` in the target):

```
cd /Users/megurine/local/src/ruby && \
BUNDLE_GEMFILE=<rigor>/Gemfile nix … develop <rigor> --command \
  bundle exec <rigor>/exe/rigor check --no-cache lib
```

- **Coverage: all 626 `.rb` files.** Wall **3m45s** (user 3m36s), peak
  RSS ~per-worker; fork backend. 313 errors in 92 files; 498
  error+warning diagnostics total across 129 files.
- **Vendored split:** 216 of 498 diagnostics (~43%) live under
  `lib/bundler/vendor/**` + `lib/rubygems/**` (re-vendored gems —
  connection_pool, net-http-persistent, fileutils copy). Pure-stdlib
  diagnostics: 282. Findings below are quoted from the **pure-stdlib**
  set unless noted; the vendored tree mostly duplicates the same classes.
- **Instrument 2 (sig-gen census):** `rigor sig-gen --print
  --format=json` was run over a 23-file representative slice (set,
  ostruct, optparse, shellwords, pathname, csv, uri, cgi, securerandom,
  time, ipaddr, tempfile, delegate, forwardable, find, open3, open-uri,
  tmpdir, fileutils, pp, prettyprint, resolv, English). **Finding: it is
  the wrong census instrument** — sig-gen emits only *candidate* methods
  (new/changed/tighter-return), 25 across 14 files, and every `untyped`
  return in that set was an `initialize` (param-driven `untyped`, return
  is `void`). `--tighter-returns` = 0 (the tree ships no RBS to tighten
  against). The Dynamic-fall census below is therefore read off the
  **diagnostic flow** (nil-union / `Dynamic[top]` operands that appear in
  argument-mismatch and possible-nil messages) plus targeted repros,
  not a sig-gen return histogram.

### sig-gen CRASH found en route (see Instrument-1 #1)

`rigor sig-gen` over `lib/erb.rb` aborts the **entire run** with an
uncaught `NoMethodError` (the `check` path recovers it per-file as an
`internal analyzer error`). Root-caused below.

## Instrument 1 — diagnostics (FP hunt)

Pure-stdlib error classes (vendored excluded), normalized:

| Class | Example site | ~Count | Verdict | Mechanism | Minimal repro |
| --- | --- | --- | --- | --- | --- |
| **`internal analyzer error: undefined method 'name' on Prism::MultiTargetNode`** | `lib/erb.rb:937 def location=((filename, lineno))` | 1 (+ crashes all of sig-gen) | **ARTIFACT — engine bug (recoverable)** | `method_parameter_binder.rb:115`/`:119` call `.name` on every `requireds`/`posts` entry; a destructured positional `((a,b))` is a `Prism::MultiTargetNode` with no `#name` | `def location=((a,b)); end` → `check`: error; `sig-gen`: hard crash |
| **`undefined method 'new' for Struct`** | `lib/rubygems/requirement.rb:23 Struct.new(:for_lockfile).new "!"` | 3 | **ARTIFACT — engine bug** | the *chained* `Struct.new(:a).new(…)` — `Struct.new(...)` result does not type as a `.new`-bearing singleton in chained position (constant-bound `S = Struct.new(...); S.new` works) | `Struct.new(:a).new("!")` → `error`; `S = Struct.new(:a); S.new("!")` clean |
| `possible nil receiver` (`[]`,`[]=`,`include?`,`delete`,`split`,`<<`,…) | `lib/resolv.rb:711 size`; `lib/mkmf.rb:2500 target[/\A\w+/]`; `lib/erb/compiler.rb:464 comment[…]` | ~110 stdlib / 180 total | **MIXED — mostly upstream nil-union imprecision (artifact-ish), some genuine** | receiver is a local/ivar/regex-global typed `T?` because an *upstream* source fell to a nil-union: regex globals (`$1`,`$+`,`$~`) type nil-able; Hash `[]` lookups return `V?`; cross-method ivar joins. The `&&`/`if x` guards exist in source but the nil isn't narrowed out because the receiver's *value-flow* is already widened | did **not** reduce in isolation — flow-context-specific (constant-fold short-circuits the guard, or the nil-union only forms across the full class). Driver = census buckets C1/C2/C3 below |
| `argument type mismatch at '^' on Integer: got Dynamic[top] \| Integer \| nil` | `lib/ipaddr.rb:463/466/513 IN4MASK ^ @mask_addr` | 6 | **ARTIFACT — cross-method ivar join** | `@mask_addr` is assigned in several methods (`mask!`, `set_prefix`, ctor) with differing types; the ivar state-join widens to `Dynamic[top]\|Integer\|nil`, then `Integer#^` rejects it. Single-method assignment (`@m=0` in ctor only) is precise | `class M; def initialize;@m=0;end; def f;0xff ^ @m;end;end` is clean → needs the multi-writer ivar to reproduce (census C2) |
| `argument type mismatch … create on Resolv::LOC::Size: expected …Size\|String, got Integer` | `lib/resolv.rb` LOC::Size/Coord/`allocate_request_id`/Sender `new` | ~8 | **NEEDS-RBS (genuine vs sig)** | Resolv ships **no RBS**; inferred sigs are too strict (Ruby accepts an `Integer` the inferred param type excludes). Not an engine bug — an RBS/inference-precision gap on a no-RBS library | n/a (library-specific) |
| `undefined method 'name' for Resolv::DNS::Resource` | `lib/resolv.rb:617 data.name` after `when Resource::CNAME` | 1 | **GENUINE-conservative** | narrowed to base `Resource::CNAME`, which does not declare `attr_reader :name`; the concrete `IN::CNAME` subclass (line 2234) does. Base-class-after-narrowing attr gap — borderline genuine | n/a |
| `undefined method 'untaint' for String` | `lib/fileutils.rb:2166` (+ vendored copy) | 2 | **GENUINE (true catch)** | `Object#untaint` was **removed in Ruby 3.2**; the stdlib line is dead-on-modern-Ruby. Rigor is correct — not an FP | n/a |
| `wrong number of arguments` | `lib/resolv.rb:700 send`; TCPSocket `open`; Gem::ConfigFile `new` | 13 | **MIXED — NEEDS-RBS / genuine** | mostly built-in/library RBS arity gaps (`send` resolved to a too-narrow sig; socket `open` overloads) | n/a |
| `condition is always truthy/falsey` | `lib/bundled_gems.rb:203 if caller_gem`; `lib/mkmf.rb:197` | 85 (41 vendored) | **MIXED — block-capture/global driven** | `caller_gem = $1` assigned *inside* an `each`+`break` then read after the loop reads the pre-loop `nil` → spurious `always falsey`. Loop *reassignment* (not content-mutation) write-back of a plain local; compounds with regex-global nil typing | did not reduce standalone (needs the `=~`+`break` loop shape with global capture) |
| `return-type mismatch` / `return type widened … breaks substitutability` | `lib/uri/ldap.rb`, `lib/uri/generic.rb` | 47+4 | **MIXED** | accessor returns inferred `Dynamic[top]?` vs declared `String` — ivar-state Dynamic-fall (C2) surfacing through the override-conformance check | n/a |
| `instance variable … previously assigned A; this write assigns B` | `lib/rubygems/specification.rb @new_platform` | ~5 | **GENUINE-conservative** | genuinely heterogeneous ivar writes (`Platform` then `Gem::Platform`); true worst-case flow | n/a |

## Instrument 2 — Dynamic-fall census

Mechanisms driving real-stdlib `Dynamic[top]` / nil-union falls, ranked
by radius (read off the diagnostic operands + targeted repros, since
sig-gen's candidate filter under-covers):

| Bucket | Mechanism | Rough radius | Difficulty | Precision-additive? | Class |
| --- | --- | --- | --- | --- | --- |
| **C1. Regex globals (`$1`,`$~`,`$+`,`$'`) typed nil-union** | every `str =~ re; … $1` / `$~[1]` / `scan(re){ … $+ }` reads a `T?`; downstream `[]`/`[…]`/concat → possible-nil. The single largest *driver* of the 180 possible-nil errors | **very high** (every parser in the tree — erb, csv, uri, resolv, optparse, mkmf) | mechanism | yes | engine — global-var flow typing + post-`=~` narrowing |
| **C2. Cross-method ivar state-join → `Dynamic[top]`/nil-union** | an ivar written in N methods with differing types joins to a widened union; reads in a third method fall to Dynamic-or-nil (ipaddr `@mask_addr`, uri/ldap accessors). Surfaces as arg-mismatch (`^`), return-mismatch, possible-nil | **very high** | mechanism | mostly (some surface genuine heterogeneity, cf. specification `@new_platform`) | engine — ivar declared-type inference / write-join precision |
| **C3. Hash/Array `[]` lookup returns `V?` consumed without guard** | `h[k].foo`, `opts[k]=…` where the receiver itself came from a `T?` source; resolv/open3 `[]`/`[]=` | high | mechanism | yes | mostly genuine-conservative (lookups *can* miss); precision win where the key is provably present |
| **C4. `def self.x` module-singleton calls (queued gap)** | measured radius here: module_function / `def self.` helpers called within the same module type their result via singleton dispatch; many resolve, but cross-`def self` chains still fall. Smaller-than-expected radius in this corpus (stdlib leans on instance methods + mixins) | medium | mechanism | yes | engine — known queued (ADR-57 "module-singleton resolution" follow-up) |
| **C5. Loop/block plain-local *reassignment* write-back** | `x = nil; arr.each{ x = $1; break }; x` reads pre-loop `nil` → `always-falsey`. Distinct from ADR-56 slice A (that covered *captured-local mutation* `x << …`); a plain rebind inside a non-escaping block isn't joined back here | medium-high | mechanism | yes (removes FP) | engine — extend ADR-56 write-back to bare rebind-in-block |
| **C6. No-RBS library → inferred sigs too strict** | Resolv (LOC::Size/Coord, Sender, Requester), parts of prism translation. Inferred param/return types reject valid args | medium | needs-RBS | n/a | not an engine bug — RBS-authoring / inference precision on no-RBS libs |
| **C7. Destructured params `((a,b))` / `def f(a,(b,c))`** | CRASH today (C-1 below); once fixed, the destructured names also need element-type binding | low (rare in stdlib — 1 file) | mechanism | n/a (crash → must fix) | engine bug (crash) |
| C8. C-extension boundary (no Ruby body) | socket/IO/prism-FFI methods defined in C — no body to infer | n/a | expected-boundary | n/a | **expected boundary — not a bug** (resolve via RBS) |
| C9. `Object#untaint` & friends removed in Ruby ≥3.2 | dead refs in stdlib | trivial | n/a | n/a | **genuine catch — leave as-is** |

## Highlighted WRONG / unsound finds

- **No new *unsound wrong-fold* (like the old B1 `x.zero? → true`) was
  found** — the ADR-56 slice-C content-join + ADR-57 adoption gate appear
  to have closed the soundness hole the prior probe survey flagged.
- **Two hard engine bugs, both FP/crash not unsound:**
  1. `Prism::MultiTargetNode` crash (`method_parameter_binder.rb:115`) —
     aborts all of `sig-gen` on any file with a destructured positional
     param; recoverable-but-noisy in `check`. **Top priority (crash).**
  2. `Struct.new(:x).new(…)` chained → `undefined method 'new' for
     Struct` — a precision/dispatch artifact firing a spurious error on a
     ubiquitous idiom.

## Ranked attack order

1. **C-1 (crash): `Prism::MultiTargetNode` in `positional_slots`.**
   `method_parameter_binder.rb:115`+`:119` must handle a destructured
   `requireds`/`posts` entry (recurse into `MultiTargetNode.lefts/rest`
   or bind a synthetic slot) instead of blind `.name`. Engine bug; fixes
   the sole crash + un-bricks `sig-gen` on real code. Smallest, highest
   urgency.
2. **C-2 (FP): chained `Struct.new(:x).new`.** Make the `Struct.new(...)`
   result type carry `.new` dispatch in chained position (it already
   does when bound to a constant). Engine artifact; kills 3+ stdlib
   errors and a very common gem idiom. (ADR-48 deferred Struct *folding*;
   this is narrower — just `.new` dispatch on the synthesized class.)
3. **C1 (FP-class, highest radius): regex-global nil-union + post-`=~`
   narrowing.** Single biggest driver of the 180 possible-nil errors.
   Either type `$1`/`$~`/`$+` more precisely in the matched branch, or
   narrow them after a successful `=~`/`match`/`scan` guard. Engine —
   precision-additive, FP-reducing.
4. **C2 (FP-class): cross-method ivar state-join precision.** Drives the
   ipaddr `^` arg-mismatches and the uri/ldap return-mismatches. Tighten
   ivar declared-type inference so a multi-writer ivar doesn't collapse
   to `Dynamic[top]\|…\|nil` when the writes are homogeneous. Engine,
   precision-additive.
5. **C5 (FP-class): loop/block plain-local rebind write-back.** Extend
   the ADR-56 write-back from captured-local *mutation* to bare
   *reassignment* inside a non-escaping block/loop; removes the
   `always-falsey`-on-`caller_gem` FP class.
6. **C4 (Dynamic, medium radius): `def self.x` module-singleton call
   resolution** — already the queued ADR-57 follow-up; this corpus
   confirms a *medium* (not huge) radius for stdlib.
7. **C6/C8/C9: NOT engine bugs.** C6 (Resolv et al.) = ship/author RBS;
   C8 (C-extension methods) = expected boundary, resolve via RBS; C9
   (`untaint`) = genuine catch, leave firing.

Soundness-first ordering is moot this round — no unsound fold survived.
So the order is: **crash (C-1) → FP-on-ubiquitous-idiom (C-2 Struct) →
high-radius FP mechanisms (C1 globals, C2 ivar, C5 loop-rebind) →
Dynamic-precision (C4) → needs-RBS / boundary (C6/C8/C9)**.

## Residual adjudication (post-fix wave 1) — 2026-06-12

Re-run after the three wave-1 fixes landed (`e88651c4`
MultiTargetNode destructure crash, `fd4ebd50` chained `Struct.new(:a).new`,
`0cfa4f55` regex match-data global narrowing on proven-match edges). Same
command, same READ-ONLY tree. **Wall 333s, 495 diagnostics, 308 errors**
(313 → 308). The crash and the `Struct.new` artifact are both gone from
the diagnostic stream; the count barely moved because **C1 did not have
the FP surface the original survey attributed to it** — see below.

### Bucket table (308 errors)

| Rule | ALL | pure-stdlib | vendored |
| --- | --- | --- | --- |
| `call.possible-nil-receiver` | 179 | 95 | 84 |
| `call.undefined-method` | 79 | 49 | 30 |
| `call.argument-type-mismatch` | 37 | 35 | 2 |
| `call.wrong-arity` | 13 | 9 | 4 |
| **total errors** | **308** | **188** | **120** |

Warnings (185) unchanged in shape: `flow.always-truthy-condition` 84,
`def.return-type-mismatch` 47, `call.unresolved-toplevel` 23, the rest
override-conformance. (vendored = `lib/bundler/vendor/**` + `lib/rubygems/**`.)

possible-nil by receiver source (95 pure sites, hand-classified from source):

| Receiver source | ~count | Dominant files |
| --- | --- | --- |
| Hash/Array `[]`/`pop`/`delete` lookup result (C3) | ~40 | open3 `opts` (12), resolv `config_hash` (12) |
| local nil-union from `case`/`begin`-rescue join | ~20 | resolv, prism/translation/parser, time, ipaddr |
| method-return-chain `T?` then bare call | ~18 | open-uri, uri/generic, net/* |
| ivar nil-union (C2) | ~8 | net/protocol, uri |
| `&.`-guarded then bare-read in `&&` rhs | ~4 | uri/generic |
| **regex global (`$1`,`$~`,…)** | **1** | erb/compiler (and even that is `comment[…]`, a local — *not* `$1`) |
| other | ~4 | — |

### Step 2 — why C1 narrowing yielded almost nothing

**The C1 premise was a measurement artifact in the original survey.** The
survey attributed ~180 possible-nil errors to "regex globals typed
nil-union." That is false on this engine:

- An **unseeded** match-data global read (`$1`, `$~`, `$&`) types as
  `Dynamic[top]`, **not** `String | nil` (`ExpressionTyper#type_of_global_variable_read`
  → `scope.global(name) || dynamic_top`). The only writers of `@globals`
  are explicit `$x = …` assignment, `program_globals` seeding (which only
  collects `GlobalVariableWriteNode` targets — *not* the perlish match
  globals), and the narrowing edges themselves. **No call writes the
  match-data globals as a side effect**, so a bare `str =~ re; $1.foo`
  reads `$1` as `Dynamic` → `possible-nil` never fires on it. The
  `scope.rb` `forget_match_globals` comment ("falls back to the default
  `String | nil`") is *inaccurate* — it falls back to `Dynamic[top]`.

- Sampled the residual possible-nil sites across erb, time, ipaddr,
  resolv, uri, optparse, mkmf, open3, net/* — and **exactly one of 95**
  touches a `$N`, and there the nil receiver is a *local* (`comment`), not
  the global. The corpus has essentially zero "regex-global possible-nil"
  FPs for C1 to remove. C1 is therefore **precision-additive on a shape
  the corpus does not exercise as an FP** — correct work, mismeasured radius.

- The `0cfa4f55` invalidation gate (`forget_match_globals` after any
  match-capable / implicit-self call, with `match_capable_call?` returning
  true for `=~ match [] split index === …` and *every* receiver-less call)
  *is* as aggressive as hypothesized — e.g. in time.rb `if /…/ =~ s; ($1
  == '-' ? …) * ($2.to_i …)` the `$1 == '-'` (`==` ∈ MATCH_CAPABLE) clobbers
  every global before `$2.to_i`. **But the clobber is harmless**: the
  forgotten global reverts to `Dynamic[top]`, which fires no diagnostic.
  So the over-aggressive gate costs precision (Dynamic, not String), never
  an FP. Quantified clobber-on-real-bodies: the `== / [] / split` family
  appears between guard and read in the majority of the multi-statement
  date-parser bodies (time.rb, resolv.rb), but with zero FP consequence.

C1 shape breakdown (the (a)/(b)/(c)/(d) classification asked for, applied
to the *would-be* regex-global sites — all of which currently read Dynamic):

- (a) engine-gap shapes that *would* matter if globals were seeded
  `String | nil`: the dominant missing narrowing is **`.match` /
  `str.match(re)` is not a narrowing predicate** — only `=~` is in
  `simple_dispatch_name?`; `String#match` / `Regexp#match` set `$~` at
  runtime but neither narrows the globals nor the returned MatchData. Also
  missing: `if md = re.match(s)` narrows `md` (local-write truthy) but not
  the globals, and `scan(re){ … $1 }` block bodies get no edge. These are
  real gaps but **demand-gated to near-zero** because the globals are
  Dynamic, so closing them yields precision not FP-reduction.
- (b) cross-method (match in one method, `$1` read in another): not
  observed as an FP for the same Dynamic reason.
- (c) optional/alternation groups correctly stay nilable in the walker
  (`unconditional_capture_groups`) — verified, no over-promotion.
- (d) the real possible-nil driver is **not** globals at all (see Step 3).

**Verdict on C1: keep the landed narrowing (it is sound and additive), but
drop it from the FP-attack ranking — its FP radius on real code is ~0.**
The 180-error figure in the original Instrument-1 row conflated "regex
parsers carry nil-unions" (true, but the nil is in *locals/ivars/lookup
results*, not the globals) with "the globals are nil-typed" (false).

### Step 3 — the real possible-nil drivers (next-slice material)

Sampled and root-caused the two largest *repeatable* clusters plus the
non-regex mechanisms:

1. **`case … when … else raise` exhaustion not credited (NEW dominant
   gap).** `eval_case` joins `[*branch_results, else_result]` via
   `reduce_scopes_with_nil_injection`; when the `else` clause *terminates*
   (`raise`/`return`/`throw`) the join still folds in the else/no-match
   scope, where a local assigned only inside the `when` branches is
   un-bound → nil-injected. Minimal repro (`/tmp/probe3.rb`): `case info;
   when nil then h={…}; when String then h={…}; when Hash then h=info.dup;
   else raise; end; h.include?(:a)` → **`possible nil receiver`** (FP).
   Control: `else h = {}` (assigns) is clean; no-else is correctly nilable.
   This is the resolv `config_hash` cluster (**12 sites**) verbatim, and
   recurs elsewhere. Engine fix is the exact `branch_terminates?` pattern
   already used in `eval_if`/`eval_unless`: in `eval_case`
   (`statement_evaluator.rb:535`) drop the else_result scope from the join
   when the else clause terminates. **FP-safe, low difficulty, ~12+ sites.**

2. **`opts = (cond ? cmd.pop.dup : {})` — `Array#pop` nil leaks through
   `.dup` into a both-branches-Hash join.** open3 `opts` cluster (**12
   sites**, `[]=`/`delete`). `if Hash === cmd.last; opts = cmd.pop.dup;
   else opts = {}; end` → `opts : Hash | nil` because `cmd.pop` is `T?` and
   `.dup` preserves nil; the `Hash === cmd.last` guard does not narrow the
   *separate* `cmd.pop` call. Genuine-conservative at the type level (pop
   *can* be nil) but the guard makes it unreachable. Fix needs either
   `x === y` ⟹ aliasing-narrow of the receiver's element, or
   special-casing `Array#pop` under a proven-non-empty guard — **higher
   difficulty, aliasing-sensitive, medium FP risk.** Deprioritize.

3. **`&.`-guarded receiver not known-non-nil in the `&&` rhs.** uri/generic
   `v&.start_with?('[') && v.end_with?(']')` — the `&&` right operand
   executes only when `v&.start_with?` was truthy, which implies `v`
   non-nil, but `v.end_with?` still sees `v : String | nil`. ~4 sites.
   Engine-fixable in `analyse_and` (the left operand's `&.`-safe-nav
   truthy edge should narrow the receiver non-nil for the right operand),
   **FP-safe, low-medium difficulty, small radius.**

4. **`until idx = expr; …; end; idx.foo` loop-exit non-nil.** net/protocol
   `until idx = @rbuf.index(term); …; end; rbuf_consume(idx + …)`. The
   loop exits precisely when `idx` is truthy, so post-loop `idx` is
   non-nil; the engine keeps the loop-body nil-union. Note: the *isolated*
   probe (`/tmp/probe2.rb`) passes — reproduces only in the full method
   context, so it is entangled with the per-iteration scope join, not a
   standalone narrowing miss. Medium difficulty, FP-safe, ~3–4 sites.

Non-regex bucket verdicts (Step 3 of the brief):

- **C2 ivar state-join (`argument-type-mismatch ^` on ipaddr, 6 sites;
  uri/ldap `def.return-type-mismatch`).** Multi-writer ivar
  (`@mask_addr`) joins to `Dynamic[top] | Integer | nil`; `Integer#^`
  rejects. Engine-fixable by tightening ivar declared-type inference so
  homogeneous writes don't collapse to Dynamic; **medium difficulty**, the
  uri/ldap return-mismatches (47-wide `def.return-type-mismatch` bucket)
  ride the same mechanism, so the radius is larger than the 6 `^` sites.
  Some genuinely-heterogeneous writers (specification `@new_platform`)
  must stay flagged — fix must preserve those.
- **C6 no-RBS strict sigs (Resolv LOC::Size/Coord/Alt, DNS Requester;
  ~10 of the 37 arg-mismatch).** Inferred param types reject valid args on
  a library that ships no RBS. **Not an engine bug** — author RBS or
  improve inference precision on no-RBS libs. Leave.
- **`call.undefined-method` (49 pure).** Long tail by receiver class:
  `String` (6, incl. the `untaint` genuine catch C9), Gem::* / Bundler::*
  (project-internal classes Rigor types partially → inherited-method
  resolution gaps, ADR-43 territory), URI/OpenURI (mixin/`method_missing`
  delegation). Mostly **needs-RBS / genuine-conservative**, not a single
  mechanism; no concentrated engine slice here.
- **C5 always-truthy `$extmk` (mkmf, 18 of 45 pure always-truthy).** Not a
  loop-rebind — it is **program-global constant-fold over-eagerness**: a
  top-level `$extmk = nil`/truthy seed makes `if $extmk` always-truthy
  inside every method body, ignoring external/late reassignment.
  **FP-risky to "fix"** (the seed IS the only visible value); the right
  move is to NOT constant-fold a mutable program-global's truthiness
  inside method bodies (widen `$global` reads in method scope to the
  union of all seen writes incl. an unknown-write floor). Medium, must be
  FP-validated against Mastodon/haml. Lower priority.

### Ranked next-slice list

| # | Slice | Mechanism / rigor anchor | Expected yield | FP risk |
| --- | --- | --- | --- | --- |
| 1 | **`case`/`else`-terminates exhaustion** | drop terminating `else` scope from the join in `eval_case` (`lib/rigor/inference/statement_evaluator.rb:535`), reusing `branch_terminates?` as in `eval_if` | ~12 resolv + scattered = **~15 errors** | **low** (mirror of shipped if-guard logic) |
| 2 | **C2 ivar homogeneous-write declared-type** | tighten ivar write-join so same-typed multi-writer ivars don't collapse to `Dynamic[top]` (ivar declared-type inference; `class_ivars_for` seed + write-join) | ipaddr `^` (6) + a slice of the 47 uri/ldap `def.return-type-mismatch` = **~15–25** | medium (must keep genuinely-heterogeneous writers flagged) |
| 3 | **`&.`-truthy narrows `&&` rhs receiver** | in `analyse_and` (`narrowing.rb`), the left `recv&.pred` truthy edge narrows `recv` non-nil for the right operand | uri/generic = **~4** | low (narrowing-only) |
| 4 | **`until/while x = expr` loop-exit non-nil** | post-loop scope narrows the loop-condition assignment-target non-nil on the truthy-exit edge (`eval_loop` join) | net/protocol etc. = **~4** | low–medium (entangled with loop-scope join; probe in full-method context) |
| 5 | **`.match` as a narrowing predicate (C1 follow-up)** | add `String#match`/`Regexp#match`/`if md = re.match(s)` global+local narrowing to `simple_dispatch_name?` / `analyse_call` | **precision only** (globals read Dynamic → ~0 FP today) | low — but **demand-gated; not FP-reducing on this corpus** |
| 6 | **program-global truthiness widening (C5 `$extmk`)** | stop constant-folding a mutable program-global's truthiness inside method bodies (`flow.always-truthy` on `if $g`) | mkmf 18 + scattered = **~25 warnings** | medium–high (FP-validate vs Mastodon/haml first) |

**Not engine work:** C6 (Resolv no-RBS), the open3 `cmd.pop.dup` cluster
(genuine `Array#pop` nilability; aliasing fix is high-cost/medium-risk —
explicitly *not* slated), the `undefined-method` long tail (needs-RBS /
ADR-43 inherited-resolution), C9 `untaint` (genuine catch).

**Headline correction for the campaign:** C1 (regex globals) was the
top-ranked FP mechanism in the original survey but has **~0 FP radius** on
real stdlib — match-data globals read `Dynamic`, never `nil`. The actual
dominant, cleanly-fixable possible-nil mechanism is **`case/else-raise`
exhaustion** (slice 1), which the original survey did not isolate.
