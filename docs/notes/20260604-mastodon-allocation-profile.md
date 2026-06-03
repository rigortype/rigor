# Profiling `rigor check` on Mastodon: it is allocation-bound

*2026-06-04. Profiling note — informational, not normative. The spec binds.*

## Question

Where does `rigor check` actually spend its time on a large real-world
app? Mastodon `main` (commit `d20d049`, 2026-05-26) is the largest
anchor in the survey corpus, so it is the natural target for a CPU /
allocation profile and a bottleneck ranking.

## Setup

- Target: `rigor-survey/mastodon`, `app` + `lib` = **1,303 `.rb` files**.
- Config: the tuned survey `.rigor.dist.yml` (6 Rails plugins,
  `severity_profile: lenient`).
- Invocation: `rigor check --workers 0 --no-cache` — single process (so
  the profiler sees all inference; pool mode forks past it) and cache
  disabled (so we measure real inference, not cache hits).
- Result envelope: **~30 s wall / ~28 s user CPU**, 457 diagnostics,
  peak RSS ~220 MB.

## Methodology, and a trap worth recording

There is no `stackprof` / `vernier` in the bundle. The first pass used a
home-grown sidecar thread sampling `Thread.main.backtrace_locations`.
**It lied.** It reported `File.read` at 38.7 % self-time and the project
pre-passes (`run_project_pre_passes`) at 38.7 % inclusive.

A pure-Ruby sampler thread can only run when the main thread *releases
the GVL*, which happens predominantly on GVL-releasing IO. So it
massively over-samples `File.read` and under-samples CPU-bound inference.
Deterministic counters refuted it outright:

| Measured deterministically | Value |
|---|--:|
| `File.read` (all, 2,980 calls, 8.4 MB) | **0.08 s** |
| `Prism.parse` (all, 2,607 calls, 2.0×/file) | **0.21 s** |
| pre-pass: cross-file class discovery | 0.17 s |
| pre-pass: cross-file def-index | 0.34 s |
| pre-pass: synthetic-method scan | 0.00 s |
| **all project pre-passes** | **0.51 s (1.6 % of wall)** |

Parsing and IO are noise; the two extra full parse passes in
`run_project_pre_passes` (which their own comment flags as a future
share-the-parse optimisation) cost **1.6 %**, not 39 %.

The real profile was taken with **stackprof** installed into a throwaway
`GEM_HOME=/tmp/rigor_gems` (no Gemfile edit), using `mode: :cpu`
(ITIMER_PROF — samples by CPU consumed, GVL-unbiased), cross-checked
against `GC.stat`, and attributed with `mode: :object`.

## Headline finding: allocation-bound, not parse/IO/compute-bound

The engine allocates **87.8 M objects** for 1,303 files — **~67,000
objects per file**. The memory subsystem, not any inference hot loop,
dominates CPU.

stackprof `:cpu` self-time, top frames:

| self % | frame |
|--:|---|
| **49.6 %** | `(sweeping)` |
| **5.9 %** | `(marking)` |
| 1.2 % | `(garbage collection)` |
| 1.5 % | `MethodDispatcher.dispatch_precise_tiers` |
| 1.4 % | `CallContext.build` |
| 1.2 % | `Scope#rebuild` |
| 0.9 % | `Scope#initialize` |
| 0.9 % | `ExpressionTyper#type_of` |

GC machinery is **≈57 %** of CPU samples. No single piece of Rigor logic
exceeds 1.5 %: the inference cost is spread thin across `expression_typer`
(5.3 %), `scope` (3.7 %), `method_dispatcher` (3.5 %), `statement_evaluator`
(2.4 %). **There is no hot loop to optimise — there is an allocation
volume to cut.**

### Reconciling 57 % (stackprof) with 9.7 % (GC.stat)

`GC.stat[:time]` reports only **2.93 s (9.7 % of wall)** of discrete
stop-the-world GC pauses (248 runs, 8 major). That is not a
contradiction: Ruby's **lazy incremental sweep** runs a little on *every
allocation*, fused into the allocation path rather than counted as a GC
pause. stackprof catches the IP inside `gc_sweep_step` constantly; the
clock attributes it to allocation. Both numbers are true; they measure
different things.

The decisive test: re-running with a roomy heap
(`RUBY_GC_HEAP_INIT_SLOTS=4M`, raised `MALLOC_LIMIT*`) gave **zero
improvement** (30.22 s → 29.49 s, within noise) and *more* GC runs, not
fewer pauses. The cost scales with allocation **volume**, not GC
**frequency**. GC tuning is not the lever; allocating less is.

## Allocation attribution (stackprof `:object`)

1,755,722 sampled allocations × interval 50 ≈ 87.8 M (matches `GC.stat`).
Top self-allocation sites:

| alloc % | site |
|--:|---|
| **10.9 %** | `String#split` (overall #1) |
| **9.8 %** | **`ExpressionTyper#resolve_ancestor_class_name`** (top Rigor site) |
| 4.1 % | `Array#join` |
| 3.9 % | `Array#[]` |
| 3.4 % | `RBS::TypeName.parse` |
| 3.0 % | `Scope#rebuild` |
| 2.8 % | `Hash#keys` |
| 2.7 % | `Data#initialize` |
| 2.5 % | `String#rpartition` |
| 2.1 % + 2.1 % | `CallContext.new` + `CallContext.build` |
| 1.8 % | `String#delete_prefix` |

By file: `expression_typer.rb` 14.2 %, `scope.rb` 7.8 %,
`prism/node.rb` 5.9 %, `rbs/type_name.rb` 3.7 %, `combinator.rb` 3.4 %.

### Root cause of the #1/#2 cluster: qualified-name string churn

`ExpressionTyper#resolve_ancestor_class_name`
([`expression_typer.rb:1400`](../../lib/rigor/inference/expression_typer.rb)):

```ruby
def resolve_ancestor_class_name(subclass_qualified, raw_superclass)
  segments = subclass_qualified.split("::")
  (segments.length - 1).downto(0) do |i|
    candidate = (segments[0, i] + [raw_superclass]).join("::")
    return candidate if known_user_class?(candidate)
  end
  nil
end
```

It `split`s and re-`join`s qualified constant names from scratch on every
call. It is driven by `enqueue_ancestors` → `resolve_user_def_through_
ancestors`, i.e. invoked **once per method-call-site dispatch** during the
ancestor BFS walk — yet the inputs it walks (`discovered_superclasses`,
`discovered_includes`, `discovered_def_nodes`) are **frozen project-wide
for the entire run** (built once in `run_project_pre_passes`). The same
`(subclass, raw_superclass)` pairs, and the same `(class, method)`
resolutions, are recomputed thousands of times. The string family
(`split` 10.9 %, `join` 4.1 %, `rpartition` 2.5 %, `delete_prefix` 1.8 %,
`RBS::TypeName.parse` 3.4 %) is largely this path plus repeated type-name
re-parsing.

The secondary cluster is structural: `Scope` is an immutable ~20-field
value object that `rebuild`s in full on every narrowing/binding change
(3.0 % alloc), and `CallContext` is a `Data` constructed per dispatch
(4.2 % alloc).

## Bottleneck ranking and recommendations

1. **Memoise the ancestor/name resolution** —
   `resolve_ancestor_class_name`, `resolve_user_def_through_ancestors`,
   `enqueue_ancestors`, keyed on the frozen project indexes. Pure
   functions of immutable state; **no behaviour change**, and it targets
   the single largest fixable allocator (~10–15 % of all allocations).
   Highest leverage, lowest risk.
2. **Intern `RBS::TypeName.parse` / `RbsLoader#parse_type_name`** results
   — the same type-name strings are re-parsed repeatedly (3.4 % + 0.9 %).
3. **Cut `Scope#rebuild` / `CallContext` allocation** — broader but more
   architectural (per-dispatch `Data`, full value-object rebuild on every
   narrow). Smaller per-fix, wide reach.
4. **Union construction** — 199,995 `Type::Union` builds, p99 arity 5,
   max 184 (6 unions ≥40). Minor for time; the fat tail is a precision
   smell worth a separate look.

`RIGOR_BUDGET_TRACE` on this run: `recursion_guard` 150,
`ancestor_walk_limit` 0, `hkt_fuel_exhausted` 0 — the silent cutoffs are
not what is costing time here (see
[`20260603-inference-budget-reality-survey.md`](20260603-inference-budget-reality-survey.md)).

## Reproduction

Inside the Flake dev shell, from the rigor checkout:

```sh
# real CPU profile (stackprof in a throwaway GEM_HOME — no Gemfile edit)
GEM_HOME=/tmp/rigor_gems gem install --no-document stackprof
env GEM_PATH=/tmp/rigor_gems:$(ruby -e 'puts Gem.path.join(":")') \
  BUNDLE_GEMFILE=$PWD/Gemfile bundle exec \
  ruby -I/tmp/rigor_gems/gems/stackprof-0.2.28/lib /tmp/rigor_stackprof.rb \
  ../rigor-survey/mastodon/app ../rigor-survey/mastodon/lib

# deterministic GC + parse/IO accounting (no profiler gem needed)
bundle exec ruby /tmp/rigor_gc.rb          ../rigor-survey/mastodon/{app,lib}
bundle exec ruby /tmp/rigor_deterministic.rb ../rigor-survey/mastodon/{app,lib}
```

The harness scripts (`rigor_stackprof.rb` object/cpu modes,
`rigor_deterministic.rb`, `rigor_gc.rb`) are throwaway instrumentation;
the repo and `Gemfile.lock` are unmodified by this work.
