# concurrent-ruby — opacity attribution (2026-09-01)

Target: /Users/megurine/repo/ruby/rigor-survey/concurrent-ruby (paths: lib — includes concurrent-ruby-edge)

## Numbers

| metric | value |
| --- | --- |
| files | 178 (0 parse errors) |
| expressions | 23,757 |
| precision | 56.04% (constant 7193, nominal 5239, shaped 355, bot 527; opaque 10,443) |
| protection | 49.51% (protected 1773 / unprotected 1808; lower_bound_typed 42) |
| cause_site_counts | inferred_return_untyped 685 (37.9%), none 641 (35.5%), unsupported_syntax 472 (26.1%), explicit_untyped 10 |
| tractability | engine_gap 1157, add_rbs 10 |

Opaque split: calls 3858, local reads 3231 (def_param 2120 / block_param 290 / assigned_local 821), ivar reads 496, other (BlockNode 542, IfNode 361, joins/splat/super...).
Call receiver tiers: precise 888, dynamic 1658, implicit_self 1312.

## Attribution split

- A param-sourced: 2410 local reads (def_param 2120 + block_param 290) — ADR-67, counted only.
- Known ivar roadmap: 496 opaque ivar reads — ADR-58 WD2/WD3 territory, counted only.
- C propagation: assigned_local 821 + dynamic-receiver calls 1658 (methods on already-Dynamic values: ==, [], call, arithmetic) + Mutex#synchronize below.
- D engine dispatch gaps: the dominant *named* remainder — the entire runtime-engine-selection + extend metaprogramming layer (below).
- F unsupported_syntax 26.1%: in rigor's taxonomy this cause is recorded by `unresolved_call_result` (lib/rigor/inference/expression_typer.rb:1200-1205) — i.e. mostly *unresolved dispatch*, which here is the same D mechanisms surfacing, plus genuine JRuby-only code.

## Cases

1. **implicit-self `synchronize` — 186 sites — D (conditional-superclass constant).**
   `Concurrent::Synchronization::LockableObject < LockableObjectImplementation` where `LockableObjectImplementation = case … when Concurrent.on_cruby? … when Concurrent.on_jruby? …` (lib/concurrent-ruby/concurrent/synchronization/lockable_object.rb:11-16). The superclass is a conditionally assigned (private) constant, so ancestor resolution stops and every `synchronize`/`ns_*` send inside the dozens of LockableObject subclasses is unresolved. Example: any `synchronize { … }` in lib/concurrent-ruby/concurrent/atomic/mutex_atomic_boolean.rb.
   Fix direction: constant-fold the engine predicates (`RUBY_ENGINE == 'ruby'` is a compile-time constant under the analysis Ruby) so the `case` folds to `MutexLockableObject`; failing that, type a conditionally assigned class constant as the union of its arms and dispatch through it.

2. **`extend Module` singleton dispatch — ≥120 sites — D (verified control).**
   `singleton(Concurrent)#on_jruby?/on_cruby?/on_truffleruby?` (54; lib/concurrent-ruby/concurrent/utility/engine.rb:44 `extend Utility::EngineDetector`), `singleton(Concurrent::Promises)#resolvable_future` (20) + `future` (30, implicit/dynamic bucket; promises.rb:2152 `extend FactoryMethods`), `Concurrent::Utility::NativeInteger.ensure_*` (15; native_integer.rb:51 `extend self`), `Concurrent#global_io_executor/#executor` (18).
   Control (same-file, no cross-file horizon): `module Det; def on_x?; RUBY_ENGINE == 'x'; end; end; module Host; extend Det; end; Host.on_x?` → Dynamic[top]. Extended modules never join the singleton ancestor chain.
   Fix direction: fold `extend M` (statically visible in a class/module body) into singleton-ancestor resolution — the ADR-43 complete-ancestor machinery is the natural home. This single mechanism also unlocks case 1's `case` folding (its scrutinees are `Concurrent.on_*?`).

3. **`module_function` copy — 31 sites — D (verified control).**
   `singleton(Concurrent)#monotonic_time` (lib/concurrent-ruby/concurrent/utility/monotonic_time.rb:18 `module_function :monotonic_time`). Control: `module MF; def mono(…); 42; end; module_function :mono; end; MF.mono` → Dynamic[top]. Fix: model `module_function` (both nullary-mode and named form) as def + singleton copy.

4. **Conditional-superclass atomics — 43+ sites — D (same family as case 1).**
   `Concurrent::AtomicFixnum#value` (30), `#compare_and_set` (13): `AtomicFixnumImplementation = case … end`, `class AtomicFixnum < AtomicFixnumImplementation` (lib/concurrent-ruby/concurrent/atomic/atomic_fixnum.rb:99-107,136). Identical pattern for AtomicBoolean/AtomicReference/CountDownLatch/Semaphore/`AtomicMarkableReference`. Example site: lib/concurrent-ruby/concurrent/atomic/read_write_lock.rb:115 (`@Counter.value`).

5. **`Mutex#synchronize` — 48 sites — C (container/generic of Dynamic).**
   Control shows the block-generic binding works (`m.synchronize { 1 }` → Constant[1]), so these sites are X:=Dynamic propagation: the block bodies read ivars and call the case-2/3 factories. Example: lib/concurrent-ruby-edge/concurrent/edge/channel.rb:102.

6. **Optional (nilable) receiver dispatch — ~40 sites — D (verified control).**
   `Array[Dynamic[top]]?#length/#[]/#clear` (22+, e.g. lib/concurrent-ruby/concurrent/agent.rb:532), `Concurrent::Hash | Hash[…] | nil#[]=` (7, non_concurrent_map_backend.rb:26). Control: `arr = cond ? [1,2] : nil; arr.length` → Dynamic[top], while the nil-free union `([1] or {1=>2}).size` → Integer. The union-dispatch machinery works; the nil arm makes it bail. Fix: dispatch over non-nil arms and join (surface the nil arm as a diagnostic, not Dynamic) — consistent with false-positives-first, since these sites are guarded by control flow the narrowing missed.

7. **`Concurrent::Maybe.just/.nothing` — 21 sites — D (metaprogrammed constructor).**
   Plain `def self.just/nothing` resolve, but their body `new(…)` goes through `safe_initialization!` → `extend SafeInitialization` whose `def new(*args, &block)` overrides the constructor at runtime (maybe.rb:106; synchronization/safe_initialization.rb:28-29). Falls out of case 2's fix if the macro body is evaluated; otherwise plugin territory (a `safe_initialization!` recognizer would be ~5 lines of plugin).

8. **`Thread.pass` — 9 sites — D (small, unexplained core-singleton miss).**
   Control file `Thread.pass` alone → Dynamic[top]; a `-> void` return types as `top` (separate control), so this is not void-mapping — resolution fails before signature lookup. Worth a unit look; low volume.

9. **F unsupported_syntax (472 sites, 26.1% of causes).** Sampled: `@queue.length == 1` chains (provenance carried from unresolved origins, agent.rb:535), `!!ok` on Dynamic (agent.rb:469), and genuinely JRuby-only code — `java.util.concurrent.CountDownLatch.new(count)` where `java` exists only under JRuby (java_count_down_latch.rb:15). The bucket is mostly unresolved-dispatch fallback (the D cases above) plus platform-conditional code no static env can resolve; very little is *syntax* in the grammar sense.

10. **A param-sourced — 2410 local-read sites.** Counted; ADR-67 closed territory.
