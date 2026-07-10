# External-gem provenance: the coverage floor is a gem-install boundary, not an engine gap

Investigation note, 2026-07-11. Follows the [ADR-82 WD9](../adr/82-dynamic-provenance-wiring.md)
external-gem constant-provenance landing and its recorded coverage limitation. The question was
whether to build "target `GEM_PATH` awareness" so a global-gems project (mise/rbenv) gets the full
external-gem population instead of the rigor-shared floor. **The answer is no — the limitation is an
ADR-27 design boundary with an existing opt-in, and the real precondition is simply that the gems be
installed.**

## What the floor actually was

WD9's measured yield on the survey apps (Mastodon `app/models` 47, GitLab `lib` 124) came *entirely*
from gems rigor itself bundles (`i18n`, `rack`, `activesupport`). Every project-specific gem
(`grape`, `banzai`, `globalid`, `railties`) produced nothing. The reason is not the resolver — it is
that **the survey checkouts have no gems installed at all**:

```
$ cd rigor-survey/gitlab && bundle show globalid
… in locally installed gems      # not found — the bundle was never installed
```

GitLab's 800+ locked gems exist only in its `Gemfile.lock`. With nothing on disk, no resolution
strategy — not `Gem::Specification`, not a `GEM_PATH` probe — can read a gem's constants. WD9's
`Gem::Specification` fallback happened to catch the three gems rigor's *own* bundle shares, which is
the whole floor.

## Why "target GEM_PATH awareness" is the wrong fix

`BundleSigDiscovery.auto_detect` already states the boundary, and it is deliberate
([ADR-27](27-tool-distribution-model.md) — Rigor reads the project as *data*, never runs its
toolchain):

> The pure-default install location — gems in the active Ruby's GEM_HOME with no `path` configured —
> is the *project's* Ruby's gem home, which the isolated analyzer cannot know without running the
> project's toolchain. Point rigor at it with `bundler.bundle_path:` … `BUNDLE_PATH` from rigor's own
> environment is deliberately NOT consulted — it describes rigor's bundle, not the analyzed
> project's.

Auto-detecting the target's gem home would either (a) run the project's toolchain (violating the
isolation ADR-27 rests on) or (b) reimplement every version manager's on-disk layout (mise vs rbenv
vs rvm vs asdf, each different) as a fragile guess. And it is **redundant**: the escape hatch already
exists and already threads all the way through — `bundler.bundle_path:` → `Configuration` →
`ProjectContext` → `Environment.for_project` → the WD9 constant index's primary resolver.

## Proof the feature is complete once gems are installed

Installed Redmine's full bundle to `vendor/bundle` (101 gems) — the one layout `auto_detect` finds
without configuration — and re-ran `coverage --protection app lib` on **unchanged engine code**:

| cause | before (not installed) | after (`vendor/bundle`) |
|---|---:|---:|
| `external_gem_without_rbs` | shared-gem floor | **279** |

The 279 root at Redmine's actual gems, adjudicated correct: `Rails.application` / `Rails.env`
(`railties-8.1.3/lib/rails.rb` declares `module Rails`, ships no `sig/` → `:missing` → indexed),
`fragment.scrub!` (loofah), `I18n.t` (i18n). No engine change — the existing `vendor/bundle`
auto-detect + WD9 index delivered the full population the moment the gems were on disk.

## Conclusion

External-gem provenance is **complete**. Its coverage is a function of whether the project's gems are
installed where Rigor is allowed to look:

- `vendor/bundle` / `BUNDLE_PATH` → auto-detected, full coverage (Redmine: 279 sites).
- default gem home (rbenv/mise, no `--path`) → set `bundler.bundle_path:` (the ADR-27 opt-in).
- not installed (a bare checkout) → the rigor-shared floor; correctly fails open.

The only work this warranted was **documentation**: the "install your gems where Rigor can read them"
note in [`docs/manual/15-type-protection-coverage.md`](../manual/15-type-protection-coverage.md) §
"Why a hole is untyped". No engine change; "target GEM_PATH awareness" is closed as
already-decided (ADR-27) rather than deferred.
