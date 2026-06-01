# textbringer type-coverage survey — and why bundled `sig/` doesn't move `rigor coverage`

**Date:** 2026-06-01.
**Subject:** [textbringer](https://github.com/shugo/textbringer) v26 (terminal
text editor by Shugo Maeda), shallow-cloned to
`~/repo/ruby/rigor-survey/textbringer/` at commit `3f6b0d2` (2026-05-25).
**Why:** Coverage-investigation survey target. textbringer is unusual in the
corpus — a mature **plain-Ruby** application that *ships its own handwritten
RBS* (`sig/lib/textbringer/**.rbs`, 52 files). That makes it the natural place
to ask: does wiring a project's own `sig/` into `signature_paths:` lift the
`rigor coverage` precision number? The answer turned out to be a clean
"no — and here is exactly why," which corrects an intermediate wrong reading.

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

## Reproduction

```sh
cd ~/repo/ruby/rigor-survey/textbringer   # commit 3f6b0d2
BUNDLE_GEMFILE=~/repo/ruby/rigor/Gemfile \
  bundle exec ~/repo/ruby/rigor/exe/rigor coverage lib --config .rigor.dist.yml
```
(inside the rigor Flake shell). Probe files in §3 are reconstructable from the
snippets above; point a throwaway config's `signature_paths:` at the
textbringer `sig/` to toggle the RBS.
