# ADR-88 — Incremental plugin-fact soundness

Status: **Accepted — WD1–WD4 implemented ([PR #89](https://github.com/rigortype/rigor/pull/89)); WD5 (per-consumer
plugin-read tracking) deferred.** The `--incremental` snapshot's global fingerprint
(config / gems / RBS env / `signature_paths:`) does NOT capture the values a plugin
computes from files OUTSIDE those inputs — a Sorbet catalog built from an `.rbi`
tree under `rbi_paths:`, an ActiveRecord model index from `db/schema.rb`. Editing
such a file changes the types unchanged call sites resolve without moving any
analyzed file, so the recheck serves a stale cached diagnostic. WD1 fingerprints
the plugin **fact surface** (ADR-9 facts + ADR-60 producer values + an optional
hook) and invalidates the snapshot when it moves. WD2 producer-izes the Sorbet
catalog. WD3 records the `user_def_site_for` dependency edge. WD4 hardens the gate
— and root-causes the pre-existing gitlab `--verify-incremental` red to a
plugin-loader idempotency bug, not the hypothesized producer nondeterminism.

Grounding: [`20260714-incremental-plugin-fact-audit.md`](../notes/20260714-incremental-plugin-fact-audit.md)
(the recorder / catalog / snapshot-fingerprint map this ADR reads).

## Context

ADR-46 makes a `--incremental` recheck re-analyze only the changed closure
`ΔF ∪ dependents[ΔF]`, serving every other analyzed file from the
{Cache::IncrementalSnapshot}. Two gates protect it: the **global fingerprint**
({IncrementalSnapshot.fingerprint}) drops the whole snapshot on a config / gem /
RBS / project-`sig` change, and the per-file **dependency graph** (recorded via the
`Scope` accessor choke points, ADR-46/85) drives the closure.

Neither sees a plugin's cross-file contribution derived from files those two
mechanisms do not track:

- `rigor-sorbet` reads `.rb` / `.rbi` sig trees under its `paths:` / `rbi_paths:`
  and contributes `dynamic_return` types at call sites in OTHER files. An `.rbi`
  under `sorbet/rbi/` is not analyzed, is not in `signature_paths:`, and is read by
  the plugin internally — not through a `Scope` choke point. So editing it moves
  the catalog (and the types every consumer resolves) while the global fingerprint
  stays fresh and the recheck's changed set `ΔF` is empty. The recheck serves the
  stale cached diagnostics.
- The same holds for any producer over out-of-band inputs: an AR `db/schema.rb`
  edit changes `model_index`; a routes change changes `helper_table`.

The audit note maps the choke points (the recorder at `scope.rb`, the catalog
build at `sorbet.rb`, the snapshot fingerprint at `incremental_snapshot.rb`) and
confirms the ADR-45 whole-run cache is inert on these runs (a
`record_dependencies` / `analyze_only` run is excluded).

## Criterion

A cached per-file diagnostic may depend on a plugin value that the global
fingerprint does not capture. Every such value must be **fingerprinted so its
change invalidates the snapshot** — the conservative direction (a full re-analysis
is always sound). But the fingerprint must be **precise about what actually
changed**: it invalidates on a change to a producer's *contributed value*, never on
a change to its *inputs* alone. A value-preserving edit (a controller body edit
that adds no action) recomputes `controller_index` to an identical value and must
keep the recheck incremental — otherwise every Rails model/controller edit forces a
full re-analysis, and incremental is worthless for the apps it exists to serve.

Honesty of attribution carries over from ADR-82: a plugin that contributes types
but declares no fingerprint surface is not silently trusted (a stale reuse) — it is
named and makes the snapshot un-reusable, a forcing function to declare the surface.

## Working decisions

### WD1 — Fact-surface value fingerprint

After the analysis runs `#prepare`, {Analysis::PluginFactFingerprint} digests three
channels and stores the digest on the snapshot ({IncrementalSnapshot::SCHEMA} 8→9;
a pre-9 blob mismatches the gate and loads nil — a clean cold rebuild, spec'd):

- **(a) facts** — every ADR-9 `services.fact_store` publication `(plugin_id, name)
  -> value`, digested per `(plugin_id, name)`.
- **(b) producers** — every declared {Plugin::Base.producer}'s computed **value**
  (`producer_value`), digested.
- **(c) hook** — an optional `Plugin::Base#incremental_state_fingerprint` returning
  a String, for internal catalog state outside (a)/(b).

On a warm recheck the current digest is compared to the snapshot's stored one; a
mismatch discards the snapshot and runs a full analysis, surfaced in the
`--incremental` banner and `--cache-stats`.

**Value, not blob.** The digest is of the producer's **value**, not its cache-entry
blob. The blob also carries the dependency descriptor (the input files' digests), so
it moves on ANY input edit — including a value-preserving one — which over-invalidates
(a measured gitlab controller-edit → 23s full re-analysis vs 9.5s incremental). The
value digest moves only when the contributed value moves. This is the criterion's
precision requirement made concrete, and it is why WD2's determinism fix
(below) is load-bearing: a non-deterministic producer value would false-invalidate on
every recompute.

**Post-hoc, not a separate probe.** The fingerprint is read POST-HOC from the
analysis runner's already-prepared registry
({PluginFactFingerprint.from_registry}), not from a second `#prepare` probe. The
recheck already ran `#prepare` and consulted/validated its producers, so their
values are memoised — the fingerprint pays only the value digest, ~0.24s on gitlab
(≈2.5% of a 9.5s recheck, under the perf gate). A POOLED run's main process skips
`#prepare`, so there the always-sequential probe ({PluginFactFingerprint.compute})
is the fallback; both paths compute the identical digest for a given surface, so the
reuse decision is pool-independent (the parity spec asserts `from_registry` ==
`compute`).

**Opaque plugins.** A plugin registering `dynamic_return` / `narrowing_facts` with
NONE of (a)/(b)/(c) has stale-able state the fingerprint cannot see. Rather than
risk a stale reuse it makes the snapshot un-reusable every run and is named in a
one-line note (`--incremental` banner + `--cache-stats`). The bundled contributing
plugins were audited and all made non-opaque: sorbet gets its surface from WD2's
producer; actionpack / activerecord / activestorage already declare producers;
minitest / rspec / mangrove (and the `examples/` units / pattern / lisp-eval) get an
`incremental_state_fingerprint` returning a stable sentinel — their contributions
are per-file (each analyzed file's own AST) or static, so they carry no cross-file
surface, a claim the `--verify-incremental` gate backstops.

### WD2 — Sorbet catalog producer-ization

The per-run Sorbet catalog (`sorbet.rb`) was rebuilt unconditionally on every
recheck (parse + walk every `.rb`/`.rbi` sig tree). It becomes an ADR-60
record-and-validate `producer :catalog` with `watch:` over the scanned trees, so it
is disk-cached and invalidated on any sig add/remove/edit — and its VALUE is
digested by WD1(b) for free (closing the `.rbi` gap). The producer returns a
Marshal-clean bundle `{ catalog:, sigil_by_path:, parse_errors_by_path: }` (a cache
HIT does not run the block, so the sigil map + parse errors are captured in the
value, not written as side-effects; parse errors become `{kind:, line:, column:}`
tuples, no live Prism node). The catalog VALUE must be deterministic across
recomputes — a non-deterministic value would false-invalidate the WD1 fingerprint —
so the last-sig-wins fold order must be stable; `Dir.glob` already sorts by default
on Ruby 3.0+ (the slice-1 "filesystem order" caveat predates that default), so the
walk relies on that rather than re-sorting. All bundled producers were verified
deterministic on recompute.

### WD3 — `user_def_site_for` records its edge

`Scope#user_def_site_for` (which names a project monkey-patch's definition site for
`call.undefined-method`'s `project_definition_site`) read `discovered_def_sources`
without recording a dependency edge — the sibling `#user_def_for` records one. A
line-shift edit above the def moves its `"path:line"` (its body, and so its symbol
fingerprint, unchanged), and the caller was served the stale line from cache. It now
records the same instance-side cross-file method edge; the file-level edge the read
establishes pulls the caller back into the affected closure. A fabricated line-shift
spec demonstrates it (red without the edge: the caller is not in `affected`).

### WD4 — Gate hardening

**(a) Fabricated-edit battery.** WD4a specs prove the WD1 mechanism end-to-end
against real bundled plugins: a Sorbet `.rbi` sig edit (Integer→String) invalidates
the snapshot and re-analyzes the consumer (red-before with WD1 disabled: the recheck
stays warm and serves the stale `call.undefined-method`); a dry-types alias-module
addition and an AR schema-column change each move the fact-surface digest. Plus the
WD3 line-shift, the WD1 schema/fingerprint round-trip specs, the opacity spec, and
the pooled-vs-sequential parity spec.

**(b) The gitlab `--verify-incremental` red — root-caused to the plugin loader, not
a producer.** Before this PR, `rigor check --verify-incremental app/models
app/controllers` on gitlab FAILED with 1,161 incremental-only / 19 full-only
diagnostics (all `:info` Action Pack recognition trace). The audit hypothesized
producer cached-state ≠ fresh or `Dir.glob`-order nondeterminism. **It is neither.**
The verify harness runs baseline → subset-reanalyze → full **in one process**, and
its `full` oracle (`verify_full_diagnostics`) is a SECOND in-process
`Plugin::Loader.load` of the same bare-string plugin set. `require` runs a gem's
body — and its `Rigor::Plugin.register` calls — at most once per process, so the
second load's newly-registered delta is empty and a bare-string (`id:`-less) entry
hits the `when 0` "did not register any plugin" LoadError → the oracle silently
loaded ZERO plugins → 2,494 correct diagnostics vs the oracle's 101. **The fix is in
the loader**: it memoises `gem name → registered plugin ids` on first load and
recovers the ids when a re-load's `require` no-ops (`Plugin.record_gem_registration`
/ `ids_for_gem`, consulted only for an `id:`-less entry with an empty delta). This
also makes the incremental session's own subset-reanalysis load its plugins. After
the fix the gitlab verify is byte-identical (887/1,774 re-analyzed matches full,
2,494 diagnostics, **zero mismatch**), with a cleared cache too (so it was a
same-process reproducible bug, not stale disk state). The sort-the-globs
determinism work still lands (WD2) — it is real robustness against
cross-environment nondeterminism — it was simply not the cause here.

### WD5 (out of scope) — per-consumer plugin-read tracking

A finer design would record, per consumer, which plugin values it read (a Scope-side
plugin-read choke point), so a fact-surface change re-checks only the affected
consumers instead of invalidating the whole snapshot. This is deferred: the
whole-snapshot invalidation is sound and, with the value-digest precision (WD1) +
producer determinism (WD2), does not over-invalidate on the common value-preserving
edit. The measured warm-recheck overhead (~2.5% on gitlab) does not justify the
plugin-read-graph machinery yet.

## Consequences

Precision-additive to the incremental machinery: no diagnostic, type, or severity
change; cold diagnostics are byte-identical to `origin/master`. The perf gate is met
(warm recheck +~2.5% on gitlab; a value-preserving model/controller edit stays
incremental). The WD4b loader fix is a strict soundness improvement to the
`--verify-incremental` gate and any in-process multi-load path (LSP, the incremental
session's own subset run).

## Rejected / deferred

- **Blob digest (cache-entry bytes) as the producer signature** — cheaper (no
  re-Marshal) but the blob carries the input-file descriptor, so it over-invalidates
  on value-preserving edits. Value digest is the correct semantics.
- **A separate `#prepare` probe as the fingerprint's sole path** — measured ~1.0s on
  gitlab (a second `#prepare` + a second producer validation), ~10% of a recheck.
  Post-hoc from the analysis runner reuses the recheck's prepare (~0.24s). The probe
  survives only as the pooled-mode fallback.
- **Down-tiering / suppressing the gitlab `:info` verify diff** — the diff was a
  broken oracle, not a real strengthening; fixed at the loader, never by excluding
  `:info` (ADR-72 kinship: fix the source).
- **WD5 per-consumer plugin-read tracking** — deferred (above).
