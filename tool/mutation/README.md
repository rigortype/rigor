# Mutation harness (prototype)

A dev-only probe for the **"壊したら壊れる"** question: if we break the code under
analysis, does Rigor actually bite? It injects *type-visible* mutations into a
source file, re-runs `rigor check` on the mutated bytes, and reports whether a
**new diagnostic** appears. A *surviving* mutant — no new diagnostic — is a
candidate false-negative.

This is **not** a CLI command and is off the ADR-50 frozen-contract surface.

```sh
nix --extra-experimental-features 'nix-command flakes' develop -c \
  bundle exec ruby tool/mutation/mutate.rb lib/rigor/<file>.rb --verbose
```

Flags: `--config PATH` `--limit N` `--seed N` `--operators nil_inject,...`
`--dry-run` `--verbose`.

## How it works

- **Mutator** walks the Prism AST and records byte-range splices — no unparser
  needed, since Rigor re-parses the spliced source. Operators (all targeted at
  a diagnostic rule family):
  - `nil_inject` — literal → `nil` (→ `flow.possible-nil`)
  - `type_swap` — integer↔string literal (→ `call.type-mismatch`)
  - `undefined_method` — rename a *call site* to a missing method (→ `call.undefined-method`)
  - `arity_extra` — append a trailing arg inside `(...)` (→ `call.argument-count`)
  - Only *call sites and bodies* are mutated, never `def` signatures, so the
    reused ProjectScan's declarations stay valid.
- **Warm loop** (the "editor mode + cache" path): the RBS environment and the
  whole-project ProjectScan are built once via `LanguageServer::ProjectContext`,
  then every mutant reuses them through `Runner.new(environment:, prebuilt:)` +
  `#run_source`. Passing `prebuilt:` makes `run_result_cacheable?` false, so the
  run-result cache — which digests the *disk* file — is bypassed and a mutant is
  never served a stale clean hit. Measured: ~400 ms cold setup, then ~6–12 ms
  per mutant.
- **Kill** = a diagnostic in the mutant run whose `(rule, path, line, column,
  message)` signature is not in the clean baseline set.

## Reading the output — raw kill-rate is noise

A type checker only sees a subset of bugs. Most mutations are *type-invariant*
(equivalent mutants) and survival is **correct** — this is Rigor's false-positive
discipline working as intended. Two real prototype runs:

- `lib/rigor/trinary.rb`: renamed calls on **typed** receivers fire
  `call.undefined-method`; the *same* method survives where the receiver is
  `Dynamic`. Teeth appear exactly where type knowledge exists.
- `lib/rigor/cli/ci_detector.rb`: **0% kill** — its string literals are plumbing
  into `ENV[...]` / `case`-`when`, never entering a typed contract. Nothing for a
  type checker to bite. 0% is right, not 44 blind spots.

So the signal is **the per-site survivor list at sites where Rigor has a type**,
not the aggregate percentage.

## Next steps (staged)

1. **Type-aware site filtering** — query the engine's `type_of` at each
   candidate site and only emit a mutation where the receiver / consuming
   context is non-`Dynamic`. Converts "0% on plumbing" into a kill-rate over
   sites Rigor can actually see. (Requires the engine in-process — the reason
   this is Prism-native, not `mutant`.)
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
