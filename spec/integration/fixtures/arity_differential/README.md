# Arity differential fixtures

The corpus of the `arity-differential` CI job (`tool/engine_diag_diff.rb`, ADR-119 WD2 "The `SourceArity`
differential"): shapes that fire `call.wrong-arity` today, so the base engine's firings on them are never empty.
Unlike `../declaration_witness/`, nothing here is executed by a spec; each file is only analysed. Add a shape that
fires at the merge base, and any firing a change removes is listed in `arity_adjudication.yml` with a verdict.
