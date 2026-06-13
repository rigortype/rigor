# Mutation harness (prototype)

A dev-only probe for the **"壊したら壊れる"** question: if we break the code under
analysis, does Rigor actually bite? It injects *type-visible* mutations into a
source file, re-runs `rigor check` on the mutated bytes, and reports whether a
**new diagnostic** appears. A *surviving* mutant — no new diagnostic — is a
candidate false-negative.

This is **not** a CLI command and is off the ADR-50 frozen-contract surface.

```sh
# single file — full per-mutant breakdown
nix --extra-experimental-features 'nix-command flakes' develop -c \
  bundle exec ruby tool/mutation/mutate.rb lib/rigor/<file>.rb --verbose

# corpus sweep — one warm session over many files, survivors clustered into a
# ranked false-negative backlog (text, or --json for an agent / jq)
nix --extra-experimental-features 'nix-command flakes' develop -c \
  bundle exec ruby tool/mutation/mutate.rb sweep lib/rigor plugins/*/lib --per-file 40
```

Flags (single): `--config` `--limit N` `--seed N` `--operators a,b`
`--no-type-filter` `--dry-run` `--verbose`.
Flags (sweep): `--per-file N` (mutants/file, default 40) `--top N` (clusters
shown, default 25) `--json` `--seed` `--operators` `--no-type-filter`.

## Sweep mode — the false-negative backlog

`sweep <paths…>` builds the warm session once and runs every `.rb` under the
given files/dirs/globs, then groups the survivors by **(operator, receiver
type)**. Each cluster is a candidate systematic blind spot — "mutating
*operator* on a *receiver* never fires" — ranked by count, with the top method
names and example sites. Read clusters, don't chase the aggregate %: some are
*correct* non-firings (a variadic `Data.define` can't have a wrong arity; a
union with a `Dynamic` arm is gradually valid), which point at filter/operator
refinements; the rest are real engine gaps to triage. `--json` emits the same
clusters as structured data (ADR-61 flavour) so an agent can act on them.

## How it works

- **Mutator** walks the Prism AST and records byte-range splices — no unparser
  needed, since Rigor re-parses the spliced source. Operators (all targeted at
  a diagnostic rule family):
  - `nil_inject` — a call-argument literal → `nil` (→ `call.argument-type-mismatch`)
  - `type_swap` — integer↔string call-argument literal (→ `call.argument-type-mismatch`)
  - `undefined_method` — rename a *call site* to a missing method (→ `call.undefined-method`)
  - `arity_extra` — append a trailing arg inside `(...)` (→ `call.wrong-arity`)
  - Only *call sites and bodies* are mutated, never `def` signatures, so the
    reused ProjectScan's declarations stay valid.
- **Type-aware filter (Phase 1.5, default on).** Each mutation carries an
  *anchor* — the call receiver whose contract it could violate (a literal's
  anchor is its enclosing call's receiver). Before running, the harness builds
  one `ScopeIndexer` index over the original parse and probes each anchor with
  `Scope#type_of`; a mutation is kept only if its anchor types to a concrete,
  non-`Dynamic`/`Top` type. Implicit-self calls and literals outside a typed
  call (nil anchor) are dropped — Rigor has no contract there to bite, so they
  would survive as noise. The probe is FP-safe: an unresolved/failed type
  *keeps* the mutation. `--no-type-filter` disables it to A/B the effect.
  (This is why the harness is in-process Prism-native, not `mutant`: only an
  in-process tool can ask the engine for its own types.)
- **Warm loop** (the "editor mode + cache" path): the RBS environment and the
  whole-project ProjectScan are built once via `LanguageServer::ProjectContext`,
  then every mutant reuses them through `Runner.new(environment:, prebuilt:)` +
  `#run_source`. Passing `prebuilt:` makes `run_result_cacheable?` false, so the
  run-result cache — which digests the *disk* file — is bypassed and a mutant is
  never served a stale clean hit. Measured: ~400 ms cold setup, then ~6–12 ms
  per mutant.
- **Kill** = a diagnostic in the mutant run whose `(rule, path, line, column,
  message)` signature is not in the clean baseline set.

## Reading the output — filter the noise, then read survivors

A type checker only sees a subset of bugs. Most mutations are *type-invariant*
(equivalent mutants) and survival is **correct** — Rigor's false-positive
discipline working as intended. So the raw, unfiltered kill-rate is meaningless;
the **type filter** is what makes the number mean something. Measured A/B:

| file | `--no-type-filter` | default (filtered) |
| --- | --- | --- |
| `lib/rigor/trinary.rb` | 43% kill, 33 survivors (noise) | **100% kill, 0 survivors** |
| `lib/rigor/cli/ci_detector.rb` | 0% kill, 44 survivors | **83% kill, 1 real survivor** (`#new`) |

`ci_detector.rb`'s 107 dropped sites are string literals plumbing into
`ENV[...]` / `case`-`when` — never entering a typed contract. After filtering,
the survivors are **actionable false-negative candidates at sites Rigor can
actually see**, not Dynamic-receiver noise.

## Next steps (staged)

1. ~~**Type-aware site filtering**~~ — **done (Phase 1.5).** See above.
2. **Closure-aware kills** — a return-type mutation surfaces at a *caller*; use
   the ADR-46 dependents index to define where a legitimate kill may appear.
3. **Broad fuzz mode** — same warm loop, aggressive random mutation, watching
   for `internal analyzer error:` (crash), per-mutant timeout (hang), and
   *soundness contradictions* (a mutant that removes/flips a baseline diagnostic
   instead of only adding one). Crash detection is nearly free: the Runner
   already rescues `StandardError` into a single `internal analyzer error:`
   diagnostic.
4. Optionally a `make mutate` target and a per-rule fixture corpus where kill is
   *expected*, tracked as a teeth-regression gate.
