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
- the relevant **configuration**.

Change any of those and the dependent entries are recomputed
automatically. A corrupt or unreadable entry is treated as a
miss and overwritten — bad cache state cannot wedge a run.

The cache is also schema-versioned: after a Rigor upgrade that
changes the cache format, the stale cache is purged on the
first writable run.

## Controlling the cache

| Flag | Effect |
| --- | --- |
| `rigor check --no-cache` | Run without reading or writing the persistent cache. |
| `rigor check --clear-cache` | Delete the cache directory, then run. |
| `rigor check --cache-stats` | Print the on-disk cache inventory when the run finishes. |

There is no config key to disable caching permanently — the
flags are per-run toggles. To run without a persistent cache
habitually, point `cache.path` at a disposable directory.

## Concurrency

The cache is safe to share. Parallel Ractor workers
(`--workers=N`) and multiple editor LSP sessions against the
same project coordinate through atomic, locked writes; the LSP
opens the cache read-only, so it never races a `rigor check`
running alongside it.
