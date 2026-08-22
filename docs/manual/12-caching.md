# Caching

Rigor caches expensive intermediate results — parsed RBS
environments, per-file analysis products — so a second run
over an unchanged project is fast. The cache is correct by
construction: you should never need to clear it to fix a stale
result. This page is for the times you are curious where it
lives or want to reclaim the space.

## Where it lives

The cache is an on-disk directory, `.rigor/cache` by default,
relative to the project root. Change it with the `cache.path`
config key:

```yaml
cache:
  path: tmp/rigor-cache
```

Add the cache directory to your `.gitignore`.

## What invalidates an entry

Each entry is keyed by a hash of everything its result depends
on:

- the **content** of the source and `.rbs` files that fed it,
- the **gems** in play, by name and locked version,
- the active **plugins**, by ID and version,
- the relevant **configuration**,
- **Rigor itself**, by version.

Change any of those and the dependent entries are recomputed
automatically. A corrupt or unreadable entry is treated as a
miss and overwritten — bad cache state cannot wedge a run.

Rigor's version identifies its own code only for a released gem.
If you run Rigor from a git checkout — a working copy you are
patching, or `gem "rigor", github:` tracking a branch, where two
commits share one version number — the entries that hold
analysis results are keyed on the content of Rigor's own source
as well, so editing the analyzer and re-running recomputes
instead of replaying the previous answer. That costs one pass
over Rigor's source per run (about 20 ms); an installed gem
neither pays it nor needs it.

The cache is also schema-versioned: after a Rigor upgrade that
changes the cache format, the stale cache is purged on the
first writable run.

## Effect summaries

[Effect labels](19-effect-labels.md) are cached alongside the rest,
but under their **own** identity: Rigor's effect vocabulary, its
built-in effect catalogue, and your `effects:` block. Two
consequences worth knowing:

- **Turning `effects:` on or off does not invalidate the entries
  your `rigor check` already relies on.** The two identities are
  separate, so adopting effect labels costs a first collection
  pass and leaves the diagnostics cache alone. Upgrading to a
  Rigor whose catalogue changed does the reverse — it re-reads
  your effects without re-running your check.
- **The `rigor effects` verbs share those summaries with `rigor
  check`.** In a job that runs both, the second command pays for
  the propagation rather than for a second analysis.

The exception is a `rigor effects` run on a project with **no**
`effects:` block: it collects under an implicit empty block and
shares no cache with `rigor check`, because a run served from that
cache would have collected nothing.

## How a file is checked for changes

To decide whether a cached entry is still valid, Rigor needs to
know which of your files changed since the entry was written. By
default it checks each file's **stat metadata** first — size,
nanosecond modification and change timestamps, and inode — and
only re-hashes a file's content when that metadata moved. On a
large project an unchanged run then reads *zero* content bytes to
validate the cache, instead of re-hashing every file.

The content hash stays the sole authority on whether a file
actually changed: the stat check only decides whether the hash
needs recomputing. A file that was merely `touch`ed (new
timestamp, identical content) is re-hashed once and correctly
found unchanged. Editing a file always moves its timestamps, so
an edit is never missed.

The stat check is skipped where it cannot work: the default
setting is `validation: auto`, which behaves as `stat` on your
machine and switches to hashing every file (`digest`) when a CI
environment is detected. CI is the common case of untrustworthy
stat metadata — a fresh checkout regenerates every timestamp and
inode, so a cache restored across CI runs (for example with
`actions/cache`) never passes the stat check, and parts of it
(plugin watch-glob entries, which are stat-signature only) would
be recomputed on every run. Content hashes are identical across
checkouts, so under `digest` the restored cache simply hits.

The setting can be forced either way:

```yaml
cache:
  validation: digest    # hash always — for any filesystem whose
                        # timestamps or inodes cannot be trusted
  # validation: stat    # stat always — e.g. a self-hosted CI
                        # runner that reuses its workspace, where
                        # stat metadata IS stable across runs
```

For a single run, `RIGOR_STRICT_VALIDATION=1` forces `digest`
and wins over the config key; `RIGOR_CI_DETECT=0` turns off the
CI detection that `auto` relies on.

## Controlling the cache

| Flag | Effect |
| --- | --- |
| `rigor check --no-cache` | Run without reading or writing the persistent cache. |
| `rigor check --clear-cache` | Delete the cache directory, then run. |
| `rigor check --cache-stats` | Print the on-disk cache inventory when the run finishes. |
| `rigor check --incremental` | Re-analyse only what changed; serve the rest from the incremental snapshot (see below). |

There is no config key to disable caching permanently — the
flags are per-run toggles. To run without a persistent cache
habitually, point `cache.path` at a disposable directory.

## Size and eviction

A project's active cache set is small (around 2 MB). Entries
are content-keyed, so events like a gem upgrade or an `.rbs`
edit write fresh entries and leave the old ones *orphaned* —
nothing references them, and no run would otherwise delete
them. To reap those, Rigor evicts least-recently-used entries
at the end of a run once the cache directory exceeds
`cache.max_bytes` (default **256 MB** — far above any active
set, so eviction only ever touches orphans):

```yaml
cache:
  max_bytes: 67108864   # tighten the cap to 64 MB…
```

```yaml
cache:
  max_bytes: null       # …or disable eviction entirely
```

## Incremental analysis

The cache above makes an *unchanged* project fast — a second
run over the same files reuses the whole result. `rigor check
--incremental` goes further: when you have edited a few files,
it re-analyses **only those files plus the files that depend on
them**, and serves every other file's diagnostics from a
snapshot of the previous run. Editing a leaf controller
re-checks one file; editing a model re-checks the model and its
callers — not the whole project.

The diagnostics are identical to a full run. Rigor records, per
file, which other files its analysis read from, so it knows
exactly which files an edit can affect. A continuous-integration
gate, `rigor check --verify-incremental`, asserts this on every
build: it runs the incremental analyzer and a full analysis and
fails if they disagree on a single diagnostic.

Rigor is also precise about *what* an edit changed. Re-checking a
file that many others depend on — a base class, a widely-used
concern, a shared utility — used to re-check every dependent.
Now, if your edit did not change the file's declaration shape
(the signatures of its methods, its superclass and includes) or
the types its methods return, the files that only depend on those
things are left untouched: a comment, a formatting change, or an
internal refactor that preserves every method's return type stops
at the edited file. An edit that *does* change a return type or a
signature still propagates to the dependents that consume it, so
the result stays identical to a full run.

Types contributed by plugins (a Sorbet signature, an
ActiveRecord column type, a dry-types alias) are validated too:
if a plugin's cross-file contributions change between runs, the
snapshot is dropped and the next run is a full one, so a plugin
edit can never leave a dependent stale.

An `--incremental` re-check honours `--workers=N` (and
`RIGOR_RACTOR_WORKERS` / `parallel.workers:`), analysing the
affected files in parallel just as a full run does.

The snapshot lives under the cache directory (`.rigor/cache`)
and is keyed by a fingerprint of your configuration, your locked
gems, your project's own `sig/` RBS, the Rigor version, and — if
you run Rigor from a checkout — the content of Rigor's own
source. Change any of those and the snapshot is dropped and the
next run is a full one, so an incremental run can never serve a
stale result. (The fingerprint keys on the analysis *roots* — e.g.
`["lib"]` — not the expanded file list, so adding or removing a
file *under* those roots does **not** drop the snapshot: the
incremental session re-analyzes the added files and the
dependents of removed ones.) As with the rest of the cache, a
missing or corrupt snapshot is simply a full run; it can never
wedge analysis.

`--incremental` is most useful for fast local re-checks and CI
on a changed branch. For a one-shot run on an unchanged project,
the ordinary cache already serves the whole result in one step.

## Concurrency

The cache is safe to share. Parallel worker processes
(`--workers=N`) and multiple editor LSP sessions against the
same project coordinate through atomic, locked writes; the LSP
opens the cache read-only, so it never races a `rigor check`
running alongside it.
