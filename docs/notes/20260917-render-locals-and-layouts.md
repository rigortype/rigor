# Render-site locals and layouts — corpus measurement

Status: measurement note for [#1047](https://github.com/rigortype/rigor/issues/1047). Taken against the
branch `render-locals-and-layouts-1047`, base `63bbfa33` (which carries #393's ERB template units, #1053's
`ProjectScan` index and #1057's controller → template edge), Ruby 4.0.5.

Two halves the design note
([`20260816-effect-labels.md`](../design/20260816-effect-labels.md) § 11.3) names and #393 left out, and
they are one piece of work seen from two sides: tracing a render site's `locals:` is what lets the `flow.`
rules back into a view, and making `<%= yield %>` compile is what gives a layout a unit.

The interesting result is a **negative** one, and it is the whole point of the slice: the family that was
suppressed for a measured reason can be un-suppressed, and the corpus does not move by a byte.

## Method

Identical to [the #1048 note](20260917-controller-template-edge.md) § Method, which is where the bundler
invocation `measurement.md` is missing lives. Private copies, never run in place:

```sh
rsync -a --exclude .rigor --exclude .git ../rigor-survey/<name>/ tmp/corpus/<name>/
```

Both copies got the same minimal `.rigor.yml` — `paths: [app]`, `plugins: [rigor-activerecord,
rigor-actionpack]`, `effects: {enabled: true}` — and both arms ran under the same Flake shell and the same
bundle, with `.rigor` removed before each:

```sh
cd tmp/corpus/<name> &&
BUNDLE_GEMFILE=<w>/Gemfile BUNDLE_APP_CONFIG=<w>/.bundle BUNDLE_PATH=<w>/vendor/bundle \
  bundle exec <w>/exe/rigor check --format json --no-stats --no-cache
```

The **before** arm is the base commit's working tree; the **after** arm is this branch. Both compilers are
still in play and it is still luck rather than planning: redmine's `.bundle/config` resolves
`erubi-1.13.1` out of its own `vendor/bundle`, mastodon has no installed bundle and compiles with stdlib
`ERB` 6.0.1.1.

Four arms were taken rather than two, because the posture change is the result:

| arm | suppressed set |
| --- | --- |
| `before` | `["call.", "flow."]` — what `master` ships |
| `before-flow` | `["call."]` — `master`, with the family that #1047 is about turned back on |
| `after` | `["call.", "flow."]` — this branch, old posture |
| `after-flow` | `["call."]` — **this branch, what ships** |

## 1. The false-positive gate

`rigor check --format json --no-stats --no-cache`, differenced as `(path, line, rule, message)` multisets
— and, as it turned out, byte for byte.

| Project | `before` | `before-flow` | `after` | **`after-flow` (shipped)** |
| --- | ---: | ---: | ---: | ---: |
| redmine | 435 | **438** | 435 | **435** |
| mastodon | 1180 | 1180 | 1180 | **1180** |

`before-flow` is the three false positives #393 measured, reproduced exactly:

```
app/views/common/_other.html.erb:5  flow.always-truthy-condition  condition is always falsey …
app/views/common/_other.html.erb:7  flow.always-truthy-condition  condition is always falsey …
app/views/common/_other.html.erb:11 flow.always-truthy-condition  condition is always falsey …
```

`after-flow` is **byte-identical to `before`** on both projects — the same 172 398 and 475 466 bytes of
JSON. So the family that was suppressed because of one missing binding reports nothing once the binding
arrives, and `flow.` leaves `SUPPRESSED_VIEW_RULES`. The suppression was a stand-in, not a preference.

That `after` and `after-flow` are also identical is the same statement from the other side: the only
`flow.` rows a template produced on either corpus were the three, and they are gone.

**Layouts cost nothing here either.** redmine compiles four templates it used to decline and mastodon two,
and neither project gains a diagnostic — no parse error, no `call.`, no `plugin_loader` row. That was the
one thing a layout could plausibly have broken, since a layout is the template whose body is least like a
method's.

### What the locals index actually found

| Project | render targets seen | names seeded | of those, concretely typed |
| --- | ---: | ---: | ---: |
| redmine | 131 | 100 | 2 |
| mastodon | 60 | 4 | 0 |

The `typed` column is meant to be small. A type is a claim the engine acts on, so it is settled only from
what the call itself says — a non-nil-able finder or constructor on a constant, or an ivar the rendering
action's own seeds already typed — and only when every site that passes the name agrees. Everything else is
a NAME with no type, which is exactly what the false positives needed: `path` had to be *bound*, not
*known*. mastodon's 60 targets against 4 names is the Haml gap showing through — most of its render sites
name templates this plugin never compiled.

`common/_other` seeds `{kind, path, download_link}`, all `Dynamic`, from three sites — and the third of
them (`common/_pdf.html.erb`'s bare `render :partial => 'common/other'`) passes **none** of them. That is
the union rule doing the work it exists for: a name bound at only some sites is seeded anyway. Had the
index required agreement on presence, the measurement above would read 438.

## 2. Layouts, and what the edge reaches

`rigor effects --format json --full`, `before` against `after-flow`.

| Project | `view:` units, before → after | layout units | `template-not-analysed`, before → after |
| --- | ---: | ---: | ---: |
| redmine | 502 → **506** | 5 | 148 → **140** |
| mastodon | 44 → **46** | 2 | 329 → 329 |

redmine's five layout units are `view:layouts/base.html`, `layouts/admin.html`, `layouts/mailer.html`,
`layouts/mailer.text` and `layouts/_file.html` — the last a partial-layout, which is what a view's
`render layout:` names (`RenderingHelper#render` rewrites `layout:` to `partial:` when a block is given,
which is the reading [#1057](https://github.com/rigortype/rigor/issues/1057) already took). Four of them
are new; `layouts/mailer.text` compiled before, having no `yield`.

**Eight of redmine's `ActionView::Base#render` taints discharge**, 72 → 64, and all eight are the same
shape — the six `attachments/*.html.erb` views plus `layouts/admin.html` doing
`render :layout => 'layouts/file'`, and `AttachmentsController#show` inheriting one of them by
propagation. Every one of them is a layout render that previously pointed at a declined file.

mastodon discharges nothing, which is the right answer: its two layouts are rendered by the Rails layout
machinery rather than by an ERB `render layout:`, and 310 of its 356 views are Haml.

**What is still not edged, and deliberately.** The layout Rails wraps an *action's* template in —
`layouts/application`, or whatever `layout "base"` named — gets no edge. A callee rule may read the call's
argument literals, the unit's owner class and the unit's own key
([`callee_rule.rb`](../../lib/rigor/effects/callee_rule.rb)), and a layout's name is none of the three: it
is a class-body declaration plus a convention lookup against the view tree, inherited through the
controller hierarchy. Reading it would make a plugin row's meaning a function of the view tree, which is
the thing that module's comment says the scan must not do. Naming `layouts/application` unconditionally was
considered and refused for a reason the corpus makes concrete: redmine's `ApplicationController` declares
`layout 'base'`, so the guess would have been wrong for all 506 of its templates and right only by
accident elsewhere.

## 3. Determinism

`rigor effects --format json --full` on redmine is **byte-identical** between `RIGOR_RACTOR_WORKERS=2` and
sequential — the same 3 537 106 bytes (3 533 152 at the review head, § 5), the same 506 `view:` rows, the
same 140 residual taints. Nothing in
this slice adds a field to an edge or to a unit, so the #1057 sort-key hazard does not recur; the
measurement is the negative control for the two indexes, which run on the parent and reach a worker only as
already-frozen `TemplateUnit` data.

## 4. Two decisions the measurement made

### The `yield` rewrite is a rewrite of the template, not of the seam

The seam deliberately does not wrap a unit's body in a synthesised method
([`macro-substrate.md`](../internal-spec/macro-substrate.md) § Positions: a wrapper shifts every line and
composes a second map onto the plugin's). So a body that must *parse as written* has to be *rewritten as
written*, in the same pre-pass `BLOCK_EXPR` and the trim markers already live in: the `yield` keyword
inside an ERB tag becomes `__rigor_yield`, an ordinary implicit-self call on the synthesised view context,
declared in the plugin's bundled `sig/action_view.rbs` as `(*untyped) -> String`.

Unlike the other two rewrites this one is **not width-preserving**, and it does not need to be — a unit
whose `line_map` is non-empty reports at column 1 by construction
(`Analysis::TemplateUnits#remap`). The line map over a rewritten layout is still exact, pinned by spec.

`String` is the widest honest reading and the narrowest thing that is not a fabrication. Rails' `yield`
returns whatever the inner template's buffer holds and `yield :sidebar` returns a `content_for` buffer —
an empty `SafeBuffer` when nothing was provided, never nil; anything more specific would be the `Parameters#[]` trap one layer up. `content_for?(:x)` needed
nothing — it was always an ordinary method call on an open receiver.

### The index compiles once for two readers

Building the render-locals index reads and compiles every template, and `#template_units_for_file` was
about to compile each of them again. The builder therefore keeps what it compiled, keyed by path and
guarded by the template's own scrubbed bytes, and the unit hook reuses it — so a full `rigor check` does
exactly the compile work it did before this feature, one pass instead of two, and an editor buffer (whose
bytes differ) falls through to its own compile rather than being served a stale unit.

That claim was wrong in the first draft of this note, in the other direction: a publish did **not** rebuild
the index, because the index is memoised on the plugin instance a long-lived `ProjectContext` keeps — so
the real cost was **staleness**, and review found it (§ 5).

## 5. What review found that the corpus could not

Both are shapes neither corpus writes, and both would have cost a correct template a finding.

### Render sites the index cannot read

With `flow.` reporting, the standard optional-local preamble still fired `flow.always-truthy-condition` on a
partial whose render sites the index cannot see: `locals: { **opts }`, `locals: some_hash`, a `render` in
`app/helpers/*.rb` (never scanned), and — most ordinary of all — an optional local with a default that *no*
site passes. The corpus did not hit any of them, which says more about redmine's style than about Rails.

The fix is in the same over-binding spirit as the union: a template that writes `defined?(path)`,
`defined? path`, `local_assigns[:path]` or `local_assigns.key?(:path)` (and `fetch` / `has_key?` /
`include?`) is *declaring* `path` an optional local, and that declaration needs no render site. Every such
name is seeded `Dynamic` (`ViewUnits.self_declared_locals`), beneath the render-site seeds and the
strict-locals comment. All four shapes are pinned silent under the default posture, and each fails with the
declaration reading switched off — so `flow.` stays unsuppressed.

Re-measured at the review head, `rigor check` is still **byte-identical to `before`** on both projects (the
three `_other.html.erb` names were already bound by their render sites), mastodon's effect table is
unchanged, and redmine's moves in exactly one way: **52 units lose a spurious
`unresolved-self-call` cause** — 51 `filedrop` and 1 `thumbnails` — because `attachments/_form.html.erb` and
`attachments/_links.html.erb` test `defined?(filedrop)` / `defined?(thumbnails)`, and a tested local was being
read as a call on the view context and propagated into every controller action that renders an attachment
form. No label moves, no `exhaustive` flips, and `template-not-analysed` stays 140. Pooled == sequential still
holds byte for byte (3 533 152 bytes).

### A memo that outlived the render site

`@render_locals ||=` lives on the plugin instance, and a `LanguageServer::ProjectContext` keeps that instance
across publishes (an `invalidate!` builds a fresh one, so a save — which fires `didChangeWatchedFiles` —
always did recover). Meanwhile #1038's carry revalidated each template against its *own* bytes. Drop a local
in `show.html.erb` on disk without the editor seeing a save — a `git checkout`, a formatter, another tool —
and `_card`'s unit kept the seed through every publish until something invalidated: a `flow.` row with no
cause on disk.

Two halves, both needed, both pinned (each spec fails with its half reverted):

- **The collector decides a plugin's carry for its whole claim.** If any of its templates was edited, added
  or deleted, none of its units is carried — because a transform may read its plugin's other templates, a
  template's own freshness cannot vouch for its unit. The editor's buffer is exempt, so this never costs a
  keystroke, and it only bites on an on-disk edit the owner has not invalidated for (a save invalidates and
  rebuilds cold anyway); measured on redmine, the recompile is 0.1–0.3 s. A template read with no unit
  (declined) is carried as a bare stat pack, so one layout the plugin cannot compile does not read as an edit
  on every run. The one change the rule does not see is the *deletion* of such a declined template, which
  had contributed nothing a sibling could read.
- **The plugin revalidates its indexes once per collection pass** against a fingerprint of every controller,
  helper and template they read (a glob and a `stat` per file; a byte-identical `touch` rebuilds the index,
  which costs a rebuild and never a wrong answer). The pass is announced by a new engine hook,
  `Plugin::Base#template_units_pass_started`, and the check runs at that pass's first
  `#template_units_for_file`. A second review round showed that inferring the pass from the order of paths is
  not enough — a warm pass offers only the editor's buffer, so switching buffers after an on-disk edit was
  served stale whichever way the two paths sorted — and revalidating when the edited template's own bytes
  arrive would be too late: `_card.html.erb` globs before `show.html.erb`.

### A helper tested with `defined?`

`<% if defined?(current_user) && current_user %>` in a shared partial tests a *helper*, not an optional
local, and seeding it would turn every later `current_user` from a call into a `Dynamic` read. Names a
project helper `def`s under `app/helpers` are therefore not seeded; a helper a gem or a concern defines is not
seen by that scan and still is — `Dynamic` either way today, since the view context does not resolve project
helpers yet. `defined?` also only names a local when the name is its whole operand (`defined?(link_to "x",
y)` names nothing), and `<%#` comment tags are not read.

What remains is stated in the manual: an unsaved `locals:` does not reach its partial until the save,
because the index reads from disk.

## Not measured, deliberately

- **Haml / Slim / Jbuilder.** Still the same seam behind a different compiler, and mastodon is still the
  measurement of what not claiming them costs — now with the extra reading that 56 of its 60 render targets
  name a template this plugin never compiled.
- **The `.js` → `.html` format fallback** ([#1065](https://github.com/rigortype/rigor/issues/1065)),
  which is the largest single remaining gap in the edge and is untouched here: redmine's
  `ActionView::Base#render` residue is 64, of which the 34 `.js.erb`-rendering-an-HTML-partial units
  #1057 counted are the bulk.
- **A controller's `layout` declaration as an edge** — § 2 above.
- **`view_type_checks: true` on the corpus.** It turns `call.` on, which #393 already measured, and this
  slice does not change what that family sees beyond the locals it now binds.
