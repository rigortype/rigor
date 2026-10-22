# Record EditReplay's skeleton builder in producers.yml as a reasoned producer

- **PR:** [#2272](https://github.com/rigortype/rigor/pull/2272)
- **Issue:** [#1967](https://github.com/rigortype/rigor/issues/1967)
- **Class:** gate-row
- **Precedent:** [#2225](https://github.com/rigortype/rigor/pull/2225)
- **Decided:** 2026-10-22

## Background

Review found that emptying a file masks finer missing edges, so the `--verify-incremental-edits` replay gained a second edit: the file reduced to its `class` / `module` skeleton. `Analysis::EditReplay` builds that text by walking the file's `Prism::ClassNode` / `Prism::ModuleNode` headers, and `spec/rigor/declaration_facts/producers_spec.rb` flags every method that references those node classes.

## Options and trade-offs

- Build the skeleton without naming the node classes (for example by node `type` symbols). The gate would not see it, but that bends the code around the gate, which the lane contract forbids.
- Add two reasoned rows (taken), as #2225 did for `settle_alias_slot`. The grandfathered count does not move.

## Decision

The rows say that the methods copy header spellings into a test edit, feed no analysis and derive no declaration context.

## To undo

Delete the rows along with `lib/rigor/analysis/edit_replay.rb`, or drop the skeleton edit.
