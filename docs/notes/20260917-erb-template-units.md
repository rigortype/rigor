# ERB templates as effect units — the false-positive measurement

Status: measurement note for [#393](https://github.com/rigortype/rigor/issues/393); no design
commitments beyond what the PR shipped. Taken against the branch `erb-template-units-393`
(base `6e4929d3`, which carries the #392 template-unit seam), Ruby 4.0.5. The two corpus projects
resolve **different compilers**, which was not planned and turned out to be the most useful thing in
the run: redmine ships a `vendor/bundle` carrying `erubi-1.13.1`, so ADR-90's resolution finds it and
compiles with Erubi; mastodon has no installed bundle, so stdlib `ERB` 6.0.1.1 compiles it.

The gate the issue sets is *"templates typing without new false positives on the Rails corpus —
`call.*` diagnostics inside templates stay off unless already justified; measure and record"*. This
note is that measurement, and it is also how four of the shipped decisions were arrived at rather than
argued — plus one property (§ 5) that the corpus demonstrated and nobody planned for.

## Method

Both corpus projects were copied out of the survey checkouts first — the survey trees are never run
in place ([`docs/agents/measurement.md`](../agents/measurement.md)):

```sh
rsync -a --exclude .rigor --exclude .git ../rigor-survey/<name>/ tmp/corpus-<name>/
```

Each copy got the same minimal `.rigor.yml` — `paths: [app]`, `plugins: [rigor-activerecord,
rigor-actionpack]`, `effects: {enabled: true}` — and was checked twice:

- **before** — with `app/views` moved aside, so the plugin's `template_globs:` matched nothing and
  the run is exactly the `.rb`-only analysis of the base commit;
- **after** — with the views back.

`rigor check --format json --no-stats` on both, differenced as
`(path, line, rule, message)` multisets. Moving the views is what makes the comparison possible
inside one worktree; the one rule it perturbs on its own is `render-target` / `missing-template`
(which reads the views directory), and nothing in either difference below is from that family.

## Result

| Project | compiler | `.erb` files | units built | diagnostics before | after | **new** | removed |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| redmine | erubi 1.13.1 | 506 | 502 | 433 | 435 | **2** | 0 |
| mastodon | erb 6.0.1.1 | 46 | 44 | 1180 | 1180 | **0** | 0 |

Both of redmine's two new rows are `plugin.activerecord.model-call` **info traces** —
`WorkflowTransition.where` in `issue_statuses/index.html.erb:29` and `IssuePriority.where` in
`users/_mail_notifications.html.erb:28`. They are correct: those templates really do issue those
queries, which is the whole point of the feature. No `call.*` row, no `flow.*` row, no parse error,
no `plugin_loader` row, on either project.

`rigor effects` after the change: redmine reports 502 `view:` units (the four templates it does not
are the layouts — see § 3), 35 of which carry an `io.db.*` row —

```
view:custom_field_enumerations/index.html: [mutate.local] ≤ [io.db.read] …? (17 reasons, --why)
view:documents/_form.html:                 [mutate.local] ≤ [io.db.read] …? (10 reasons, --why)
```

mastodon reports 44 `view:` units and no `io.db.*` row, which is the honest answer for a codebase
whose ERB surface is almost entirely admin and mailer chrome (its user-facing views are Haml, and
Haml is a different compiler — see *Not measured* below).

## What the measurement changed

Four of the shipped decisions are consequences of a run, not of a design argument. Each is recorded
because the intermediate numbers are the evidence, and they are not reconstructable from the diff.

### 1. `<%= form_with … do |f| %>` — 431 parse errors on redmine

The first run put **431 new diagnostics** on redmine, all of them parse errors on `.erb` paths, in
pairs (`unexpected ')'` + `expected a block beginning with do to end with end`). The cause is the
single most common shape in a real Rails view: an *output* tag whose Ruby opens a block. Both
compilers emit `_buf << (form_with(…) do |f|).to_s`, which is not Ruby.

Rails does not hit this because its own ERB handler carries the rule
(`ActionView::Template::Handlers::ERB::BLOCK_EXPR`) and emits the expression unwrapped. The plugin
now applies the same rule one step earlier, as a same-width rewrite of the *template* (`<%=` → `<% `)
rather than of a compiler's output, so it holds for whichever compiler resolved. Residue after the
fix: 87 of 506.

### 2. The trim markers — 87 more

Of those 87, all were `-%>` / `<%-`. Under `trim_mode: nil` stdlib ERB leaves the `-` in the emitted
Ruby, where it parses as a unary minus. Passing `trim_mode: "-"` would fix the parse but hand the
line map over to the compiler's trim rules, so the markers are blanked in the same pre-pass instead
(`<%-` → `<% `, `-%>` → ` %>`), again same-width and same-line. Residue: **4 of 506** on redmine and
**2 of 46** on mastodon.

### 3. The last few, and why a template that does not compile is declined silently

All six are layouts, and all six are `<%= yield %>` — legal ERB that Rails renders, and not legal
Ruby outside a method body.

(Under stdlib `ERB` redmine has a fifth, `app/views/issues/new.js.erb`, whose `case` tag is separated
from its first `when` tag by nothing but the newline between them — which Erubi swallows and stdlib
ERB emits as a buffer append, making the `case` illegal. Erubi compiles that one and stdlib ERB does
not, and it is the only behavioural difference the two compilers showed across 552 templates — see
§ 5.)

Reporting them would have been two parse diagnostics per file on correct templates. So the plugin
parses the compiled Ruby itself and a body that does not parse **declines the file** through the
seam's own `[]` door — no unit, no diagnostic, no effects. That is the FP-first ordering applied to
the feature's own failure mode, and it costs one Prism parse per template on the parent.

A layout therefore contributes nothing today, which is also why every declined file on both corpora
is one. That is a real gap, not a rounding error: a layout is
where `content_for` and `yield` live, so it is precisely the unit the `template → layout` edge would
need. It is [#1047](https://github.com/rigortype/rigor/issues/1047).

### 4. `flow.*` joins `call.*` in the default suppressed set

With the parse errors gone, redmine still reported **three** `flow.always-truthy-condition`
warnings, all in `app/views/common/_other.html.erb`, on the standard optional-local preamble:

```erb
<% path = nil unless defined? path %>
…
<% if path.present? %>
```

The compiled Ruby really does assign `nil` there, so the flow rules fold three live branches to
always-falsey — on a partial Rails renders correctly. The rule is right about the code it was given
and wrong about the template, and the reason is exactly the binding this slice does not synthesise:
the render site's `locals:`. Until those are traced, `flow.` is suppressed inside a template unit
alongside `call.`, and `view_type_checks: true` turns both back on together.

That is the whole of the number in the table: with `call.` alone suppressed, redmine's new-row count
is 5; with `flow.` too, it is 2, and both of those are info traces.

### 5. Both compilers ran, and their prologues differ — which is why the offset is measured

This was discovered rather than designed. redmine's `.bundle/config` sets `BUNDLE_PATH:
vendor/bundle` and that tree carries `erubi-1.13.1`, so `Isolation.require_with_target_bundle`
appends the bundle's require paths and Erubi loads; mastodon has no installed bundle and gets stdlib
`ERB`. The probe measures:

| compiler | prologue offset | 4-line template's map |
| --- | ---: | --- |
| erubi 1.13.1 | 0 | `{1=>1, 2=>2, 3=>3, 4=>4}` |
| erb 6.0.1.1 | 1 | `{2=>1, 3=>2, 4=>3, 5=>4}` |

A hardcoded offset would have been right for exactly one of the two, and wrong by one line on every
finding in every template of the other — silently. Both maps are exact for the multi-line-tag case
(`<%= b(\n 1) %>`), which is the shape that would expose a compiler that re-flows lines.

### Two known under-reads, recorded rather than fixed

Neither costs a false positive — both leave an ivar unseeded, which reads as `Dynamic` and is silent —
and both are the every-path rule being conservative in a place it did not have to be:

- `return unless @u = User.find(1)`-shaped guards, and any assignment after an early `return`, are
  taken as every-path on the fall-through, which is right for the fall-through and is the one case
  where the rule is *less* conservative than it looks. Rare in a controller action.
- assigns made inside `respond_to do |format| … end` are dropped, because a block may not run. In
  Rails it always does, so this loses real seeds on format-dispatching actions.

## Not measured, deliberately

- **Haml / Slim.** mastodon's user-facing views are Haml. `template_globs:` claims `*.erb` only, so
  they are invisible here; the design note (§ 11.3) has them as the same seam behind a different
  compiler.
- **Pooled versus sequential, for diagnostics.** The effect table is identical between
  `RIGOR_RACTOR_WORKERS=2` and sequential on both projects (redmine: the same 502 `view:` rows, 35
  with `io.db.*`). The diagnostic stream is not, by one row, and the row is
  rigor-activerecord's missing-schema notice — whose once-per-run flag is per plugin instance and
  therefore per worker. That duplicate is present on `master` (434 vs 433 with the views moved
  aside); what template units add is that a worker whose chunk starts with a view positions its copy
  at an `.erb` path. Filed as [#1051](https://github.com/rigortype/rigor/issues/1051).
- **`views: lenient` vs `views: strict`.** The two stanzas are documented in
  [`docs/manual/plugins/rigor-actionpack.md`](../manual/plugins/rigor-actionpack.md) and the
  machinery underneath them works — a view unit is now an `effects.envelopes:` subject and a finding
  is positioned in the template. But the two presets do not yet *differ* in behaviour, because
  `io.db.read` arriving from a plugin attribution rides the **declared** lane and
  `Effects::EnvelopeCheck` reads the proven one. That is a property of the Rails effect layer as a
  whole — `UsersController#index` reports `[mutate.self] ≤ [io.db.read]` for a plain `User.find` too
  — not of templates, so it is filed separately as
  [#1048](https://github.com/rigortype/rigor/issues/1048) rather than worked around here.
