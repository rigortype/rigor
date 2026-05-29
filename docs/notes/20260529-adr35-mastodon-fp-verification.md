# ADR-35 override-rules — Mastodon false-positive verification

Date: 2026-05-29. Corpus: Mastodon (`~/repo/ruby/rigor-survey/mastodon`),
full `app` + `lib`, 1219 Ruby files. Companion to
[ADR-35](../adr/35-override-signature-compatibility.md) slice 4.

## Method

Ran `rigor check` over the whole project under a **forced `strict`
severity profile** (Mastodon's own `.rigor.dist.yml` uses `lenient`,
which maps all three `def.override-*` rules to `:off` and would surface
nothing). Config mirrored the dist file (same `paths:` / `plugins:`) with
`severity_profile: strict`. Tabulated diagnostics by rule. The temporary
config was removed afterwards.

## Findings

| Rule | Fires (strict) | Verdict |
| --- | --- | --- |
| `def.override-return-widened` | 0 | Correctly inert — no authored RBS on app classes (WD1 gate). |
| `def.override-param-narrowed` | 0 | Same — no authored RBS. |
| `def.override-visibility-reduced` | 160 → **35** | 160 were a real FP cluster (fixed); 35 residual are true reductions. |

### The visibility false-positive cluster (160) and its fix

The 160 fires were dominated by the Rails **concern** pattern: a concern
under `app/controllers/concerns/` defines `private` helper methods
(`username_param`, `set_account`, `pundit_user`, `pagination_*`, …), and
the including controller redefines them — also `private`. private → private
is **no reduction**, so these should never have fired.

Root cause: method **visibilities were tracked per-file only**, whereas the
def-node / superclass / includes indexes were seeded **cross-file** (the
ADR-24 project pre-pass). So when analysing a controller, the ancestor
concern's `private` visibility (declared in a sibling file) came back
`nil`, and a `nil → :public` fallback in the rule fabricated a "public"
parent — producing a bogus public→private "reduction".

Fix (engine):

- `Inference::ScopeIndexer.discovered_def_index_for_paths` now also
  collects `method_visibilities` across all project files.
- `merge_project_method_indexes` merges per-file visibilities **over** the
  cross-file seed (current file authoritative for its own classes; sibling
  ancestors preserved).
- `Analysis::Runner#seed_project_scope` seeds the cross-file table.
- `CheckRules` no longer fabricates `:public` from a missing entry — an
  unknown ancestor visibility bails to silence (FP-safe per WD7).

After the fix: **160 → 35**, and the cross-file *genuine* case (a public
parent in one file, private override in another) now fires correctly
(previously it only "worked" by the lucky `|| :public` coincidence).

### The 35 residual fires are true positives

All 35 are real visibility reductions the engine now reads correctly:

- `pundit_user` is genuinely **public** in the `Authorization` concern
  (no `private` modifier); controllers override it `private`.
- `pagination_max_id` / `pagination_since_id` / `pagination_params` are
  genuinely **protected** in `Api::Pagination`; controllers override them
  `private`.
- `respond_with_error` protected in `Api::BaseController`, overridden
  private.

These are *stylistically common* in Rails and arguably harmless, but they
are real reductions, not analyzer misreads. They surface only under
`strict`. Mastodon's actual `lenient` config surfaces **zero**.

## Calibration decision

Keep the shipped severity mapping for all three rules:
`lenient → off`, `balanced → :warning`, `strict → :error`. **No**
`balanced → :error` promotion — the residual true positives are common
enough in idiomatic Rails that erroring a `balanced` project would trade
against the false-positive-discipline value. A team wanting strict LSP
visibility enforcement opts in via `severity_profile: strict` or a per-rule
`severity_overrides:` entry.

## Reach notes (not bugs — documented limits)

- The `return` / `param` rules need authored RBS on **both** sides; an
  app with no `sig/` sees nothing from them. This is the intended WD1 gate.
- The nominal subtype check resolves **loaded** Ruby classes / their
  ancestors; an app-only class hierarchy degrades to `:maybe` and stays
  silent. Reach for return/param is over core / stdlib / loadable-gem
  hierarchies (e.g. `Numeric`/`Integer`). A project-RBS-ancestor-aware
  subtype path would extend this; deferred.
