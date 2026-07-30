# `RBS::Rewriter` for the sig-gen writer's update path — evaluation

Date: 2026-07-30. Against `rbs` 4.1.0 (`references/rbs` at the 4.1.0 tag) and
`lib/rigor/sig_gen/writer.rb` at 706 lines.

Status: **evaluation, decided — do not adopt.** Answers
[#228](https://github.com/rigortype/rigor/issues/228). No code changed. The reusable
part of the finding is the model, not the gem; see § 5.

---

## The question

`rbs` 4.1 shipped [`RBS::Rewriter`](https://github.com/ruby/rbs/pull/2927) — replacements
applied against an `RBS::Buffer` by `RBS::Location`, with overlap rejection — and upstream
rebuilt `rbs annotate` on it. `rigor sig-gen --write` solves what looks like the same
problem when it updates an existing `.rbs`: change a declaration without disturbing the
rest of the file. Adopt it?

The crux #228 named is the version floor: `RBS::Rewriter` is 4.1+, the gemspec supports
`rbs >= 3.0, < 5.0`. Three findings below make the floor question moot, so it is answered
last.

## 1. What `RBS::Rewriter` actually is

70 lines (`references/rbs/lib/rbs/rewriter.rb`), of which the mechanism is 15:

- `rewrite(location, string)` — accumulate a replacement; raise if it overlaps an existing one.
- `string` — apply them, sorted by start position, in reverse.
- `add_comment` / `replace_comment` / `delete_comment` — three comment-specific helpers.

Two properties matter for the "upstream maintains it, so location drift becomes their
problem" argument in #228, and neither survives contact:

- **It never interprets a location.** Only `start_pos` / `end_pos` (and `start_column`, in
  the comment helpers). There is no parser coupling to inherit, so there is no drift to
  outsource.
- **It does not check buffer provenance.** A `Location` built against a *different* buffer
  is accepted silently (probed). The overlap guarantee is therefore only as strong as the
  caller's own discipline about keeping one coordinate system — which is exactly the
  discipline a caller would be adopting it to be relieved of.

Same-anchor zero-width insertions come out in the order they were added (probed to 12
inserts at one anchor). That is `sort_by` happening to be stable, not a documented
guarantee — worth knowing, not worth deciding on.

## 2. Upstream's own use is comment attachment, not declaration editing

`rdoc_annotator.rb` is the only consumer in the `rbs` tree, and it calls **only** the three
comment helpers — never the general `rewrite`. `rbs annotate` attaches RDoc comments to
declarations that already exist. It never inserts a declaration, never creates a namespace,
never moves one.

So the resemblance to sig-gen's problem is superficial. The workloads are disjoint:

| sig-gen `--write` does | `RBS::Rewriter` offers |
| --- | --- |
| insert method declarations into a class | — |
| create a missing namespace chain | — |
| relocate a declaration under its parent, re-indented, head shortened | — |
| replace an existing member's method type | `rewrite(member.location, text)` |
| keep the untouched bytes intact | the model, not an API |

One row. `Writer#replace_eligible_conflicts` already sorts by descending byte position for
exactly the reason `string` does, and that is a single line.

## 3. The blocker: our merge steps anchor on text earlier steps wrote

`Rewriter`'s model requires every location to come from one immutable buffer. The writer's
merge cannot supply that, and says so itself (`writer.rb`, `merge_candidates`):

> Ancestors first, so `Foo` is created (or found) before `Foo::Bar` looks for a parent to
> nest under.

`merge_class` may **create** `Foo`; the next iteration then locates `Foo`'s closing `end` to
nest `Foo::Bar` inside it. `merge_class_shells` reads the re-parsed declarations for the same
reason, and `collapse_nested_declarations` runs against the merged text. That is why the
writer re-parses between steps — not offset-bookkeeping laziness, but a genuine dependency of
later anchors on earlier output.

A replacement model cannot express this without first restructuring the merge into a
plan-against-the-original-buffer pass. That restructuring is the whole of the potential win
(N parses → 1), and it is **available at zero version cost** — it is our merge algorithm, not
upstream's API. Adopting `RBS::Rewriter` does not deliver it; it would have to be earned
first, after which `Rewriter` adds the 15 lines from § 1.

## 4. What would not survive

The byte-manipulation surface (`insert_before_end`, `append_top_level`, `splice_out`,
`reindent`, `line_start_index`, `blank_range?`, `apply_replacement` ≈ 60 lines) is mostly
layout rules `Rewriter` has no concept of: anchoring an insertion at a line start so the
snippet's own indentation wins, collapsing the newline seam a cut leaves behind,
re-indenting a moved block to its new parent's member depth. All of it stays.

## 5. Decision

**Do not adopt `RBS::Rewriter`.** Three reasons, in the order they became decisive:

1. Its usable surface for us is one method-type replacement (§ 2), against a workload it was
   not built for.
2. The structural win #228 hoped for is blocked by our own merge order, and is ours to take
   whenever we want it — without a dependency (§ 3).
3. Only then does the floor matter, and [ADR-94](../adr/94-rbs-inline-reader-and-the-rbs-3x-floor.md)
   has already adjudicated this exact trade, in a case where the migration bought
   strictly more: *a dependency migration that buys correctness a workaround already buys does
   not justify narrowing the supported toolchain range.*
   [ADR-79](../adr/79-rbs-version-range-over-pinned-determinism.md) fixed the range on the
   principle that Rigor checks against the toolchain the project actually resolves.

What is worth keeping is the **model**: accumulate non-overlapping edits against one
immutable buffer and apply once. If the writer's re-parse chain ever shows up as a cost —
it has not: `--write` runs are small and bounded by file count — the fix is to plan the merge
against the original buffer, which is a change to `merge_candidates`, not a new dependency.

## Re-open if

- The `rbs` floor moves to 4.1+ for an unrelated reason, **and** `RBS::Rewriter` has by then
  grown declaration-level editing (insertion, relocation) rather than comment helpers.
- The writer's re-parse chain becomes measurable on a real `--write` run.
