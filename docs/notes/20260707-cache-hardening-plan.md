# Cache hardening / compaction — actionable plan

**Status (2026-07-08): executed and landed via [PR #57](https://github.com/rigortype/rigor/pull/57)**
(three commits) — phases 1–6 below are all complete (implementation, specs, docs,
CHANGELOG, verification green). Only the "Deferred" section remains open, now
tracked in `docs/ROADMAP.md`.

Re-planned from the handover note [`20260707-cache-mechanism-audit-sakana.md`](20260707-cache-mechanism-audit-sakana.md),
after auditing that note against the actual working-tree diff of `lib/rigor/cache/store.rb`
(the only changed file, ~+107/−17, syntax-clean, no specs/docs/CHANGELOG yet, no Flake verification yet).

## Audit verdict on the handover note

The note is accurate. Everything it lists as "already landed" is present in the diff:

- `PAYLOAD_ABI_VERSION = Rigor::VERSION` folded into `schema_marker_value` (now
  `<Rigor::VERSION>.<Descriptor::SCHEMA_VERSION>.<FORMAT_VERSION>`).
- `write_entry_for_compute` — `fetch_or_compute` no longer dies on filesystem write failures
  (`SystemCallError` / `IOError`), while serializer contract violations still raise.
- `fsync_directory` after the rename in `atomically_replace` (best-effort).
- `cleanup_stale_temp_files` (1-hour cutoff) and `evict_excess_generations`
  (`GENERATION_CAP_BY_PRODUCER`, RBS whole-project producers capped at 2,
  `analysis.run-diagnostics` at 16), both invoked from `evict!`.
- `producer_id_for_entry`'s first-path-segment assumption is valid: `entry_path` is
  `root/<producer_id>/<key[0,2]>/<key[2..]>.entry`.

Its top-priority open item is real and confirmed at two call sites: read-only stores are created by
`lib/rigor/language_server/project_context.rb:82` (LSP) and `lib/rigor/analysis/runner.rb:505`
(editor/buffer mode), and `ensure_schema_version!` early-returns for them without checking the marker
— so after a Rigor upgrade, until a writable run repairs the root, the LSP path will happily
unmarshal old-ABI blobs. This half-defeats the ABI marker.

Additional findings from this audit (not in the note):

- **(A) Write-failure policy is now inconsistent across the two fetch paths.**
  `fetch_or_compute` → `write_entry_for_compute` deliberately propagates serializer contract errors
  (`TypeError` etc.), but `fetch_or_validate` keeps its pre-existing blanket `rescue StandardError`
  around `write_entry`, which swallows the same class of producer bug. Pick one contract
  (recommended: the `write_entry_for_compute` one — narrow rescue, contract errors visible) and
  apply it to both.
- **(B) `max_bytes: nil` disables the new compaction entirely.** `evict!` early-returns on
  `@max_bytes.nil?`, so an explicitly unbounded store (`cache.max_bytes: null`) gets neither stale
  temp cleanup nor the generation cap. Both are orthogonal to the byte cap: `null` opts out of
  *size-based LRU eviction*, not of reclaiming provably-dead generations or leaked temp files.
  Recommended: run `cleanup_stale_temp_files` + `evict_excess_generations` before the
  `@max_bytes.nil?` check (still `read_only`-gated); only the LRU byte pass stays cap-gated.
- **(C) The marker write is non-atomic** (`File.write`). A crash mid-write leaves a corrupt marker,
  which the next writable run reads as a mismatch and clears the root — safe (over-invalidation,
  never stale reuse). No change needed; record the reasoning in the spec doc.

Decisions the note already made that this plan keeps:

- ABI marker stays `Rigor::VERSION` (parity with `IncrementalSnapshot`); the per-release cold rebuild
  is acceptable post-ADR-54 (~2 MB/project envelope).
- No zlib level tuning, no zstd — measured wins are ~8 % overall / ~3 % on the env blob; the real
  problem was orphan generations, which the generation cap addresses.
- `GENERATION_CAP_BY_PRODUCER` stays a hardcoded allow-list for now; a producer-declared
  `generation_cap:` metadata field is the better long-term shape → record as deferred follow-up.
  The `analysis.run-diagnostics` cap of 16 is a judgment call (multi-path-set invocations could
  churn live generations); keep it but call it out in the spec doc and CHANGELOG-adjacent notes.

## Plan

### Phase 1 — complete the ABI marker: boolean `ensure_schema_version!` + disk gate (highest value)

Make `ensure_schema_version!` return whether the disk tier is usable, memoized per Store
(`@disk_available` tri-state replaces `@schema_version_ensured`):

| Situation | Result |
| --- | --- |
| writable, marker current or repaired (mkdir + clear + rewrite succeeded) | `true` |
| read-only, marker present and current | `true` |
| read-only, marker missing / stale / unreadable | `false` (no clear, no write — next writable run repairs) |
| any filesystem failure during check/repair (mkdir, read, write, clear) | `false` — disk disabled for this Store instance |

Then gate both fetch paths:

- `fetch_or_compute`: `disk = ensure_schema_version!`; skip `read_entry` and
  `write_entry_for_compute` when `disk` is false. Producer block still runs; result still lands in
  `@memo`; stats record a miss (and no write).
- `fetch_or_validate`: same gate — no disk read, no disk write when unavailable.

This closes both remaining correctness items from the note at once: the read-only stale-marker hole
(LSP / editor mode) and the "broken cache root must not break analysis" degrade.

### Phase 2 — `atomically_replace` failure cleanup

Wrap the temp-file lifecycle in `ensure`:

```ruby
tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
begin
  ... write, fsync, rename, fsync_directory ...
ensure
  unlink_entry(tmp) if File.exist?(tmp)
end
```

so a failed write doesn't rely on the 1-hour `cleanup_stale_temp_files` sweep.

### Phase 3 — consistency fixes from this audit

1. **(A)** Replace `fetch_or_validate`'s blanket `rescue StandardError` write guard with
   `write_entry_for_compute` (rename it if it now serves both callers, e.g. `try_write_entry`).
   Note: `fetch_or_validate` values may legitimately fail default-Marshal serialization — its
   docstring says producers of non-Marshal-clean values MUST pass a serializer, so surfacing the
   `TypeError` is the correct contract there too. If a bundled producer currently relies on the
   swallow, that is a bug to fix at the producer, not a reason to keep the blanket rescue.
2. **(B)** Move `cleanup_stale_temp_files` + `evict_excess_generations` above the
   `@max_bytes.nil?` return in `evict!` (keep the `read_only` guard first).

### Phase 4 — focused specs (`spec/rigor/cache/store_spec.rb`)

- `schema_marker_value` includes `Rigor::VERSION`.
- Writable store clears the root on a stale marker and rewrites it.
- Read-only store: disk hit allowed only with a current marker; stale/missing marker ⇒ miss, root
  untouched, no marker written.
- Filesystem write failure (e.g. unwritable root injected after construction) ⇒ `fetch_or_compute`
  and `fetch_or_validate` return the computed value, record miss, no raise.
- Serializer contract violation raises on BOTH fetch paths (locks in Phase 3.1).
- Disk-disabled degrade: a store whose root check failed never touches disk again but memoizes.
- `atomically_replace` failure leaves no `*.tmp.*` behind.
- `cleanup_stale_temp_files` removes only files older than the cutoff.
- Generation cap evicts oldest-first for a capped producer; leaves non-listed producers alone.
- Generation cap + temp cleanup run under `max_bytes: nil`; LRU byte pass does not (locks in
  Phase 3.2).

### Phase 5 — docs + CHANGELOG

- `docs/internal-spec/cache.md`: update the marker example (`"4.2"` → the new
  `<Rigor::VERSION>.<schema>.<format>` triple); document read-only marker semantics (boolean gate,
  never repairs), the disk-disabled degrade, the generation cap (incl. the `run-diagnostics`
  cap-16 caveat and the hardcoded-allow-list limitation), stale temp cleanup, and the
  `max_bytes: nil` semantics decided in Phase 3.2.
- `docs/adr/54-cache-slimming.md`: WD3 addendum — the byte cap alone leaves orphan generations on
  small repos (observed: ~7 × 1.77 MB `rbs.environment` generations under a 16 MB cache);
  whole-project producers now carry a generation cap.
- `CHANGELOG.md` `[Unreleased]`: the note's draft entry is good; extend it with the upgrade-triggers-
  cold-run consequence and the read-only (LSP) stale-payload fix.

### Phase 6 — verification and landing

Inside the Flake (`nix … develop --command …`):

1. `bundle exec rspec spec/rigor/cache/store_spec.rb`
2. `make verify` (test / lint / self-check / check-plugins)
3. `git diff --check`

Land as a branch + PR (grouped, non-trivial change — per current landing policy), one logical
commit sequence: Phase 1+3 (behaviour), Phase 2 (hygiene), Phase 4 (specs), Phase 5 (docs).

## Deferred (record only, do not build now)

- Producer-declared `generation_cap:` metadata replacing the hardcoded allow-list.
- zstd / compression-level tuning (measured non-win).
- Any cross-project shared cache root work (ADR-54 deferral stands).
