# Driving project improvement with `rigor-next-steps`

`rigor-next-steps` is the **single entry point** for "what should we
do next with Rigor on this project?". You hand it to an AI coding
agent once; from then on it figures out where the project is on the
Rigor adoption curve and drives it forward — installing Rigor if
missing, onboarding the project if it has no config, then routing to
the right next skill until the project is set up, guarded, and as
type-protected as you want it.

This chapter is the operator's view of that journey. Each step maps to
a command you can also run by hand — the skill just drives the whole
loop for you. The bundled skills it routes to are catalogued in
[Provided skills](08-skills.md); this chapter is the *workflow* that
ties them together.

## The loop, in one picture

```
rigor-next-steps
   ├─ resolve `rigor` (install via docs/install.md if missing)
   ├─ no config?  → rigor-project-init   (onboard)
   └─ otherwise   → rigor skill describe  → the recommended next skill
                                            ↺ re-run after each step
```

The engine of the loop is **`rigor skill describe`**. It is cheap and
side-effect-free — a *presence-only* probe (it stats your config,
baseline, `sig/`, lockfiles, CI, and editor/MCP configs; it never runs
`rigor check`) — so an agent can run it freely at any point. Its
guidance is generated live by your installed Rigor, so it never goes
stale.

## What `describe` tells you

```sh
rigor skill describe        # or the alias: rigor describe
```

```
# Rigor — next steps for this project
#
# Generated live by rigortype 0.2.x; this guidance always
# reflects your installed version and the project's current state.

## Project state
- Config file:    .rigor.dist.yml
- Baseline:       none
- Project sig/:   present
- Community RBS:  collection installed
- CI integration: CI present, Rigor not wired
- Editor LSP:     .vscode present, Rigor LSP not wired
- MCP server:     not detected

## Recommended next step
→ rigor-ci-setup — Rigor is configured but not wired into CI — lock in the regression guard.
  Load it: rigor skill rigor-ci-setup

## All skills you can run next
  …the full catalogue, each with its current one-line description…

## For the agent
  …how to act on the recommendation, and how to refine it from `rigor check` findings…
```

Run it, follow the **Recommended next step**, complete that skill, then
run it again. The recommendation advances as the project's state
changes (e.g. `project-init → rbs-setup → ci-setup → …`).

## The journey, step by step

The recommendation walks a sensible adoption order. For each stage,
the equivalent hand-commands are in the linked chapter.

| Stage | Recommended skill | What it does | By hand |
| --- | --- | --- | --- |
| **Onboard** | `rigor-project-init` | Detect the stack, pick plugins, write `.rigor.dist.yml`, optionally snapshot a baseline. | [Provided skills](08-skills.md), [Configuration](03-configuration.md) |
| **Community RBS** | `rigor-rbs-setup` | `rbs collection install` so RBS-less gems stop typing as `Dynamic`. | [Configuration](03-configuration.md) (`rbs_collection`) |
| **Rails plugins** | `rigor-plugin-tune` | If Rails is locked but no Rails plugins are enabled, wire them so ActiveRecord / routes / i18n calls resolve. | [Using plugins](07-plugins.md) |
| **See findings** | — | `rigor check` for bugs; `rigor coverage --protection` for "add a type here". | [CLI reference](02-cli-reference.md), [Type-protection coverage](15-type-protection-coverage.md) |
| **Raise protection** | `rigor-protection-uplift` | Close type-protection holes — sig-gen first, minimal hand-RBS, under a double gate. | [Type-protection coverage](15-type-protection-coverage.md) |
| **Pay down debt** | `rigor-baseline-reduce` | Work an existing baseline down rule by rule. | [Baselines](06-baseline.md) |
| **Guard it** | `rigor-ci-setup` | Run Rigor in CI with inline PR/MR diagnostics. | [Running Rigor in CI](11-ci.md) |
| **Editor / agent** | `rigor-editor-setup` / `rigor-mcp-setup` | Wire `rigor lsp` into your editor / `rigor mcp` into your AI agent. | [Editor integration](09-editor-integration.md), [MCP server](10-mcp-server.md) |
| **Teach a DSL** | `rigor-monkeypatch-resolve` / `rigor-plugin-author` | Resolve your own monkey-patches via `pre_eval:`, or author a plugin. | [Configuration](03-configuration.md), [Provided skills](08-skills.md) |
| **Upgrade / validate** | `rigor-upgrade` / `rigor-doctor` | Adopt a new Rigor version cleanly; validate the setup is healthy. | [Baselines](06-baseline.md), [Troubleshooting](13-troubleshooting.md) |

## A worked walk-through

A typical Rails app, freshly installed Rigor, no config:

1. **`describe`** → *"no Rigor configuration yet — start here"* → run
   `rigor-project-init`. It writes `.rigor.dist.yml` (`target_ruby`,
   `paths:`, the Rails plugins) and snapshots a baseline if the first
   `rigor check` reports many diagnostics.
2. **`check` finds real bugs.** On a type-conscious Rails app the
   plugins resolve hundreds of framework calls *and* surface genuine,
   RBS-invisible bugs — strong-params keys that are not columns
   (`permit :start_date_jst` where the column is `start_date`), missing
   or doubled i18n keys. These are the onboarding payoff.
3. **`coverage --protection` shows where types help.** A plain library
   slice might report e.g. `17.5%` protected, with an "add a type here"
   list pinpointing the untyped receivers.
4. **`rigor-protection-uplift` closes the cheap holes.** sig-gen first,
   then a *minimal true* hand-RBS for the residual — e.g. a seven-line
   RBS for an external gem with no signatures can lift a slice's
   protection from `13%` to `26%` with **zero new diagnostics** (the
   skill verifies both: protection up *and* `rigor check` stays clean).
5. **Acknowledge mode + a baseline** snapshot today's diagnostics so
   any *new* one is a visible regression. Inject a typo'd i18n key and
   `rigor check` flags it immediately.
6. **`describe` advances** to `rigor-ci-setup`, then editor / MCP — and
   the loop continues whenever you want the next move.

## Refining the recommendation from `check`

`describe`'s headline is presence-only — it never runs `rigor check`,
which keeps it fast. But the *best* next step often depends on what
`check` would find, so the **"For the agent"** section tells the agent
to refine the choice from a `rigor check` it runs (or already ran):

- errors present, no baseline yet → `rigor-baseline-reduce`
- a `call.unresolved-toplevel` / `call.undefined-method` cluster on
  your own monkey-patches → `rigor-monkeypatch-resolve`
- framework calls typing as `Dynamic` with no matching plugins enabled
  → `rigor-plugin-tune`
- `RBS classes available: 0` or a `configuration-error` → `rigor-doctor`

If you are following the loop by hand, the same rules apply: run
`rigor check`, and let its output pick the most useful next skill.

## Practical notes

- **`target_ruby` floor.** Rigor's bundled parser (Prism) supports a
  recent Ruby floor; if you set `target_ruby` below it, `rigor check`
  tells you the minimum and where to read the right value (your
  `Gemfile.lock` `RUBY VERSION` or `.ruby-version`). `rigor-project-init`
  picks a compatible value for you.
- **List the individual Rails plugins, not the umbrella.** Put
  `rigor-activerecord`, `rigor-actionpack`, … in `plugins:` — not
  `rigor-rails` (a convenience meta-gem, which is not a single plugin).
  If you try the umbrella, the load error lists the individual plugins
  to use.
- **`RBS classes available: 0` is a broken setup, not a clean run.** If
  `rigor check` prints that warning, the RBS environment failed to build
  (usually a duplicate declaration in `signature_paths:`) — fix it
  before trusting the (near-empty) results. `rigor-doctor` helps locate
  it.
- **A missing path is skipped, not fatal.** `rigor check app lib` on a
  project with no `lib/` analyses `app` and warns about `lib` — it does
  not abort.

## See also

- [Provided skills](08-skills.md) — the per-skill reference for every
  destination this loop routes to.
- [Installing Rigor](01-installation.md) — the install step
  `rigor-next-steps` runs first.
- [Type-protection coverage](15-type-protection-coverage.md) — the
  measurement `rigor-protection-uplift` acts on.
