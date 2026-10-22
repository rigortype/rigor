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

## To undo

Pass `environment: nil` in `ProjectPrePasses#run` and delete `Runner::ScanEnvironment`, `#scan_environment` and the specs that pin them; the scanner's nil-environment gate already returns the empty index for that case. The text prefilter and the `Object` filter are independent of it and can stay.
