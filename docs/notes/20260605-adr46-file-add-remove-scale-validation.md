# ADR-46 file add/remove — scale validation (real OSS libs)

2026-06-05. Empirical validation of the ADR-46 slice-3 **file addition /
removal** incremental tier against real OSS code, beyond the synthetic
edit-driven specs. Confirms byte-identity with a full run at scale and the
expected leaf-vs-hub precision.

## Method

For each project, `liquid/lib` and `mail/lib` were copied to a tmpdir, an
`IncrementalSession` baselined over them, then — per representative file —
the file was **deleted**, `#recheck` run, and its merged diagnostics
compared (sorted, structural `Diagnostic#to_h`) to a full `--no-cache`
re-analysis; the file was then **restored** and the same comparison run.
`recheck == full` at every step is the soundness property (no stale
diagnostic served from cache).

This is the edit-driven counterpart to `--verify-incremental` (which does no
edits — it only partitions an unchanged tree). The corpus-dependent scale
check is not a committed CI test (CI has no survey corpus); the committed
soundness coverage is the synthetic add/remove specs in
`spec/rigor/analysis/incremental_session_spec.rb`.

## Results

`--verify-incremental` (unchanged-tree subset/cache/merge oracle), confirming
the roots-keyed fingerprint and the broader machinery hold on real code:

| Project | Files | Re-analyzed | Result |
|---|---:|---:|---|
| liquid/lib | 64 | 32 | OK — matches full (13 diagnostics) |
| kramdown/lib | 55 | 28 | OK — matches full (14 diagnostics) |

Edit-driven remove + re-add (`recheck == full` byte-identical at every step):

| Project | Files | File removed | Re-analyzed on remove | Re-analyzed on re-add | byte-identical |
|---|---:|---|---:|---:|:---:|
| liquid/lib | 64 | `standardfilters.rb` (leaf) | 0 | 1 | ✓ |
| liquid/lib | 64 | `condition.rb` | 1 | 1 | ✓ |
| liquid/lib | 64 | `block.rb` (base class) | **9** | 10 | ✓ |
| liquid/lib | 64 | `tags/for.rb` (leaf) | 0 | 1 | ✓ |
| mail/lib | 111 | `message.rb` | 1 | 2 | ✓ |
| mail/lib | 111 | `body.rb` | 0 | 1 | ✓ |
| mail/lib | 111 | `header.rb` | 0 | 1 | ✓ |
| mail/lib | 111 | `field.rb` | 0 | 1 | ✓ |
| mail/lib | 111 | `configuration.rb` | 0 | 1 | ✓ |

## Reading

- **Byte-identical everywhere.** Every remove and re-add produced diagnostics
  byte-identical to a full re-analysis of the post-edit tree — the soundness
  property holds on real, diverse code, not just synthetic fixtures.
- **The leaf-vs-hub intuition is real.** Removing the `Liquid::Block` base
  class re-checked **9 dependents** (its subclasses + users), while removing a
  leaf filter / tag re-checked **0** — exactly the dependency-graph precision
  the design targets. A re-add re-checks the added file plus the consumers of
  the names it re-introduces (1–2 files).
- The `--verify-incremental` pass on liquid / kramdown confirms the
  roots-keyed snapshot fingerprint (the file-add/remove enabler) did not
  regress the unchanged-tree subset/cache/merge path.

## Reproduce

In the Flake shell, copy `~/repo/ruby/rigor-survey/<proj>/lib` to a tmpdir,
drive `Analysis::IncrementalSession#{baseline,recheck}` around `File.delete` /
`File.write`, and compare `sorted(recheck.diagnostics)` to `sorted(full)`
(see the throwaway spec shape in this note's commit message / the synthetic
specs). `--verify-incremental` is the one-shot CLI form:
`cd <proj> && BUNDLE_GEMFILE=<rigor>/Gemfile bundle exec <rigor>/exe/rigor
check --verify-incremental --no-stats lib`.
