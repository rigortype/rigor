---
name: rigor-project-init
description: |
  Onboard a project to Rigor type-checking from scratch: detect the stack, choose an adoption mode (baseline vs. strict), select plugins, write `.rigor.dist.yml`, then snapshot a baseline or commit to a zero-diagnostic gate. Triggers: "set up Rigor in this project", "configure rigor for X", "add type checking", or running `rigor check` in a Gemfile directory with no `.rigor.yml`. NOT for reducing an existing baseline (use rigor-baseline-reduce) or authoring a plugin (use rigor-plugin-author).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Project Init

End-to-end onboarding for a project that has never run Rigor. The
output is a committed `.rigor.dist.yml`, an explicit adoption mode,
and — if the project chooses it — a `.rigor-baseline.yml` snapshot.

This skill is for **users adopting Rigor on their own project**. It
uses the published `rigor` executable, installed standalone — Rigor
is a tool, not a library, so it does **not** go in the project's
`Gemfile`. See the manual's
[Installing Rigor](../../docs/manual/01-installation.md)
chapter for the install channels (`mise` recommended). This skill
references only public CLI flags and config keys — the same surface
`rigor --help` documents.

## Phase 0 — When to use this skill

Trigger when the user says "set up Rigor here", "configure rigor for
this app", "add type checking", or runs `rigor check` in a project
that has no `.rigor.yml` / `.rigor.dist.yml`.

Do NOT trigger for:

- **An existing baseline the user wants to shrink** — that is the
  `rigor-baseline-reduce` skill.
- **Writing a Rigor plugin** for the project's own DSL /
  metaprogramming — that is the `rigor-plugin-author` skill. (This
  skill *points at* plugin authoring as an escalation in Phase 7;
  it does not do it.)
- **Tweaking an already-configured project** — ordinary edits to an
  existing `.rigor.yml`; no onboarding pipeline needed.

## Note — plugin installation

All `rigor-*` plugins ship **bundled inside the `rigortype` gem**.
No separate installation is needed. Listing a plugin under
`plugins:` in `.rigor.dist.yml` is sufficient to activate it.
The project's `Gemfile` is untouched by this workflow.
See [`references/02-configure.md`](references/02-configure.md)
§ "No separate installation needed" for detail.

## The central decision — adoption mode

A mature Ruby codebase routinely reports hundreds to thousands of
diagnostics the first time `rigor check` runs. Most are not fresh
bugs: some are real-but-empirically-safe (`T | nil` that production
always initialises), some are project style, a minority are genuine
latent bugs. Forcing every site to zero before adoption blocks
adoption entirely.

So **before writing any config, present the user with two modes**
and let them choose. The mode drives the severity profile, whether a
baseline is generated, and how Phase 7 frames the leftover
diagnostics.

| | **Acknowledge mode** (baseline adoption) | **Strict mode** (no compromise) |
| --- | --- | --- |
| Goal | Adopt Rigor now; make sure *ordinary coding does not increase* the diagnostic count. | Drive the project to zero outstanding diagnostics and keep it there. |
| Today's diagnostics | Snapshotted into `.rigor-baseline.yml`; suppressed as long as the count does not grow. | All surfaced; every one is fixed or consciously suppressed. |
| Hard-to-fix diagnostics | Left in the baseline. The project **trusts its test / spec suite** to cover runtime correctness for those sites — the static `T | nil` reading is worst-case-sound, the suite proves the worst case is not hit. | Fixed, or annotated `# rigor:disable <rule>` with an author-intent reason at the specific line. No blanket suppression. |
| `severity_profile` | `lenient` (or `balanced` for a small project). | `strict`. |
| Best for | Mature codebases; incremental adoption; teams that want the regression guard without a big upfront fix. | New / small projects; libraries; teams that want the maximum guarantee and have the budget to reach zero. |
| New diagnostics later | Surface immediately — anything beyond the baseline envelope is a regression. | Surface immediately — there is no envelope; every diagnostic is live. |

Both modes give the same core guarantee: **a change that introduces
a new diagnostic is caught.** They differ only in what happens to the
diagnostics that exist *today*. Acknowledge mode parenthesises them
behind a baseline and leans on the test suite; strict mode refuses to
parenthesise anything.

If the project's first `rigor check` reports more than ~100 errors,
recommend acknowledge mode as the default and let the user override.
Below that, either mode is reasonable — ask.

## Phase outline

| Phase | What | Reference |
| --- | --- | --- |
| 1 | Detect the project shape (Gemfile / Gemfile.lock walk). | [`references/01-detect.md`](references/01-detect.md) |
| 2 | Present the two adoption modes; record the user's choice. | (this file — § "The central decision") |
| 3 | Select the plugin set matching the detected stack. | [`references/01-detect.md`](references/01-detect.md) |
| 4 | Write `.rigor.dist.yml` — severity profile follows the mode. | [`references/02-configure.md`](references/02-configure.md) |
| 5 | Generate initial RBS sigs; uplift attr_reader precision with `--params=observed`. | [`references/04-sig-uplift.md`](references/04-sig-uplift.md) |
| 6 | Run `rigor triage --format json` to diagnose the diagnostic stream. | [`references/03-baseline-and-bugs.md`](references/03-baseline-and-bugs.md) |
| 7 | Acknowledge mode only — generate the baseline and wire `baseline:`. | [`references/03-baseline-and-bugs.md`](references/03-baseline-and-bugs.md) |
| 8 | Surface likely real bugs; offer the two escalation paths. | [`references/03-baseline-and-bugs.md`](references/03-baseline-and-bugs.md) |

Load each reference when you reach its phase. Phases run in order;
the only branch is Phase 7 (acknowledge mode runs it, strict mode
skips it). Phase 5 is also optional if the project already has a
committed `sig/` directory.

## Reading order — modules

| Module | Read | Covers |
| --- | --- | --- |
| 1 | [`references/01-detect.md`](references/01-detect.md) | **Phases 1 + 3.** Gemfile / Gemfile.lock walk → framework family. The plugin-recommendation table (Rails / dry-rb / Sinatra / RSpec / plain Ruby). RBS-collection presence check. |
| 2 | [`references/02-configure.md`](references/02-configure.md) | **Phase 4.** Severity-profile choice tied to the mode. The `.rigor.dist.yml` template and every key it uses. The `.rigor.dist.yml` vs `.rigor.yml` convention. |
| 3 | [`references/04-sig-uplift.md`](references/04-sig-uplift.md) | **Phase 5.** `rigor sig-gen --write` baseline. `rigor sig-gen --params=observed --write` attr_reader precision uplift. Handling residual `untyped` methods. Committing `sig/`. |
| 4 | [`references/03-baseline-and-bugs.md`](references/03-baseline-and-bugs.md) | **Phases 6–8.** `rigor triage` as the diagnosis layer. `rigor baseline generate` + wiring `baseline:`. Surfacing likely real bugs. The two escalation paths — write a project plugin, or open a Rigor issue. |

## Escalation paths (Phase 7 preview)

Some diagnostic clusters are neither a quick fix nor honest baseline
material. Two of them have a dedicated answer this skill hands off to:

- **Application-specific metaprogramming** — a project DSL,
  `define_method` factory, or in-house macro that Rigor cannot follow
  produces a cluster of `call.undefined-method`. The durable fix is a
  **project-private Rigor plugin** that teaches Rigor the DSL. Hand
  off to the `rigor-plugin-author` skill.
- **An external gem Rigor does not understand** — a dependency ships
  no RBS and Rigor has no built-in coverage for it. Try
  `rbs collection install` first; if that gem genuinely needs Rigor
  support, **open an issue on the Rigor project** asking for it:
  <https://github.com/rigortype/rigor/issues>.

Neither is a Phase 7 obligation — they are options to *offer* the
user when the triage report points at one of these causes.
