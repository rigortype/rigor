# Three mailer-discoverer producers entries were added with reasons instead of reshaping the visibility scan

- **PR:** [#2318](https://github.com/rigortype/rigor/pull/2318)
- **Issue:** [#2308](https://github.com/rigortype/rigor/issues/2308)
- **Class:** gate-row
- **Precedent:** [#2307](https://github.com/rigortype/rigor/pull/2307)
- **Decided:** 2026-10-23

## Background

The round-1 review of #2318 asked the mailer discoverer to read method visibility in source order (`public :x` after `protected`, `public def x`, `private :x`). The rewrite replaced two grandfathered producers (`#next_visibility`, `#collect_visibility_and_callbacks`) with `#scan_visibility`, `#apply_visibility_call` and a `VISIBILITY_KEYWORDS` constant. `producers_spec.rb` lists the new ones as declaration producers and fails on a TODO reason, and the grandfathered pin drops from 369 to 367 because two grandfathered entries were removed.

## Options and trade-offs

- Add entries with reasons: matches the precedent and keeps the code in the shape it would have without the gate.
- Reshape the scan to avoid the detector, for example by inlining the keyword list: rejected as shaping code for a gate.
- Route the mailer scan through `DeclarationWalk::Context`: a larger change in a plugin that runs on its own syntactic walk, outside this issue.

## Decision

Added the three entries to `producers.yml` with written reasons, as #2307 did for `IvarWriteCollector`, and lowered `grandfathered_pin` to the new count and digest (the spec names this as the review point for a removed entry). The reasons say the discoverer is a plugin-side syntactic scan that cannot use the discovery table.

## To undo

Delete the three entries and the `VISIBILITY_KEYWORDS` constant once the discoverer reads visibility from the discovery table, and set the pin to whatever `producers_spec.rb` then prints.
