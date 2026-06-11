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
