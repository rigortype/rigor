---
name: rigor-rbs-setup
description: |
  Install community RBS for the project's gems with `rbs collection install`, so Rigor stops typing calls into RBS-less dependencies as `Dynamic` and gains real coverage (and real bug-catching) on them. Rigor auto-detects the resulting `rbs_collection.lock.yaml` — no Rigor config change needed. Triggers: "set up rbs collection", "my gems type as Dynamic", "rigor check says N gems have no RBS available", "reduce false positives from untyped gems". NOT for first-time Rigor setup (use rigor-project-init first) and NOT for a gem that has no entry in the community collection (that needs rigor-plugin-author or a Rigor issue).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor RBS Setup

Most of what Rigor cannot type on a real application is the surface of
third-party gems that ship **no RBS**: a call into such a gem returns
`Dynamic`, so every downstream method on the result is unprotected and
some genuine bugs go uncaught. The Ruby ecosystem's answer is the
community RBS collection at
[`ruby/gem_rbs_collection`](https://github.com/ruby/gem_rbs_collection);
this skill wires it into the project.

## When to use

- `rigor check` ends with `info: N gem(s) in Gemfile.lock have no RBS
  available: …` — that list is the gap this skill closes.
- A deep call chain into a gem (an HTTP client, a parser, a service
  object) types as `Dynamic` and you want Rigor to see through it.

## When NOT to use

- The project has no Rigor config yet — run `rigor-project-init` first.
- A specific gem you need is **not in** the community collection — RBS
  setup will not cover it. That residue is for `rigor-plugin-author` (if
  it is your own DSL) or a Rigor issue (if it is a popular gem worth
  built-in support).

## How Rigor consumes it (so you know what "done" looks like)

Rigor **auto-detects** `rbs_collection.lock.yaml` at the project root
(`rbs_collection.auto_detect` defaults to `true`) and feeds each gem's
downloaded RBS directory into its signature paths, skipping `stdlib`
entries it already bundles. **No `.rigor.yml` change is required** — the
lockfile's presence is the whole wiring. (Set `rbs_collection.lockfile:`
only if the lockfile lives somewhere other than the project root.)

## Procedure

### Phase 1 — see the gap

```sh
rigor check
```

Read the closing `info` line listing the gems with no RBS. That is your
target set.

### Phase 2 — make the `rbs` CLI available

`rbs collection` is part of the `rbs` gem and reads the project's
`Gemfile.lock`. Check it is runnable:

```sh
rbs --version            # or: bundle exec rbs --version
```

If it is missing, add it to the project's development group
(`bundle add rbs --group development`) or install it standalone
(`gem install rbs`). Prefer `bundle exec rbs …` when `rbs` is in the
Gemfile so it matches the project's resolved versions.

### Phase 3 — initialise the collection config (first time only)

```sh
rbs collection init
```

This writes `rbs_collection.yaml` (which gems to pull, which to ignore).
Skip if the file already exists; review it either way — the default
pulls RBS for every gem in the lockfile that the collection knows.

### Phase 4 — install

```sh
rbs collection install      # bundle exec rbs collection install when bundled
```

This resolves against `ruby/gem_rbs_collection`, writes
`rbs_collection.lock.yaml`, and downloads the `.rbs` files into
`.gem_rbs_collection/`.

### Phase 5 — verify (re-check; watch for new diagnostics)

```sh
rigor check
```

Two things to confirm:

1. **The `info` "no RBS available" list shrank** — the gems now covered
   dropped off it.
2. **No surprising new diagnostics.** Community RBS occasionally ships a
   signature stricter than the gem's real runtime behaviour, which can
   surface a false positive. Treat the diff like any other:
   - In **acknowledge mode**, regenerate the baseline
     (`rigor baseline regenerate`) so the new envelope is recorded.
   - For a **genuine** new error the sharper types caught, that is a win
     — fix it.
   - For a clear RBS-quality false positive, `# rigor:disable <rule>` the
     site with a reason, or pin the gem out in `rbs_collection.yaml`.

### Phase 6 — commit

Commit the **config + lockfile**, gitignore the **download dir**:

```sh
# .gitignore
.gem_rbs_collection/
```

Commit `rbs_collection.yaml` and `rbs_collection.lock.yaml` so every
contributor and CI resolves the same RBS. `.gem_rbs_collection/` is
regenerable from the lockfile (`rbs collection install`), so it is not
committed.

## Next step

Re-run `rigor skill describe` — with the gem-RBS foundation in place it
will route you to the next move (CI wiring, baseline work, or protection
uplift).
