# Ractor worker pool crash — root-caused to a CRuby concurrent-Ractor use-after-free

**Date.** 2026-05-20. Investigation against `master` at `994b543`
(v0.1.7); reproduction confirmed on Ruby 4.0.4 and 4.0.5.

**Scope.** A CI run of `make verify` segfaulted inside an
[ADR-15](../adr/15-ractor-concurrency.md) Phase 4 Ractor worker-pool
worker. This note records the investigation, the confirmed root
cause, the reliable reproduction recipe, and the resulting decisions.

**Outcome.** The crash is **not a rigor bug**. It is a CRuby
memory-safety violation: under a parallel Ractor pool, a garbage-collector
sweep on one Ractor frees an object whose heap memory `rb_vm_ci_lookup`
(the runtime call-info interning path) is concurrently reading on
another Ractor — a heap-use-after-free. AddressSanitizer reproduces it
deterministically. A fix attempted in rigor (`7952ff2`) was proven
ineffective and reverted (`c3b02d3`).

**Companion artifacts.** A reproduction Docker image (sanitizer-built
Ruby 4.0.5 + the rigor bundle) and its `Dockerfile` are kept outside
the repo at `/tmp/rigor-tsan/`. The CI failure is GitHub Actions run
`26123249293`; the source it ran against is tag `v0.1.7`.

## 1. The original symptom

`make verify` on GitHub Actions (`x86_64-linux`, Ruby 4.0.4) printed
`1072 examples, 0 failures` and then crashed:

```
lib/rigor/inference/hkt_body.rb:111: [BUG] Segmentation fault at 0x000055b229d98000
ruby 4.0.4 (2026-05-12 revision b89eb1bcbf) +PRISM [x86_64-linux]
```

Ruby backtrace (a pool worker):

```
runner.rb:556  block (2 levels) in analyze_files_in_pool
worker_session.rb:118  initialize
environment.rb:279  for_project
builtins/hkt_builtins.rb:115  registry
builtins/hkt_builtins.rb:75   json_value_definition
builtins/hkt_builtins.rb:44   json_value_body_tree
inference/hkt_body_parser.rb:70 / 138 / 152 / 245 / 264
inference/hkt_body.rb:111  initialize        (a `super` call)
```

C backtrace: SIGSEGV in `vm_ci_hash` ← `do_hash` ← `rb_st_update` ←
`rb_vm_ci_lookup` (`vm_method.c:712`) ← `vm_ci_new_runtime_` ←
`vm_search_super_method` — i.e. the process-global runtime call-info
table (`vm->ci_table`).

## 2. Investigation arc

1. **First hypothesis — `vm->ci_table` interning race.** The C
   backtrace pointed at `rb_vm_ci_lookup`. A fix (`7952ff2`) pre-warmed
   the call-info table on the main Ractor before the pool spawned.
2. **Synthetic reproduction failed.** A standalone script spawning many
   Ractors that hammer `super`-heavy `Data.define` value objects did
   **not** crash — 30/30 clean on Ruby 4.0.4 darwin and arm64-linux,
   both for the shared-callinfo and the per-Ractor-unique-callinfo
   variants. The "pure `ci_table` interning race" model was incomplete.
3. **The real spec reproduces reliably.** `runner_pool_spec.rb`
   (gated behind `RIGOR_INCLUDE_RACTOR_POOL=1`; excluded from the
   default `make verify`) never passes on Ruby 4.0.5:

   | code | crash | hang | fail | ok |
   | ---- | ----- | ---- | ---- | -- |
   | pre-fix (`994b543`)        | 18 | 2 | 5  | 0 |
   | with `7952ff2` applied     | 6  | 0 | 19 | 0 |

   (25 runs each.) The fix only traded hard crashes for silent wrong
   diagnostics — worse for a type checker — so `7952ff2` was reverted
   in `c3b02d3`. The crash site varied between runs (`vm_ci_hash`,
   `fact_store.rb:27`, …), the signature of heap corruption surfacing
   wherever the next pointer dereference lands.
4. **TSAN was blind.** A ThreadSanitizer build of Ruby 4.0.5 reported
   **zero** races before the process still SIGSEGV'd. Expected: TSAN
   cannot follow Ruby 4.0's M:N thread scheduler, so its happens-before
   tracking misses Ractor races.
5. **ASAN pinned it.** An AddressSanitizer build caught the real error
   deterministically (see §3). `-fno-sanitize-address-use-after-scope`
   was needed to silence a false positive in Ruby's arm64 coroutine
   code (`coroutine_initialize` during M:N thread creation), and
   `halt_on_error=0` to step past it.

## 3. Confirmed root cause

AddressSanitizer (Ruby 4.0.5, arm64-linux, `runner_pool_spec.rb`,
3-Ractor pool):

```
ERROR: AddressSanitizer: heap-use-after-free
  READ of size 4 — rb_vm_ci_lookup        vm_method.c:699
    ← vm_ci_new_                            vm_callinfo.h:219
    ← vm_ci_new_runtime_                    vm_callinfo.h:240
    ← vm_search_super_method                vm_insnhelper.c:5152
    ← (the `super` in an hkt_body.rb Data.define #initialize)

  freed by:    GC sweep — gc_sweep_plane → rb_gc_obj_free
               → rb_data_free → ruby_xfree            (gc/default/default.c)
  allocated by: rbs_new_location2                     (rbs-4.0.2 C extension,
               ext/rbs_extension/legacy_location.c:203 — an RBS Location)
```

The same line also surfaces as `heap-buffer-overflow` — the same bug,
classified differently depending on where in the freed / reused region
the read lands.

**Mechanism.** Under a parallel Ractor pool:

1. One worker Ractor parses RBS; `rbs_extension.so` allocates many
   `Location` objects, churning the shared GC heap.
2. A GC sweep runs and frees objects.
3. Another worker Ractor executes a `super` in an `hkt_body.rb`
   `Data.define` value object → `vm_search_super_method` →
   `vm_ci_new_runtime` → **`rb_vm_ci_lookup` reads heap memory the GC
   sweep has just freed** → heap-use-after-free.

The defect is the interaction of three CRuby subsystems that are not
mutually safe under parallel Ractors (Ruby 4.0): parallel Ractor
execution, the shared GC heap / sweep, and the process-global runtime
call-info machinery (`vm->ci_table` / `rb_vm_ci_lookup`). Ruby's
contract — pure-Ruby code in Ractors is memory-safe — is violated.

It is **not fixable in rigor**: the pool merely exercises parallel
Ractors heavily (every `super` in the bundled HKT `Data.define` value
objects hits `rb_vm_ci_lookup`; RBS loading drives heavy GC churn).
Pre-warming the call-info table (`7952ff2`) cannot help — the table and
the GC heap are mutated continuously by every parallel Ractor, so no
single-threaded warm-up phase makes subsequent concurrent access safe.

## 4. Reproduction recipe

Sanitizer build (`Dockerfile` at `/tmp/rigor-tsan/`, arm64-linux):

```sh
docker build --build-arg SANITIZER=address \
  --build-arg EXTRA_CFLAGS=-fno-sanitize-address-use-after-scope \
  -t rigor-asan:4.0.5 .

docker run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  rigor-asan:4.0.5 bash -c '
    ASAN_OPTIONS="detect_leaks=0 detect_stack_use_after_return=0 \
      halt_on_error=0 abort_on_error=0 exitcode=0 log_path=/tmp/asanlog" \
    RIGOR_INCLUDE_RACTOR_POOL=1 \
    bundle exec rspec spec/rigor/analysis/runner_pool_spec.rb
    grep -l heap-use-after-free /tmp/asanlog.*'
```

The `heap-use-after-free` / `heap-buffer-overflow` report at
`rb_vm_ci_lookup` appears within a handful of runs (≈ every 2nd run).
Without a sanitizer, a bare SIGSEGV reproduces in ≈ 70 % of runs of the
same spec.

## 5. Decisions / follow-ups

- **`7952ff2` reverted** (`c3b02d3`); the CHANGELOG "Fixed" entry that
  claimed a segfault fix is removed with it.
- **File a CRuby bug** with the §3 ASAN evidence (the three-stack
  use-after-free report is far stronger than the original `[BUG]`
  dump). Reference GitHub Actions run `26123249293` and tag `v0.1.7`.
- **Gate the Ractor pool off** until CRuby is fixed. `runner_pool_spec.rb`
  is already excluded from the default `make verify`, but the pool is
  still reachable from `cli.rb`'s `--workers` / `parallel.workers:`
  surface — `cli_spec.rb` exercises it, which is how the pool ran in
  the CI job that crashed. The pool must be made unreachable (or
  hard-gated behind an explicit opt-in) until the upstream fix lands.
- ADR-15 Phase 4 (the Runner Ractor worker pool) is **blocked** on the
  upstream fix. Phases 1–3 are unaffected.
- `make verify` should be extended to cover the pool path (or the pool
  path removed from CI surface entirely) so a regression like this
  cannot reach `master` silently again.

## 6. Relation to existing Ruby tracker issues

A scan of the last ~12 months of `ractor`-tagged issues on
bugs.ruby-lang.org found **no duplicate** — no open or closed issue
names `rb_vm_ci_lookup`, the runtime call-info table, or a
GC-sweep-vs-Ractor use-after-free on the default GC. A new report is
therefore warranted. Three issues were checked in full:

- **#21200** — *Ractor spuriously hangs, segfaults or errors on
  `TestEtc#test_ractor_parallel`* (Assigned). Same **class** of bug:
  parallel Ractors producing spurious segfaults / hangs. Crash
  signatures there (`pthread_mutex_lock: EINVAL`, `SEGV at
  0xfffffffffffffff8`) differ from ours, and its root cause is
  **unidentified** — so a shared root cause can be neither confirmed
  nor ruled out. Link as a related issue.
- **#21204** — *`TestEtc#test_ractor_parallel` is still flaky with
  ModGC/MMTk* (Assigned). Same class of heap corruption
  (`malloc_consolidate(): unaligned fastbin chunk`), but the reporters
  **scoped it to the MMTk GC** ("failures only occur in the ModGC
  workflow"). Our ASAN backtrace is explicitly in `gc/default/default.c`
  — i.e. the same corruption class reproduces on the **default GC**
  too. Our report adds that data point; link as related.
- **#21999** — *Segfault / FPE with Ractor code involving BigDecimal*
  (Closed, "Third Party's Issue"). **Ruled out** — confirmed a genuine
  BigDecimal float-parsing bug, fixed in the BigDecimal repo (PR #528),
  not a Ractor-core issue. An earlier guess that it might be the same
  corruption misattributed was wrong.

Finalizer-themed issues (#21368 *Moving objects with finalizer between
Ractors crashes*, #21315 *Finalizers violate
`rb_ractor_confirm_belonging`*) are likely **distinct**: our ASAN free
path is a plain `gc_sweep_plane` → `rb_data_free`, with no finalizer
involved.

The new report links #21200 and #21204 as "Related issues" and frames
its unique contribution as the precise manifestation point — a
`heap-use-after-free` at `rb_vm_ci_lookup` on the **default GC**, with
a full three-stack ASAN trace.

## 7. Notes for a returning implementer

- TSAN is not a usable tool here — Ruby's M:N scheduler defeats its
  thread tracking. Use ASAN; disable use-after-scope instrumentation
  to get past the benign arm64 coroutine false positive.
- The synthetic `super`-spam reproduction is a dead end — the bug needs
  the real workload's GC pressure (RBS `Location` allocation churn)
  interleaved with the `super` / `rb_vm_ci_lookup` path. A minimal
  standalone reproduction has not been isolated; the rigor pool spec
  under ASAN is the working reproduction.
- The sequential analysis path is unaffected and remains correct; only
  `workers > 0` (pool) mode is broken.
