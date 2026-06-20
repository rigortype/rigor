# SKILL-driven onboarding (`rigor-next-steps`) — conference-app dogfood + rigor-survey field trial

Date: 2026-06-20. Status: **field-trial report.** Records the first
real-project exercise of the [ADR-73](../adr/73-skill-driven-user-experience.md)
SKILL-driven user experience — the `rigor-next-steps` entry point + live
`rigor skill describe` + the catalogue skills — against
`~/repo/ruby/conference-app` (a Rails 8.1 app) and a 6-project
`~/repo/ruby/rigor-survey` slice. The point of the exercise is **feedback
on the UX**, not a diagnostic survey: what worked, what was friction, and
what to improve before the surface freezes.

## What was exercised

The full arc an agent drives from a single entry point:

```
describe (state probe) → project-init (onboard) → check / coverage (value)
  → protection-uplift (hand-RBS under the double gate)
  → full onboard (widen paths, baseline, regression guard)
  → describe again (recommendation advances)
```

## Part 1 — conference-app (Rails 8.1, 244 .rb, rbs_rails + Steep + rbs-inline)

A real, type-conscious Rails app: `sig/` (generated + handwritten +
rbs_rails + shims), a committed `rbs_collection.lock.yaml`, a `Steepfile`,
rbs-inline `# @rbs` annotations, `.vscode/`, `.github/`. No Rigor config.

### The arc, with numbers

1. **`rigor skill describe`** read the project correctly with zero
   analysis: `config none → recommend rigor-project-init`, `sig/ present`,
   `Community RBS collection installed`, `CI present, Rigor not wired`,
   `.vscode present, Rigor LSP not wired`. The presence probe was accurate
   on every axis.
2. **Onboard (`rigor-project-init`).** Wrote a scoped `.rigor.dist.yml`
   (`target_ruby: "3.4"`, the individual Rails plugins, `rigor-rbs-inline`).
   `rigor plugins` → **7 plugins active, 0 errors**. Rigor consumed the
   project's own `sig/` (353 RBS classes).
3. **`rigor check lib`** → **no bugs** (the rbs-inline + `sig/` investment
   pays off). **`rigor coverage --protection lib`** → **17.5 % (7/40)**,
   with a precise "add a type here" list naming the two `Dynamic` sources:
   Faraday (`client.get(...).body`, `#post`, `#response`) and the
   `Rails.configuration.x.tito.*` dynamic chain. Both API-client files 0 %.
4. **`rigor-protection-uplift` on `app/decorators`** (M0 = 13.0 %, 3/23):
   sig-gen first offered one signature
   (`TalkDecorator#hashtagged_twitter_intent_url: () -> String`); the
   measurable residual was `Commonmarker.to_html` (3 sites, an external gem
   with no RBS). A **7-line true RBS** (`def self.to_html: (String,
   ?options: untyped, ?plugins: untyped) -> String` — tighten the return,
   keep params lenient) → **double gate held: protection 13.0 % → 26.1 %
   (+3 sites), `check` stayed `No diagnostics`.**
5. **Full onboard** (`paths: [app, lib]`, 101 .rb): **269 diagnostics =
   9 error + 260 info.** The 260 info are the Rails plugins *positively
   resolving* framework magic (AR finders 68, route helpers 67, ActionPack
   helpers 62, strong-params 34, i18n 13) — proof the plugins understand
   the app. The **9 errors are genuine**, RBS/Steep-invisible,
   framework-semantic bugs:
   - **strong-params keys that are not columns** (6): `start_date_jst →
     :start_date`, `end_date_jst → :end_date`, `start_at_date` /
     `start_at_time → :start_at`, `content`, `page_image` (some are
     legitimate virtual attrs — review-gated);
   - **missing / doubled i18n keys** (3): incl.
     `sample_webpush_notifications.create.sample_webpush_notifications.create.title`
     — a clearly doubled namespace = real bug.
6. **Acknowledge-mode baseline** (`rigor baseline generate` → 128 buckets /
   269) + `baseline:` wired → re-check **No diagnostics**. **Regression
   guard proven:** a deliberately injected `I18n.t("…not.a.real.key…")`
   surfaced immediately as a fresh error (then reverted).
7. **`describe` re-run** with config present → recommendation **advanced
   `project-init → ci-setup`**. The loop closes; the entry point is live.

### What worked (conference-app)

- **The presence probe is accurate and cheap.** Every state axis matched
  reality; running `rigor check` was never needed to route.
- **State-aware routing advances.** project-init → ci-setup after onboard;
  the "always current" promise held end to end.
- **The Rails plugins are the headline value.** 260 framework resolutions
  + 9 genuine bugs that the app's existing RBS/Steep did not catch.
- **The protection-uplift double gate is real.** A minimal true type
  doubled local protection at zero diagnostic cost, and the skill's
  "honest bounds" correctly predicted the residual (external-gem Dynamic).
- **Rigor consumes the project's own typing** (`sig/`, `rbs_collection`,
  rbs-inline) without ceremony.

### Friction / what did not work (conference-app)

- **`rigor-rails` is an umbrella that cannot be listed as one plugin.**
  Listing `plugins: [rigor-rails]` fails: *"registered multiple plugins
  (actionmailer, actionpack, activejob, activerecord, factorybot,
  rails-i18n, rails-routes); disambiguate with an explicit `id:` field."*
  The intuitive choice is the trap. Had to expand to the individual gems.
  → **Improvement candidate:** make the umbrella gem auto-activate its
  bundled plugins, or have `rigor-project-init`'s plugin table never
  suggest `rigor-rails` as a single entry.
- **rbs-inline usage was not auto-suggested.** The app is full of `# @rbs`
  comments, but nothing prompted enabling `rigor-rbs-inline` — I knew to
  add it. → `describe` / project-init could detect `# @rbs` / `#:` comments
  (or the `rbs-inline` gem in the lockfile) and recommend the plugin.
- **info-level plugin-resolution noise dominates.** 260/269 diagnostics
  are positive resolutions; the baseline captured all 269 incl. info.
  → Consider info plugin-notes off by default, or excluded from the
  baseline (they neither gate nor regress).
- **From-source invocation is fragile (tooling, not the product).**
  Running the repo's `exe/rigor` against an external project via
  `ruby -Ilib` *silently breaks* `check`: it bypasses Bundler, so the
  bundled plugins are off the load path AND a global `~/.gem` rbs native
  extension (built for another Ruby) is picked up → `LoadError`. The fix
  is `bundle exec` with **absolute** `BUNDLE_GEMFILE` *and* `BUNDLE_PATH`
  (the repo's `BUNDLE_PATH: vendor/bundle` is relative and breaks on
  `cd`). This is a *dogfood-from-source* artifact — an end user on a
  `mise`/`gem install` install just runs `rigor` in their project — but
  the survey/dogfood recipe must spell it out.

### Artifacts written to conference-app (uncommitted, separate repo)

`.rigor.dist.yml`, `.rigor-baseline.yml`, `sig/handwritten/commonmarker.rbs`,
`.rigor/` (cache — gitignore if kept).

## Part 2 — rigor-survey field trial (6 Sonnet subagents)

Method: one Sonnet subagent per project, each following the
`rigor-next-steps` flow from the same from-source recipe, reporting
structured findings (state → recommendation → onboard → check → protection
→ worked / friction / improvement). Projects chosen for shape diversity:

| Project | Shape |
| --- | --- |
| `faraday` | plain gem, Gemfile.lock, no sig, no config |
| `haml` | typed gem (sig), Gemfile.lock, no config |
| `rgl` | small typed gem (sig), no config |
| `liquid` | plain gem, already configured |
| `strap` | small Rails app, Gemfile.lock |
| `redmine` | large Rails app, sig + config |

### Per-project results

| Project | describe probe | headline rec | onboard | check (files / errors) | protection | one-line takeaway |
| --- | --- | --- | --- | --- | --- | --- |
| `faraday` | accurate (7/7) | `rbs-setup` | wrote (no plugins) | 33 / 6 (nil-recv + `Options` DSL) | 24.0 % | `target_ruby` Prism-floor footgun; rec ignores the 6 errors |
| `haml` | accurate; advanced init→rbs-setup | `rbs-setup` | wrote (no plugins) | 51 / **55** (own-`sig/` gaps) | 38.4 % | 55 errors present → should route to `baseline-reduce`, not `rbs-setup` |
| `rgl` | accurate; advanced init→rbs-setup | `rbs-setup` | wrote (no plugins) | 28 / ~50 (**`pre_eval` cluster**) | 37.0 % | dominant cluster is monkey-patch → should route to `monkeypatch-resolve`; rest are generic-type-param holes (intractable) |
| `liquid` | accurate | `rbs-setup` | pre-existing config | 63 / 1 (genuine nil) | 30.7 % | `rbs-setup` before `ci`/`baseline` "feels backwards" on a configured project; absolute `cache.path` not portable |
| `strap` | accurate | `rbs-setup` | pre-existing (`rigor-sorbet` only) | 6 / 0 | 17.0 % | Rails app with **no Rails plugins** → `plugin-tune` is the bigger win than `rbs-setup`; non-existent `lib` path → exit 1 |
| `redmine` | accurate (incl. "no Gemfile.lock") | `ci-setup` | pre-existing config | 86 / RBS env **FAILED** (`DuplicatedDeclarationError` → 0 classes) | 15.5 %* | broken `sig/` makes "configured" hollow; describe says "sig/ present" + routes to CI → would wire a 0-coverage analysis. *ratio is a floor |

Every fresh project that wrote a config saw the recommendation **advance** (init → rbs-setup). The probe was **accurate on every axis in all 6** + conference-app (7/7).

## Aggregate feedback (synthesis)

### ✅ What worked (consistent across all 7 projects)

- **The presence probe is accurate and cheap — 7/7.** Every state axis (config / baseline / `sig/` / Community RBS / CI / LSP / MCP) matched reality on every project. Routing never needed to run `rigor check`.
- **State-aware advancement holds.** Fresh projects flipped `project-init → rbs-setup` the moment a config landed.
- **`coverage --protection` is the most-praised surface.** Per-method call counts + `file:line` examples + least-protected file ranking = "immediately actionable" (said independently by 5 agents).
- **Real, RBS/Steep-invisible bugs surfaced** on every project that had any: conference-app strong-params + doubled-i18n; faraday possible-nil + `Options`-DSL; haml monkey-patch + struct-arity; liquid profiler nil; rgl override-substitutability.
- **Diagnostic messages are actionable** — the `pre_eval:` misses *name the exact file to list* and cite ADR-17 (faraday, haml, rgl all called this out).
- **The Rails plugins are the headline value** where they apply: 260 framework resolutions + 9 genuine bugs on conference-app; i18n resolution across 47 locales on redmine.

### ⚠️ Recurring friction (ranked by how often it recurred)

1. **[5/7] `describe`'s recommendation is presence-only and ignores what `check` would reveal.** The single dominant finding, surfaced independently. The tree recommends `rbs-setup` whenever `Gemfile.lock ∧ no collection`, but the *apter* next step was repeatedly something else: `baseline-reduce` (haml, 55 errors), `monkeypatch-resolve` (rgl, a `pre_eval` cluster), `plugin-tune` (strap, a Rails app with no Rails plugins), `doctor` (redmine, a broken `sig/`). Agents phrased it as "based only on static filesystem signals, not on whether check/coverage ran" and "`rbs-setup` front-loads a network task before the user has seen any findings." This is the direct tension with **[ADR-73](../adr/73-skill-driven-user-experience.md) WD2's presence-only / never-runs-`check` guardrail** — the guardrail keeps `describe` fast and side-effect-free, but the field trial shows the best recommendation often needs the check result.
2. **[2/7, but hard-blocks] `target_ruby` Prism-floor footgun.** No `.ruby-version` → infer from gemspec; `"3.0"` / `"3.2"` pass the config-format validator but Prism rejects them mid-`check` ("invalid version") with no hint of the floor (`3.3`). Both agents burned cycles guessing. (faraday, haml.)
3. **[redmine, high severity] `describe` reports a broken `sig/` as healthy.** A `RBS::DuplicatedDeclarationError` drops the env to 0 classes — analysis is hollow — yet `describe` says "sig/ present" and routes to `ci-setup`. A user would wire a zero-coverage analysis into CI.
4. **[conference-app] the `rigor-rails` umbrella trap.** Listing `plugins: [rigor-rails]` fails ("registered multiple plugins; disambiguate with `id:`"). The intuitive choice is the wrong one.
5. **[rgl, liquid, strap] `rbs-setup` is over-recommended.** For a gem whose only no-RBS gems are dev/test tooling (rgl: rake/yard/simplecov); on a configured project where `ci`/`baseline` is more actionable first (liquid); for a Rails app where `plugin-tune` yields more than community RBS (strap).
6. **[rgl, faraday, strap, conference-app] coverage holes are often intractable kinds.** Generic-type-param calls (rgl `Graph[V,E]` weights), framework-DSL sites (`#returns` Sorbet, `Options.new` DSL), external-gem Dynamic (conference-app Faraday/Commonmarker). The "add a type here" list mixes these in with fixable holes, so users may chase what sig-gen/hand-RBS cannot close.
7. **[smaller, scattered]**: the "N gems have no RBS" info anchored at `.rigor.yml:1:1` reads oddly mixed with code diagnostics (conference-app, liquid); a non-existent path → exit 1 instead of warn-and-skip (strap); absolute `cache.path` in shared configs is not portable and isn't flagged (liquid, strap); `rigor describe` (without `skill`) is "Unknown command" (liquid); rbs-inline `# @rbs` usage isn't auto-suggested as a plugin (conference-app); no "config just written" acknowledgement (faraday).

### 💡 Prioritized improvements

- **P1 — Make the headline recommendation check-aware, without breaking WD2.** Resolve the presence-only tension with an *opt-in deep mode* or a *zero-cost cache read*, not by making default `describe` run `check`:
  - read the last `rigor check` result from the existing `.rigor/` cache when present, and route on its error clusters (errors → `baseline-reduce`; a `pre_eval` cluster → `monkeypatch-resolve`; Rails gems locked but no Rails plugins configured → `plugin-tune`);
  - or a `rigor skill describe --deep` that runs a scoped check first.
  This is the field trial's headline feedback and likely an **ADR-73 follow-up / new working-decision** (it revisits WD2's guardrail deliberately).
- **P2 — Validate `target_ruby` against Prism's floor at config-load** with a message naming the minimum and where to read it (`Gemfile.lock` `RUBY VERSION` / `.ruby-version`); have `rigor-project-init` auto-detect from `required_ruby_version` and clamp.
- **P3 — `describe` (or `doctor`, promoted) must detect a failed RBS env build** — surface "sig/ ⚠️ build error" instead of a green "present", and have `coverage`/`check` print a banner when `RBS classes available: 0` so the ratio isn't read as real.
- **P4 — Fix the `rigor-rails` umbrella** — auto-activate its bundled plugins, or have `project-init` never emit it as a single `plugins:` entry.
- **P5 — Soften `rbs-setup`'s priority** — deprioritize when the no-RBS gems are all dev/test-group, when a Rails app has unconfigured Rails plugins (prefer `plugin-tune`), and on already-configured projects (prefer `ci`/`baseline` before a network-bound `rbs collection install`).
- **P6 — Label coverage holes by tractability** — mark generic-type-param / framework-DSL sites in the "add a type here" list so users don't chase what hand-RBS can't close.
- **P7 — Small wins** — warn-and-skip non-existent paths; move the "gems-without-RBS" advisory off `.rigor.yml:1:1`; flag non-portable absolute `cache.path`; alias bare `rigor describe`; auto-suggest `rigor-rbs-inline` on `# @rbs` detection.

### Method caveat

The from-source invocation friction (Part 1) is a **dogfood artifact**, not a product issue — every subagent had to be handed the exact `bundle exec` + absolute `BUNDLE_GEMFILE`/`BUNDLE_PATH` recipe, and even so one agent's reflex `ruby -Ilib` would have broken `check`. An end user on a `mise`/`gem install` install just runs `rigor` in their project. But it confirms the survey/dogfood recipe must be written down (now it is, here).

### Survey artifacts (uncommitted)

The subagents wrote `.rigor.dist.yml` to the three fresh projects (`faraday`, `haml`, `rgl`); `liquid`/`strap`/`redmine` used pre-existing configs. None committed.
