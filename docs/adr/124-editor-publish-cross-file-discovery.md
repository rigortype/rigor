# ADR-124 — The editor publish seeds cross-file discovery

Status: **Proposed, 2026-10-20.** Implemented in [#2164](https://github.com/rigortype/rigor/pull/2164) and waiting for the maintainer's decision; nothing has landed.

Grounding: [#2147](https://github.com/rigortype/rigor/issues/2147); the measurement in § "Consequences".

## Context

The language server publishes a buffer's diagnostics through `Runner.new(buffer:, prebuilt: project_scan)` (`LanguageServer::DiagnosticPublisher#run_analysis`, and `Runner::BufferPoolDispatcher` for a batch).

`prebuilt:` exists to keep per-buffer work small: plugin `#prepare`, the dependency-source walker, the scanners and the template units run once per generation, not once per keystroke. The discovery pass is skipped as well. `Runner#ensure_project_discovery` is a no-op there, so the scope knows only the analysed file's own declarations.

Before this ADR, that gap was written down as the contract: "the LSP path deliberately seeds an empty project scope". The cost is a whole class of editor-only answers:

- every class another file declares reads as an external ancestor;
- every reader of a resolution chain then gives up or declines.

On #2147's fixture, the self-call ivar-write proof (#1596) gives up on `Base`, the class guard's narrowing of `@io` is dropped across `log("dumping")`, and the publish reports a `call.undefined-method` that `rigor check` over the same tree does not.

The intent: **a buffer's publish answers what `rigor check` answers for the same bytes**, wherever the per-request budget allows it.

## Decision

The per-buffer publish seeds the project's discovery tables through the existing `discovery_seed:` seam (#260).

- `ProjectContext` walks each project file once per generation into ADR-85 discovery bundles (`Protection::DiscoverySeed.bundles`, reset by `invalidate!`).
- Each publish re-folds those bundles through `DiscoverySeed.tables_for_buffer` with its own `BufferBinding`. The buffer's file is re-walked from the buffer's bytes, so a declaration the buffer added or deleted wins over the one on disk. Every configured entry whose real path is the buffer's file is handed to the fold under the buffer's own spelling: the binding substitutes bytes only for a path spelled exactly as the URI's, and the configured paths may be relative (`lib`, the default) or reach the file through a symlink. Any other file whose on-disk digest moved since the bundles were built is re-walked too.
- The runner takes the result as `discovery_seed:` (`ProjectContext#discovery_seed_for`).

**Criterion:** a cache or snapshot that exists to make a request cheap may skip *recomputing* a cross-file fact, but must not make the request answer *as if the fact were absent*. The skip is a cost decision, and the absence is a semantic one. Where the fact can be supplied cheaply, it is.

## Working decisions

- **WD1 — re-fold per publish, not one frozen seed.** A seed built once per generation would hold the buffer's on-disk declarations, and a `def` the buffer deleted would keep answering. The per-publish fold costs a digest per file plus one re-walk: 2–4.5 ms per publish on the projects measured below.
- **WD2 — only the publishing buffer is read from its bytes.** Other open, dirty buffers are read from disk. This is the publish invariant the language-server design already states: "each URI's markers come from the last analysis that saw that URI's current bytes".
- **WD3 — no cache format change.** The bundles are the ADR-85 seed bundles (Marshal-clean def handles, not live nodes), held in process, built and dropped with the generation, and never written. A fork batch builds them in the parent first, so the children inherit them.

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| Make the proof optimistic when the tables are partial (keep a narrowing it cannot prove when `ENVELOPE_PROJECT_WIDE` is absent) | Fixes one reader of many. It needs edits at every exit that meets unseen code (the proof's external entries and `GuardRebinding.type_method_foreign?`), it makes the editor say less than the CLI where unseen code really writes the ivar, and it leaves `rigor check --tmp-file` broken. |
| Run the discovery pass per publish | A full project walk per keystroke is what `prebuilt:` exists to avoid. |
| Keep the empty scope (the old contract) | Every cross-file rule keeps an editor-only answer. On the projects below that is 13 and 5 diagnostics the CLI does not report. |

## Consequences

- **Measured** (each `lib` file published as an unchanged buffer, compared with one cold `rigor check` of the same tree; unchanged buffers cannot show a buffer-substitution defect, which the specs cover instead):

| Project | Files | Cold `check` | Publish before | Publish after | Removed | Added | After vs cold |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| haml (`lib`) | 52 | 8 | 20 | 8 | 13 × `call.wrong-arity` on `SyntaxError.new` (haml's own subclass takes two arguments) | 1 × `def.override-visibility-reduced`, which cold also reports | identical |
| liquid (`lib`) | 63 | 3 | 7 | 3 | 4 × `call.undefined-method` on `SyntaxError` accessors, 1 × `flow.always-truthy-condition` | 1 × `call.possible-nil-receiver`, which cold also reports | identical |
| kramdown (`lib`, measured in review) | 55 | 8 | 3 | 8 | none | 5 × `call.possible-nil-receiver` in `list.rb`, which cold also reports | identical |
| faraday, alba, rgl (`lib`) | 33, 14, 28 | 0 | 0 | 0 | none | none | identical |

  Each added diagnostic is one the CLI already reports: the editor had been hiding it because the cross-file fact was missing. The fold costs 2–4.5 ms per publish. The analysis itself also does more, because it now resolves across files: on kramdown `lib` a full pass over its 55 files took about 11% longer (5.4 s → 6.0 s, about 11 ms per publish). Bundles are walked once per generation.
- **Behaviour users see changes.** Editor diagnostics move toward the CLI's in both directions: false positives go, and diagnostics the CLI reports start to appear. That makes this a decision for the maintainer (contribution-flow.md § "Decisions and the approval queue").
- **Not covered:**
  - `rigor check --tmp-file` (buffer without `prebuilt:`) discovers only the buffer file but still finalises `ENVELOPE_PROJECT_WIDE`, so it keeps the gap ([#2165](https://github.com/rigortype/rigor/issues/2165)).
  - With `pre_eval:` configured, the prebuilt runner's own pre-eval constant publication replaces the seed's literal constant table, so constant values still differ from `check` there. One pre-existing shape of it is a false positive: a `pre_eval:` file with `X = 1` and an unlisted file with `X = "s" if …` make the editor report `X.upcase` on Integer, while `check` retracts the value (#663) and reports nothing.
  - `parameter_inference:` is still collected over the buffer alone.
- **Staleness that becomes more visible:** WD2 reads other files from disk, and a dirty buffer is not republished when another file is saved or the generation is invalidated. Rules that now fire across files (`call.wrong-arity` among them) can therefore keep a marker computed against another file's old bytes until the buffer's next change or save. The cause is older (it already applied to RBS inputs); republishing dirty buffers after a save round would close it.

## Relationship to other ADRs

- [ADR-19](19-language-server-packaging.md): the language server.
- [ADR-85](85-seed-bundles-and-lazy-def-node-handles.md): the discovery bundles this re-folds.
- [ADR-62](62-mutation-testing-teeth-measurement.md): the Tier 2 oracle that first used the `discovery_seed:` seam, for the same reason.
