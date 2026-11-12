# Leave a global Ruby's own signatures declare off the block content seams

- **PR:** [#3120](https://github.com/rigortype/rigor/pull/3120)
- **Issue:** [#3096](https://github.com/rigortype/rigor/issues/3096)
- **Class:** scope
- **Precedent:** [#3094](https://github.com/rigortype/rigor/pull/3094)
- **Decided:** 2026-11-12

## Background

#3096 asked the block content seams (ADR-56 slice C's join, the escaping floor and the `shadows` overlay) to cover class variables and globals as #3094 did instance variables. The globals include the interpreter's specials. Some of them read through a getter: `$0` answers a frozen copy, so `$0 << "y"` raises. Others, such as `$~` and `$_`, are frame-local, and another lane is working on `$~`. The lane brief asked for the specials to be left alone, and nothing defined which globals count as special.

## Options and trade-offs

- Take every global. This also fixes plain-storage specials (`$; = +","; [1].each { $; << "y" }` would read `String`). It runs into the `$~` lane's work, and it rebinds globals whose getter is not plain storage.
- Keep a hand-written list of specials. It drifts from the signatures, and every list entry is its own judgement call.
- Leave out any global that Ruby's core or stdlib RBS declares (`StatementEvaluator#capturable_non_local?` calls `Environment#global_for_name(name, builtin: true)`). That covers `$~`, `$_`, `$;`, `$stdout`, `$0` and the rest from one source. A project's or a gem's own declared global still counts.

## Decision

The third option, ruled by the coordinator. Behaviour for every special is unchanged from master. The cost is that a plain-storage special a block grows in place keeps its pre-call contents. `$; = +","; [1].each { $; << "y" }; $; == ",y"` still folds always-falsey, and so does the `$_` spelling. Ruby answers true for both. #3094 is the closest precedent: it kept a shape the seams could not yet take soundly (a nil-able instance variable) at its pre-call binding rather than widen the change. The fixture's `special_global` row pins the current answer as a labelled guard.

## To undo

Remove the `when :global` arm of `StatementEvaluator#capturable_non_local?`, or narrow it to the specials whose getter is not plain storage. Then update the `special_global` row in `spec/integration/fixtures/block_content_cvar_global_capture/demo.rb` and its precision snapshot, which will read `String`. Also update the sub-phase 3b entry in `docs/internal-spec/inference-engine.md` and the #3096 amendment to ADR-56 WD2.13, which both state the exclusion. Do this in a separate issue, coordinated with the `$~` work.
