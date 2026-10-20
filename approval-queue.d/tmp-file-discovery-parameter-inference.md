# Keep the editor's parameter inference buffer-only and close #2187

- **PR:** [#2188](https://github.com/rigortype/rigor/pull/2188)
- **Issue:** [#2190](https://github.com/rigortype/rigor/issues/2190)
- **Class:** scope
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-20

## Background

ADR-124 lists `parameter_inference:` among the editor publish's limits. Under that option the per-buffer publish collects the ADR-67 call-site table over the buffer's file alone, so a parameter typed from another file's call sites reads `Dynamic[top]` there, where `rigor check` types it. #2187 gave the publish a whole-project table built once per generation. Its review found one severe and two moderate problems:
- the table went stale on save, and the editor then reported `call.undefined-method` on correct code;
- building it took about 68s on Rigor's own `lib`;
- an invalidation during the build was lost.

## Options and trade-offs

- **Keep the buffer-only collection (taken).** This is the shipped behaviour. It is less precise than `check`, but rules decline on inferred parameters (WD6b), so the imprecision says less and never reports on correct code.
- **Land #2187 with a rebuild on every save.** This trades the false positive for the same 68s build on every save, on the editor path.
- **Design a per-file, incrementally re-folded table.** This is plausible, but it is a design that does not exist yet. The questions it must answer are recorded in #2190, marked `ready-for-human`.

## Decision

Keep the buffer-only collection and close #2187 unmerged. False positives outrank completeness (ADR-5, AGENTS.md § "Implementation Guidelines"), and the shipped behaviour only says less. ADR-124 names this as an accepted limit and links #2190.

## To undo

Reopen #2187's approach once #2190 has a design that stays fresh on save and keeps the build cost bounded. Nothing depends on the buffer-only collection beyond what shipped.
