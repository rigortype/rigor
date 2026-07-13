# ADR-54 — Cache slimming: definitions-blob retirement, payload compression, default eviction

Status: **Accepted — WD1–WD4 implemented, 2026-06-10** (same day as
proposal; commits `5f53db09` WD1, `0c671e04` WD2, `d2465fe1` WD3,
`5ced88f1` WD4). Grounded in the
[2026-06-10 cache disk + warm-load audit](../notes/20260610-cache-disk-runtime-audit.md)
(all numbers below are from that note; Mastodon cache, v0.1.17 working
tree). Landed observations: the compressed `rbs.environment` entry
measures 1.76 MB (16 % of the 11.0 MB raw blob); the repo's own
`.rigor/cache` — a long-lived checkout — held ~180 MB / 47 entries
against a ~2 MB / 14-entry active set, confirming WD3's orphan story
live (a capped run reaped exactly the stale entries and the next run
stayed warm). Every slice gated on diagnostics-identical self-check
runs (`--no-cache` / cold / warm) + cache/environment/config specs;
the cross-corpus Mastodon equivalence run is recorded in the audit
note's follow-up.

## Context

Every project's `.rigor/cache` weighs a near-uniform **~32 MB** regardless of
project size, dominated by three single-blob RBS producers:
`rbs.instance_definitions` (14.5 MB), `rbs.environment` (10.6 MB),
`rbs.singleton_definitions` (9.0 MB). Projects without their own
`signature_paths:` produce **byte-identical** entries, so a machine with the
~30-project survey corpus carries >1 GB of duplicated data. On the warm path,
loading the three blobs costs **~760 ms / 2.2 M allocations**, of which
`Marshal.load` is ~700 ms — disk read + SHA-256 envelope verification total
~15 ms and need no attention.

The audit's pivotal measurement: with the env blob already cached, **building
all 492 instance definitions from it takes 137 ms / 0.5 M allocs — versus
366 ms / 1.06 M allocs to `Marshal.load` the instance-definitions blob**
(singleton side: 178 ms build-all vs 180 ms load — break-even, and a lazy
per-class build of what a run actually touches is near-zero: 12 common
classes = 0.0 ms). The definitions blobs cost 23.4 MB/project to make warm
runs *slower*.

ADR-7 § "Slice 6-D" chose the single-blob layout because **per-class disk
entries** were slower than `--no-cache`; it never measured *blob versus
recompute-from-cached-env*. That comparison now exists, and the blobs lose.

## Decision

Adopt the criterion: **a cache tier earns its bytes only if it beats
recomputation from the next-cheapest tier on the warm path** — measured
against its own upstream cache, not against a cold rebuild. Applied:

1. retire the `rbs.instance_definitions` / `rbs.singleton_definitions` disk
   producers (WD1),
2. deflate-compress the value payload of every entry (WD2),
3. give eviction a non-nil default cap (WD3).

Expected envelope: **33.7 MB → ~1.7 MB per project (−95 %)** on disk; warm
runs that touch definitions save up to ~550 ms / 1.6 M allocs; cold runs
shed the eager build-all + 23 MB write. Precision/diagnostics are untouched
— every slice gates on byte-identical diagnostics + `make bench-perf`.

## Working decisions

**WD1 — retire the definitions blobs; build from the cached env.**
`cached_instance_definition` / `cached_singleton_definition`
(`rbs_loader.rb` ~L979/L990) switch from table lookup to per-class
`build_*_definition` on demand; the existing per-process memos
(`@instance_definition_cache` / `@singleton_definition_cache`) already
short-circuit repeats. Delete `lib/rigor/cache/rbs_instance_definitions.rb`
(both producer classes). **Constraint — the ADR-15 prewarm/Reflection
consumers stay eager:** `RbsLoader#prewarm` (~L765) and `#reflection`
(~L809) need full tables (pool workers must never call
`RBS::EnvironmentLoader.new`; the fork backend COW-shares the
parent-warmed tables). For them, `instance_definitions_table` /
`singleton_definitions_table` keep building the full table — now computed
from the cached env (315 ms for both sides) instead of Marshal-loaded
(546 ms). `RBS::DefinitionBuilder` over an already-built env does not touch
the `EnvironmentLoader` constant chain, so the Ractor-isolation rationale is
preserved.

**WD2 — deflate the value payload.** `Store#write_entry` deflates
`value_bytes` (zlib, stdlib — no new dependency); `#read_entry` inflates.
Bump the format byte (`HEADER` `RIGOR\x00\x01` → `\x02`, `store.rb:30`) —
old-format entries then fail the magic check and read as silent misses, so
**no migration code**: the next run recomputes and overwrites (the existing
fault-tolerance contract). The SHA-256 trailer keeps covering the stored
(compressed) bytes. Measured: blobs compress to 13–16 %; inflate costs
~50 ms total against the ~700 ms `Marshal.load` it sits next to —
runtime-neutral within noise.

*Addendum (landed follow-up, same day):* a format bump alone makes old
entries unreadable but never deletes them — and at ~32 MB they sit below
the WD3 cap forever. The `schema_version.txt` marker therefore now carries
`"<SCHEMA_VERSION>.<FORMAT_VERSION>"` (`Store.schema_marker_value`), so
the first writable run after a format bump clears the root through the
established marker-mismatch path and reclaims the bytes. The ADR-46
incremental snapshot — the one cache artefact that bypasses `Store` —
gets the same deflate treatment (its `SCHEMA` bumped 4 → 5; a raw pre-5
blob fails the inflate and loads as nil, the usual cold-run path).

**WD3 — default eviction cap.** `cache.max_bytes` defaults to nil
(`configuration.rb:78`), making `Store#evict!` (already wired at
`cli.rb:107`) a permanent no-op. Today entry counts stay at 1/producer only
because `Descriptor::SCHEMA_VERSION` bumps have been clearing the root; once
the schema stabilises, an `rbs` gem bump or `signature_paths:` change writes
a new key and orphans the old entries forever. Default the cap to a
generous **256 MB** (post-WD1/WD2 a full per-project set is ~2 MB, so the
cap only ever trims orphans); explicit `max_bytes:` config still overrides.

*Addendum (2026-07-07 follow-up):* the generous 256 MB cap is exactly why
small repos never trigger it — an audit of a real repository's
`.rigor/cache` found ~7 orphaned generations of `rbs.environment`
(~1.77 MB each, ~16 MB cache total) that the byte cap had no reason to
touch. The byte cap alone leaves orphan generations of a content-keyed
whole-project producer sitting below the cap indefinitely. `Store#evict!`
now runs a generation cap as a second, orthogonal compaction axis: a small
hardcoded allow-list of whole-project producer ids keeps only their most
recent N generations (2 for the RBS producers, 16 for
`analysis.run-diagnostics`), independent of `max_bytes:` — it runs even
when the store is unbounded (`max_bytes: nil`), since it reclaims
provably-dead bytes rather than enforcing a size budget. See
`docs/internal-spec/cache.md` § "Compaction (`#evict!`)" for the full
mechanics, including the co-landed stale temp-file sweep and the
`Rigor::VERSION`-carrying marker (payload ABI boundary on upgrade).

**WD4 (minor) — memoise `RbsDescriptor.build` per loader.** It runs once per
producer fetch (7×/run, identical result). Measured 1.3 ms × 7 today —
noise — but it scales linearly with `signature_paths:` size
(`gem_rbs_collection` checkouts), and the memo is one line.

## Rejected / deferred alternatives

| Alternative | Verdict | Reason |
| --- | --- | --- |
| Keep the definitions blobs but compress them | Rejected | Dominated by WD1 — a compressed blob still `Marshal.load`s slower than recomputing from the cached env, and still pays the disk. |
| Cross-project shared cache root (XDG `~/.cache/rigor` for the `rbs.*` producers) | Deferred | Safe (entries are content-keyed; ADR-6 deferred only cross-*machine* sharing) but post-WD1/WD2 the duplication shrinks to ~1.7 MB × N — not worth a second root, its locking story, and the read-only/editor-mode interactions. Re-evaluate if the env blob grows an order of magnitude. |
| mtime fast-path for ADR-45 `fresh?` re-digest | Rejected — **superseded by [ADR-87](87-null-build-floor.md)** | Saves ~50–150 ms warm on Mastodon-scale dep sets at the cost of the digest-strict soundness ADR-45 was built on. ADR-87 re-measures the premise on the far larger monorepo dep sets Rigor has since onboarded and adopts a *stat-then-digest* tier that keeps the SHA-256 as the sole change authority (the stat only decides whether to rehash), so the soundness ADR-45 was built on is preserved. |
| zstd via a gem dependency | Rejected | zlib is stdlib and already within 13–16 %; a compression gem violates the no-new-dependency posture ADR-6 chose the own-format backend for. |
| Per-class disk entries (re-litigating ADR-7 slice 6-D) | Stays rejected | ADR-7's measurement stands: per-entry disk open + load made warm runs slower than `--no-cache`. WD1 removes the tier entirely rather than re-sharding it. |
| Seek-indexed lazy blob (offset table + partial reads) | Rejected | Solves the same eager-load problem as WD1 with strictly more format machinery. |

## Consequences

- **Positive:** ~95 % smaller per-project cache; >1 GB reclaimed on a
  survey-corpus machine; warm runs touching definitions save up to ~550 ms
  and 1.6 M allocations; cold runs skip an eager 983-definition build and a
  23 MB write; pool-mode prewarm gets faster (315 ms compute vs 546 ms
  load).
- **Negative / cost:** one-time full cache invalidation on the WD2 format
  bump (silent miss + rebuild — the standard path); pool workers that
  lazily build a definition the parent didn't prewarm duplicate that small
  build per worker (bounded by build-all at 315 ms, COW makes it rare).
- **Status ripple:** ADR-7 § Slice 6-D is **partially superseded** — the
  definitions-blob half retires; the env blob and the rejection of
  per-class disk entries stand. ADR-6's format version policy covers the
  WD2 header bump.

## Relationship to other ADRs

- **ADR-6** — storage backend; owns the on-disk format whose version byte
  WD2 bumps. Its deferred "cross-machine sharing" row is unaffected.
- **ADR-7** — slice 6-D partially superseded by WD1 (see above).
- **ADR-15** — the prewarm/Reflection eager-table contract (Phase 2b /
  4b.x) is the binding constraint on WD1's lazy/eager split.
- **ADR-44/45/46** — same perf programme; this ADR closes the cache-layer
  disk/load axis those left untouched.
