# textbringer type-coverage survey — invalid bundled `sig/`, and the namespace-synthesis fix

**Date:** 2026-06-01.
**Subject:** [textbringer](https://github.com/shugo/textbringer) v26 (terminal
text editor by Shugo Maeda), shallow-cloned to
`~/repo/ruby/rigor-survey/textbringer/` at commit `3f6b0d2` (2026-05-25).
**Why:** Coverage-investigation survey target. textbringer is unusual in the
corpus — a mature **plain-Ruby** application that *ships its own handwritten
RBS* (`sig/lib/textbringer/**.rbs`, 52 files). That makes it the natural place
to ask: does wiring a project's own `sig/` into `signature_paths:` lift the
`rigor coverage` precision number? The first answer was a clean "no" (§3) — but
the deeper investigation (§4) found the real reason: textbringer's `sig/` is
**invalid RBS** (`rbs validate` rejects it; missing namespace declarations), so
it was inert for every consumer, and Rigor swallowed the build error silently.
The fix — synthesizing the missing namespaces (commit `1529b54d`) — turns the
"no" into **+9.6pt coverage** (40.3% → 49.9%), and three further levers (§5)
carry it to **65.0%**. §3 is kept as the investigation record; its mechanistic
conclusion is superseded by §4.

All numbers below are from the rigor repo's Flake bundle, run with
`cwd = the target` + `BUNDLE_GEMFILE=<rigor>/Gemfile` per
[[reference_survey_external_projects]].

---

## 0. Onboarding (rigor-project-init, acknowledge mode)

Followed the `rigor-project-init` workflow end to end:

- **Phase 1 (detect):** plain-Ruby gem (`gemspec`-driven Gemfile, no
  Rails/Sinatra/dry-rb/Sorbet markers). test-unit suite under `test/`. No
  `Gemfile.lock`, no `rbs_collection.lock.yaml`. Ships a handwritten `sig/`.
- **Phase 2 (mode):** first `rigor check` reported **45 errors** (< 100) →
  acknowledge mode, `balanced` (default) severity.
- **Phase 3 (plugins):** none — plain Ruby; the core analyzer covers it.
- **Phase 4 (config):** `.rigor.dist.yml` with `paths: [lib]`,
  `target_ruby: "3.3"` (the gemspec floor is 3.2, but Prism 1.8 dropped the
  3.2 grammar — 3.3 is the oldest supported and a parsing superset), and
  `signature_paths: [sig]` to consume the bundled RBS (Rigor does **not**
  auto-detect `sig/`). `rigor plugins` → `loaded: 0  load-error: 0` (correct
  for plain Ruby).
- **Phase 6 (triage):** see §2.
- **Phase 7 (baseline):** `rigor baseline generate` → 29 buckets / 74
  diagnostics, wired `baseline: .rigor-baseline.yml`. Re-check → **No
  diagnostics** (envelope holds).

`target_ruby` gotcha worth recording: the config layer accepts a loose
`"3.2"` form, but it is passed verbatim to `Prism.parse(version:)`, and Prism
1.8.1 raises `invalid version: 3.2` (it ships only 3.3.0 / 3.4.0 / latest).
`rigor coverage` surfaces this as a hard crash, not a diagnostic.

---

## 1. Cold coverage baseline

`rigor coverage lib` over 77 files, 0 parse errors:

| metric | value |
| --- | --- |
| expressions typed | 47,601 |
| **precise** | **19,173 (40.3%)** |
| dynamic (opaque) | 28,428 (59.7%) |

Tier breakdown: constant 27.0%, nominal 8.1%, shaped 3.7%, refined 0.1%, bot
1.5%, dynamic-opaque 59.7%. **Constant folding alone is ~2/3 of all precise
expressions** — a literal-driven profile. Per-file spread: low ~20%
(`commands/rectangle.rb`), themes cluster ~50% (constant colour tables), heavy
files `buffer.rb` 31.8%, `window.rb` 26.8%, `skk_input_method.rb` 56.6%.

---

## 2. `rigor check` / `rigor triage` (cold, pre-baseline)

74 diagnostics (45 error / 29 warning). Distribution:
`call.undefined-method` 28, `flow.always-truthy-condition` 24,
`call.possible-nil-receiver` 13, `call.argument-type-mismatch` 4,
`call.unresolved-toplevel` 4, `def.return-type-mismatch` 1.

Triage hints (no config-gap hints — no `activesupport-core-ext` /
`gem-without-rbs`, so the baseline ran against the real set):

- **`systemic-file-cluster`** — 9 `call.undefined-method` in
  `lsp/client.rb` (the `@io` / `@wait_thread` reads typed worst-case nil:
  `alive?`/`read`/`read_nonblock`/`close` "for nil"). One structural cause.
- **`unresolved-toplevel` (4)** — `window.rb` uses a refinement
  (`using` / `refine` / `attrset`) the analyzer can't follow from the toplevel
  call; candidate for `pre_eval:` (ADR-17) if pursued.
- **`genuine-bugs` (5)** — the localised review pile:
  - `floating_window.rb:158/183/194/215` — `<` / `>` on `Integer` with RHS
    `Dynamic[top] | nil` (×4). A width/height ivar that is nil-typed at the
    comparison.
  - `keymap.rb:2` — `define_keymap` declared `-> Textbringer::Keymap` but
    inferred `Dynamic[top] | nil` (return-type mismatch).
  - plus the `tetris_mode.rb` `set_cell`/`render`/`start_timer` "for nil"
    cluster (the `@gamegrid` ivar) — worst-case-sound nil reads on a
    gamegrid that the code initialises before use.

Per [[feedback_false_positive_discipline]], the ivar-nil clusters are
worst-case-sound static reads on working code → honest baseline material, not
force-fixed. They are now in the envelope; `rigor-baseline-reduce` is the
follow-up if the project wants them driven down.

---

## 3. The headline finding — bundled `sig/` lifts `rigor coverage` by **0**

> **⚠️ Superseded by §4 (2026-06-01 resolution pass).** The *observation*
> below (sig wiring lifted coverage by 0) is real, but the **mechanism this
> section infers is wrong**. The true root cause was not "the scanner doesn't
> seed `self`/ivar/param" — it was that textbringer's RBS *never built at all*
> (missing-namespace `NoTypeFoundError`), so no project method resolved on any
> receiver. Once that is fixed, `self`-receiver calls **do** resolve. Read §4
> for the corrected account; §3 is kept as the investigation record.

Re-running `rigor coverage lib` with `signature_paths: [sig]` active produced
numbers **identical to the byte** (40.3% precise, every tier count unchanged).
`rigor check` clearly *does* consume the RBS — stderr reports `project sig/:
47` loaded, and diagnostics reference declared types (`define_keymap` →
declared `Textbringer::Keymap`). So this is not "check ignores the RBS."

### Why — proven, not assumed

`rigor coverage` runs `Inference::PrecisionScanner`, a **lightweight per-node
`Scope#type_of` scan** over a `ScopeIndexer`-built scope chain — *not* the full
`Analysis::Runner` flow pass with the fact store. Two minimal probes pin the
mechanism (both run with/without `signature_paths: [sig]`):

**Probe A — receiver gets a nominal type from `.new`:**
```ruby
b = Textbringer::Buffer.new
n = b.point_min                       # RBS: () -> Integer
s = Textbringer::Buffer.new_buffer_name("foo")   # RBS: (String) -> String
```
→ **6.7% precise without sig → 40.0% with sig** (+5 nominal). Coverage *is*
RBS-aware.

**Probe B — receiver is `self` / `@ivar` / a method parameter:**
```ruby
class Textbringer::Buffer
  def demo
    a = point_min        # implicit-self receiver
    b = self.point_min   # explicit self
    c = goto_char(a)     # self receiver
  end
  def demo_ivar;  @buf.point_min; end   # ivar receiver
  def demo_param(buf); buf.point_min; end  # param receiver
end
```
→ **42.4% precise with and without sig — identical.** Zero lift.

### Conclusion

`rigor coverage` credits an RBS method-return type **only when the call-site
receiver already carries a nominal type** within the per-node scan. The
precision scanner does not seed receiver types for the three receivers that
dominate idiomatic OO Ruby — **implicit/explicit `self`, instance variables,
and method parameters** — so the bundled RBS, however accurate, has almost no
typed receiver to attach to in real method bodies. textbringer's `lib/` is
almost entirely such call sites, hence the byte-identical result.

Note this even covers **`self`-receiver** calls: ADR-24 (implicit-self method
resolution) and ADR-35 return-checking apply on the full checker path, but the
`coverage` precision scanner does not type `self` from the enclosing method's
class, so even `point_min` called bare inside `Buffer#demo` stays opaque.

### Takeaways

1. **`rigor coverage` understates RBS value on OO codebases.** The metric is a
   reasonable proxy for *constant-fold + locally-inferable* precision, but it
   is close to insensitive to a project's own handwritten/SIG-gen'd RBS,
   because RBS pays off at typed-receiver call sites the per-node scan rarely
   establishes. The 40.3% headline is best read as a constant-fold-dominated
   floor, not a verdict on the RBS.
2. **Do not present "sig/ changed nothing" as "the RBS is worthless."** The
   checker uses it; the coverage *metric* just doesn't see it. Keep the two
   surfaces distinct when reporting survey numbers.
3. **Possible engine follow-up (not filed):** if `coverage` is meant to track
   the impact of adding RBS, the precision scanner could seed `self` from the
   enclosing class and ivar/param types from in-scope RBS. That would make the
   metric move when a project's RBS coverage grows — currently it does not.
   Filed here as an observation, not a change request; weigh against the cost
   of giving the lightweight scan a heavier inference path.

---

## 4. Resolution pass (2026-06-01) — the real root cause and the fix

§3 stopped one layer too shallow. Pushing the probes down with `rigor type-of`
and a direct `Reflection.instance_method_definition` query revealed the actual
mechanism:

- `self` inside `Buffer#demo` **does** type as `Textbringer::Buffer`
  (`ScopeIndexer` seeds `self_type` correctly), and the dispatcher *does* route
  `Nominal` receivers through `RbsDispatch` unconditionally. So §3's "the
  scanner doesn't seed `self`" was wrong.
- Yet `b.point_min` returned `Dynamic[top]` **even with `b` typed as
  `Textbringer::Buffer`** — and so did the stdlib-on-nominal cases until I
  isolated them. The discriminator was not self-vs-explicit receiver; it was
  **stdlib-RBS vs project-RBS**.
- `Reflection.instance_method_definition("Textbringer::Buffer", :point_min)`
  returned `nil`. The cause: `RBS::DefinitionBuilder#build_instance` raised
  **`RBS::NoTypeFoundError: Could not find ::Textbringer`**, which the loader's
  fail-soft `rescue ::RBS::BaseError` swallowed to `nil`. textbringer's `sig/`
  declares `class Textbringer::Buffer` (and 50 siblings) but **never declares
  `module Textbringer`** — so the namespace is absent from `class_decls` and
  every definition build fails. `rbs validate` rejects the same files with the
  identical error: textbringer's committed RBS is **invalid upstream**, inert
  for *any* RBS consumer (Steep included), not just Rigor.

So the §3 probes were all measuring "no project RBS method resolves on any
receiver." Probe A's +5 nominal came from `Buffer.new` → `Nominal[Buffer]` and
the `b` reads (singleton/`.new` handling), **not** from `point_min`/
`new_buffer_name` returns; probe B was identical because, again, nothing
resolved. The receiver-kind framing was an artifact of the build failure.

### The fix (landed)

`RbsLoader.build_env_for` now **synthesizes an empty `module` for each
undeclared enclosing namespace** before `resolve_type_names` (ADR-5 robustness —
lenient on inputs; commit `1529b54d`). Only absent names are added, so it is a
no-op for well-formed sig sets. With it:

| run | precise | nominal tier |
| --- | --- | --- |
| cold (sig inert) | 40.3% | 8.1% |
| **sig live (post-fix)** | **49.9%** (+9.6pt) | **15.0%** |

`self.point_min` / bare `point_min` now resolve to `Integer`. A new
`rbs.coverage.synthesized-namespace` `:info` diagnostic names the synthesized
namespaces (`Textbringer`, `Textbringer::LSP`) so the user learns the RBS is
malformed and can declare them at the source.

### Corrected takeaways

1. **The 40.3% cold number was a floor depressed by a build failure, not by a
   scanner limitation.** Project RBS *does* flow into `rigor coverage` once it
   builds; the metric is more RBS-sensitive than §3 concluded.
2. **`self`/ivar/param framing, corrected:** `self` receivers resolve (seeded +
   dispatched). Instance variables resolve only when the class-ivar index typed
   them; **method parameters** remain the genuine opaque case (untyped unless
   `--params=observed` or inline annotations give them a type) — that part of
   §3 survives.
3. **The durable lesson:** a silent `RBS::BaseError` rescue can hide a
   *total* loss of project-RBS value behind a plausible-looking partial number.
   When `signature_paths:` RBS seems to do nothing, check `rbs validate` and
   whether `build_instance` raises before theorising about the scanner.

---

## 5. Coverage-uplift arc (what raised the number, and why)

After the namespace fix, "what blocks more coverage?" was answered by bucketing
every remaining opaque node. Four levers, landed in order:

| # | Lever | `rigor coverage` | Kind |
| --- | --- | --- | --- |
| 0 | baseline (sig inert) | 40.3% | — |
| 1 | namespace synthesis (§4) | 49.9% | engine robustness |
| 2 | **exclude non-expression nodes** from the metric | **62.9%** | metric correction |
| 3 | referenced-type stub synthesis (`DRb::DRbServer`, …) | 64.3% | engine robustness |
| 4 | block→block-less overload fallback | **65.0%** | engine bug fix |

Lever 2 was the single biggest move and is **not** an inference change: the
`PrecisionScanner` had been counting `ArgumentsNode` / `ParametersNode` /
`StatementsNode` / `AssocNode` / parameter declarations — syntax with no
runtime value — as "opaque", and they were ~49% of all opaque nodes. Excluding
them makes the ratio measure expression precision, which is what it claims to.

Levers 3 + 4 together unblocked the `Textbringer::Commands` cascade: a single
unavailable `DRb::DRbServer` reference had been failing the whole module's
build (lever 3 stubs it, FP-safely), and `define_command`'s 186 block-bearing
self-sends had been degrading because the method's RBS declares no block
overload (lever 4 — a general fix, not textbringer-specific).

The remaining ~35% opaque is dominated by the **Dynamic cascade from untyped
roots** — method parameters (no types without `--params=observed` or RBS param
types) and untyped instance variables — plus RBS-less C-ext / FFI gem
dependencies (`curses`, `fiddle`). Those are the next frontier; closing them
needs parameter-type inference (deliberately deferred — measured-FP-risky) or
project-side RBS authoring, not a Rigor metric/robustness fix.

## 6. The FP twist — `attr_*` accessors with incomplete RBS

Chasing "more coverage" past §5 ran straight into the false-positive ceiling.
`Buffer#point` / `#file_name` / `#name` / `#mode` / `#keymap` are defined by
`attr_reader` / `attr_accessor` in `buffer.rb`, but textbringer's `buffer.rbs`
omits the getters (it declares only the `name=` / `file_name=` setters). Because
the in-source method scanner recorded `def` / `define_method` / `alias_method`
but **not** the `attr_*` macros — and because the discovered-method table was
per-file — every `buffer.point` call read as `call.undefined-method`: **167
false errors on textbringer's own types.** So any lever that types *more*
receivers as `Buffer` (param inference, ivar seeding) would have *multiplied*
these FPs, not produced clean coverage.

The fix (commit `1329cca7`) is therefore an FP fix, not a coverage fix: record
`attr_*` accessors as discovered methods and propagate the table project-wide
(plain `def`s stay per-file so the ADR-17 monkey-patch diagnostic is unchanged).
Textbringer-type `undefined-method` fell **167 → 30**, and the honest baseline
shrank from 328 to 187 diagnostics. Coverage stayed at 65.0% (accessor calls
resolve to `Dynamic[Top]` via the discovered-method tier — suppressing the FP,
not adding precision), which is the correct trade: **the false-positive
discipline outranks the coverage number.** The lesson for the corpus: once a
project's own types are typed, its coverage ceiling is set by the completeness
of its RBS, and pushing past it surfaces RBS-gap FPs rather than real precision.

---

## Reproduction

```sh
cd ~/repo/ruby/rigor-survey/textbringer   # commit 3f6b0d2
BUNDLE_GEMFILE=~/repo/ruby/rigor/Gemfile \
  bundle exec ~/repo/ruby/rigor/exe/rigor coverage lib --config .rigor.dist.yml
```
(inside the rigor Flake shell). Probe files in §3 are reconstructable from the
snippets above; point a throwaway config's `signature_paths:` at the
textbringer `sig/` to toggle the RBS.
