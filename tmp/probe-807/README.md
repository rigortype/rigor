# Issue #807 probes — the cross-process marker race

The instruments behind PR #891. Kept on this branch only: they are throwaway harnesses, not
suite material, and the in-suite example (`spec/rigor/cache/store_spec.rb`, "survives many stores
… left stale by an earlier release") preserves only the thread-level shape.

`race_probe5.rb` is the one that matters. It forks `PROCS` processes that construct a `Store` on
ONE fresh root at the same instant and counts spurious `clear_cache_root!` calls. Pre-fix it
reported 6 clears across 4 of 40 rounds; post-fix, 0 of 40.

    PROCS=12 ROUNDS=40 nix … develop --command bundle exec ruby -Ilib tmp/probe-807/race_probe5.rb

The in-PROCESS variants (`race_probe.rb`, 2, 3, 4, 6) never reproduced: 0 clears over 200
barrier-synced rounds × 24 MRI threads. MRI essentially never preempts mid-`File.write`, which is
why the atomic-write half of the fix is justified by the fork probe rather than by a spec.
