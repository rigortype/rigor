# Vendored gem RBS stubs

This directory ships RBS signatures for a small curated set of Ruby
**native-extension gems** that Rails projects routinely depend on but
that the stdlib RBS bundled with the `rbs` gem doesn't cover. The
stubs are loaded by default by `Rigor::Environment::RbsLoader` on
top of every project's `signature_paths:`, so they're in scope for
every analysis run with no user configuration.

## Why these specifically

A 14-project real-world survey (`docs/notes/20260515-real-world-rails-survey.md`)
ranked the top `call.undefined-method` selectors that real Rails
codebases (and a few non-Rails Ruby projects) hit when the gems'
RBS isn't loaded. The selectors clustered around four families:

1. **Database drivers** — `pg` (PostgreSQL), `mysql2` (MySQL).
2. **HTML/XML** — `nokogiri`.
3. **Auth/crypto** — `bcrypt` (Devise's password hashing).
4. **Cache/queue/Sidekiq** — `redis`.
5. **Standalone but ubiquitous** — `idn-ruby` (Mastodon's
   `bundle install` blocker, used by `twitter-text` for IDN
   handling).

These are the six gems vendored here. None of them have RBS in
the rbs-gem stdlib distribution; four (`mysql2`, `nokogiri`,
`bcrypt`, `redis`) are vendored from
[`ruby/gem_rbs_collection`](https://github.com/ruby/gem_rbs_collection)
(MIT) with per-gem `LICENSE.upstream` provenance; two (`pg`,
`idn-ruby`) are minimal hand-written stubs by Rigor maintainers
(MPL-2.0) because the collection doesn't carry them.

## Layout

```
data/vendored_gem_sigs/
  <gem>/
    <gem>.rbs           # the main RBS file (one per gem)
    <gem>_extras.rbs    # optional: Rigor-side patches for missing methods
    LICENSE.upstream    # provenance + license per gem
```

`<gem>_extras.rbs` carries hand-written additions to fill gaps in
the upstream RBS (e.g., `Nokogiri::HTML5` is a 1.12+ addition not
in the 1.11 collection snapshot; `Redis#scan` / `#ttl` / `#type`
are 4.5+ commonly-used methods absent from the 4.2 snapshot). All
extras are MPL-2.0 to match the rest of Rigor.

## Loading mechanism

`Rigor::Environment::RbsLoader.build_env_for(libraries:, signature_paths:)`
appends `Rigor::Environment::RbsLoader.vendored_gem_sig_paths` to
the `RBS::EnvironmentLoader` AFTER the user-supplied
`signature_paths`. User-supplied paths win on name conflicts.

The cache descriptor (`Rigor::Cache::RbsDescriptor.build`)
includes every `.rbs` file under each vendored gem dir, so editing
a stub invalidates the RBS env cache without manual intervention.

## Trade-offs

Adding a vendored stub for `Mysql2::Client` turns a previously
silent `client.query("SELECT ...")` (receiver `Dynamic[top]`,
diagnostic skipped) into a checked call. That catches BOTH real
bugs (genuine undefined methods on `Mysql2::Client`) AND incomplete-RBS
false positives (methods that exist in the gem but aren't in the
vendored stub). The 14-project survey shows the net effect is a
small increase in total diagnostics (+24 across 14 projects after
the initial set + the `Nokogiri::HTML5` patch) — concentrated on
the larger projects (Canvas LMS, Discourse, Forem) where the
likelihood of hitting gaps in the curated 4.2 / 1.11 surfaces is
highest.

Closing the residual gaps is incremental: add the missing methods
to the appropriate `<gem>_extras.rbs` and the next run picks them
up. PRs welcome.

## Adding a new vendored gem

1. Pick the gem. Bias toward "native extension that fails
   `bundle install` for users without system libs" or "shipped with
   every Rails app via the framework".
2. Decide the source:
   - If [`ruby/gem_rbs_collection`](https://github.com/ruby/gem_rbs_collection)
     carries it: vendor a snapshot of one version's RBS,
     attach `LICENSE.upstream` with the upstream commit reference
     and MIT license text.
   - If not: hand-write a minimal stub covering the most-used API.
3. Add `data/vendored_gem_sigs/<gem>/` with the `.rbs` files +
   `LICENSE.upstream`.
4. Verify with `make verify` (self-check confirms env build still
   succeeds and rigor's own `lib/` stays clean).
5. Re-measure on the survey projects; any new false positives
   surface specific missing methods, which extend
   `<gem>_extras.rbs`.

## Why opt-in is NOT the design

Earlier we landed `examples/rigor-activesupport-core-ext/` as an
**opt-in** RBS bundle wired in via `signature_paths:`. That was the
right design for ActiveSupport-shaped extensions because they're
in-place modifications of stdlib classes (`Object#blank?`,
`Integer#days`, `String#html_safe`) — every user with their own
local extensions of those classes has different needs.

This directory is the OPPOSITE shape: each gem owns its own
namespace (`PG::Connection`, `Mysql2::Client`, `Nokogiri::XML::Node`,
…), so there's no risk of clobbering user code. Shipping these by
default is uniformly safer than shipping ActiveSupport extensions
by default.
