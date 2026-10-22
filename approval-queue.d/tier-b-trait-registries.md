# Hand the Tier B scan a separate, lazily built RBS environment instead of resolving trait modules at dispatch

- **PR:** [#2286](https://github.com/rigortype/rigor/pull/2286)
- **Issue:** [#476](https://github.com/rigortype/rigor/issues/476)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-10-22

## Background

#476 found the ADR-16 Tier B (trait registry) lane dead in production: the pre-pass passes `environment: nil`, so `module_instance_method_names` answers `[]`. The issue left the design open and named three options: (a) build an environment without the synthetic index for the scan, then the real one; (b) resolve trait modules at dispatch time against the live environment; (c) retire the tier.

## Options and trade-offs

- **(a) A separate environment without the index (taken).** The scanner reads only the RBS loader and `class_ordering`, and `Environment.for_project` merely stores the index, so the environment the scan needs does not depend on the scan. Plumbing only: no new tier, no dispatcher change. The cost is a second `RbsLoader` instance in the coordinator process for projects that load a trait-registry plugin (the persistent RBS cache serves it), built lazily so a project with no matching `devise` call never builds it.
- **(b) Resolve at dispatch.** Avoids the second loader and the whole-project parse for the call-site scan, but moves the trait-to-module mapping into the dispatcher, changes what the index holds (the arity rule and the top-level veto read membership from it), and is a design change beyond the issue's plumbing.
- **(c) Retire the tier.** Gives up rigor-devise's synthesised methods and the worked Tier B consumer.

Two smaller calls rode along. A registry-only scan returns the empty index when no file's text names a registry's method, so loading rigor-devise costs nothing in a project that never writes `devise`; the price for a project that does is the full-project parse the class hierarchy needs (+0.45 s warm on mastodon). And the methods a module's RBS definition inherits from `Object` (its owner is the one `Object`'s own table names) are not synthesised: they would sit above the class's own `def` and silence its arity check.

## Decision

(a), with the text prefilter and the `Object` filter, as the smallest change that makes the tier reachable and says nothing more than the project's RBS declares. The environment is built only when a loaded plugin registers a trait registry, so Tier C and the nested-class tier are unchanged. Tier B still emits nothing for a module the project's RBS does not declare, which is the case for every real Devise project today (the gem ships no RBS and Rigor bundles none); bundling `Devise::Models::*` signatures is a separate decision this PR does not take. No default changes for a project that does not load a trait-registry plugin.

**Round-1 review calls.** The adversarial review's fixes left four calls open; each took the conservative side.

- **Shadowing (S1): decline at the scanner, ignoring `include` order.** A Tier B entry is not emitted for a name the class body declares (`def`, `alias` / `alias_method`, `attr_*`, `define_method`, `delegate`, any reopening) or a project module it includes or prepends declares (through that module's own mixins, matched by name or `::`-suffix). Ruby lets a module included *before* `devise` lose to the Devise module; the scanner declines it anyway rather than model MRO order, so the call falls to the tiers that answered it before Tier B was reachable. Alternative: a dispatcher-side guard consulting the discovered-method tables first, which keeps the index honest for `plugin_member_answers?` and the arity rule only if each consumer learns the same rule. Undo: drop `decline_project_declared`.
- **Module surface (M2, m3).** A trait-module method is kept only when its `defined_in` is the module or one of its own `include` / `prepend` ancestors, and only when public. This replaces the `Object`-owner filter and covers self-typed modules. Keeping private methods with their visibility was the alternative; skipping says less.
- **Incremental invalidation (M1): re-baseline on a moved index.** The snapshot stores `SyntheticMethodIndex#surface_digest` (SCHEMA 44); a recheck whose runner built a different index re-analyses the whole project (the #1898 effect-digest precedent). Folding each file's registry call sites into its declaration signature would re-check only the model's dependents, but `ScopeIndexer` is plugin-agnostic and the per-file contribution of a concern-re-targeted call lives in another file. The digest covers Tier C and nested-class entries too, so a Tier C class-body edit that moves the index now re-baselines as well (not pinned by a spec here). The schema bump makes every existing snapshot cold once.
- **Scan environment (m1): document, do not equalise.** The scan environment re-runs the source-RBS synthesizers, misses `#prepare`-built plugin signatures in pool mode, and passes `source_files:` where the language server's does not. Equalising each mode costs a second synthesizer pass or a prepare in the coordinator; `macro-substrate.md` now states the difference and what it costs (a module one side declares and the other does not is skipped, or promotes to `Dynamic[top]`).

## To undo

Pass `environment: nil` in `ProjectPrePasses#run` and delete `Runner::ScanEnvironment`, `#scan_environment` and the specs that pin them; the scanner's nil-environment gate already returns the empty index for that case. The text prefilter, the own-ancestry filter and the project-member decline are independent of it and can stay; the M1 digest (`synthetic_surface_digest`, SCHEMA 44) is needed whenever the index can be non-empty.
