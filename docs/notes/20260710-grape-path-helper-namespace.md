# Grape path helpers: an open namespace, not a name table

Design note, 2026-07-10. The GitLab plan's **P2 item 8**
([`20260708-gitlab-type-coverage-improvement-plan.md`](20260708-gitlab-type-coverage-improvement-plan.md)),
which framed the work as "model the gem's `api_v4_*` helper-name generation over grape route files".
Reading the gem overturns that framing.

## Why the names cannot be enumerated

`grape-path-helpers` 2.0.1 builds each helper name in `DecoratedRoute#path_helper_name` from the
**route's path segments**, joined with `_` and sanitized: `/api/:version/groups/:id/badges` with
`version 'v4'` becomes `api_v4_groups_badges_path` (the `:id` segment resolves to nil and is
dropped). The route list it walks is `Grape::API::Instance.routes` — the *runtime* route table, built
by mounting.

GitLab's grape sources build that table with metaprogramming:

```ruby
%w[group project].each do |source_type|
  is_project = source_type == 'project'
  # ... resource source_type.pluralize ...
```

A static parser cannot enumerate those routes. It could derive *some* names, which is worse than
none: every route it failed to derive would keep firing `plugin.rails-routes.unknown-helper` on
working code. That is precisely the failure mode P0-1 just fixed for Rails' own `name_for_action`.

So a name table is the wrong artifact. What can be established statically is the *namespace*.

## What can be established

The gem defines only `_path` helpers — `NamedRouteMatcher#method_missing` opens with
`return super unless method_name.end_with?('_path')`. There is no `_url` form.

And the leading path segments are declarations, not computation. In `lib/api/api.rb`:

```ruby
class API < ::API::Base      # ::API::Base < Grape::API::Instance
  prefix :api
  version 'v3', using: :path do ... end
  version 'v4', using: :path
```

`prefix` contributes the first segment; `version` contributes the second **when the strategy is
`:path`** (Grape's default; `using: :header` / `:param` keeps the version out of the path, and so out
of the helper name — such an API's namespace is the bare `api_`). Both are ordinary literal arguments
in a class body whose superclass chain reaches `Grape::API`. Every helper the gem generates for that
API therefore begins `api_v4_` or `api_v3_`, and everything after is opaque.

## The decision

Treat `<prefix>_<version>_…_path` as an **open namespace**: a name the project's routes may define
but Rigor cannot enumerate, so proving it undefined is unsound and the rule must not fire.

This is not a new mechanism. It is the reasoning ADR-26 gives for `open_receivers`, the reasoning
`CheckRules#unbounded_receiver_surface?` implements for synthesized stubs — and, inside this very
plugin, the reasoning already applied to Devise's OmniAuth family, whose provider segment is supplied
at runtime (`HelperTable#omniauth_match?`).

The namespace is grounded in the project's own source, never guessed:

1. Within the configured grape directories, a class whose transitive superclass chain reaches
   `Grape::API` (or `Grape::API::Instance`) is a grape API.
2. Its `prefix` and path-strategy `version` literals compose the recognised prefixes.
3. A call matching `<prefix>_…_path` is recognised; no arity is claimed for it.

A project with no grape API declares no prefixes, and nothing changes for it.

### What this gives up, and why that is the right trade

A typo'd `api_v4_grops_path` stops firing. Against that, 68 of GitLab's 141 `unknown-helper`
diagnostics (43%) are errors on working code today. Rigor's false-positive discipline settles it: a
red error on code that runs is worse than a missed typo, and the alternative — a partial name table —
is not "teeth", it is a different set of false positives.

Teeth are retained where the gem's own contract makes them sound:

- `api_v4_anything_url` still fires. The gem defines no `_url` helper.
- A helper matching no declared grape prefix still fires.
- Rails route helpers that happen to live under a grape-shaped name are still resolved from the real
  routes table first, arity included.

## Gate

`make verify` + the plugin self-check, plus the corpus diff: GitLab `app` `unknown-helper` 141 → 73
with zero new firings and `wrong-arity` unchanged (the 3 GitLab arity firings are not grape). Redmine
and Mastodon carry no grape API, so their route diagnostics must be byte-identical.
