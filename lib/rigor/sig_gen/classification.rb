# frozen_string_literal: true

module Rigor
  module SigGen
    # The classifications a candidate method falls into after the generator has compared the inferred return
    # type — or, for a member declared inline, the inline declaration (ADR-112 WD4) — against the project's
    # existing RBS.
    #
    # The strings are the diagnostic-family identifiers ADR-14 reserves under `sig.*`; the MVP carries them as
    # plain symbols on the method candidate and renders the matching identifier in JSON / text output. They are
    # added to the diagnostic family hierarchy in `docs/type-specification/diagnostic-policy.md` even though
    # slice 1 does not yet emit them as diagnostics.
    module Classification
      NEW_FILE = :new_file
      NEW_METHOD = :new_method
      TIGHTER_RETURN = :tighter_return
      EQUIVALENT = :equivalent
      SKIPPED = :skipped
      # ADR-112 WD4 — a member declared inline by `# @rbs` / `#:` whose `sig/` declaration disagrees with it,
      # under `--overwrite`: the whole `sig/` member is replaced by the inline line. Produced only when the run
      # asked for `--overwrite`; without it the same member is refused (`sig.skipped.inline-differs`), because
      # neither side is presumed right and a slot-by-slot mix of two declarations need not be a declaration.
      INLINE_OVERWRITE = :inline_overwrite

      # The classifications that actually produce a line in a generated `sig/`. Consulted by the renderer,
      # the writer and the generator's own post-passes; it lived as a private constant in the first two,
      # which is one fork too many for a list this load-bearing.
      EMITTABLE = [NEW_FILE, NEW_METHOD, TIGHTER_RETURN, INLINE_OVERWRITE].freeze

      DIAGNOSTIC_IDS = {
        NEW_FILE => "sig.generated.new-file",
        NEW_METHOD => "sig.generated.new-method",
        TIGHTER_RETURN => "sig.generated.tighter-return",
        INLINE_OVERWRITE => "sig.generated.inline-overwrite"
      }.freeze

      SKIP_DIAGNOSTIC_IDS = {
        complex_shape: "sig.skipped.complex-shape",
        user_authored: "sig.skipped.user-authored",
        untyped_return: "sig.skipped.untyped-return",
        # The generator rendered a line `rbs` itself rejects. Skipping the method keeps sig-gen useful on a
        # project with one pathological def, where failing the command outright would deny the user every other
        # signature; the count is reported so the defect is not silent. See {SigGen::RbsValidity}.
        unrenderable_rbs: "sig.skipped.unrenderable-rbs",
        # Issue #735 — the class's superclass chain does not terminate in a class the RBS environment knows,
        # so emitting the declaration would collapse the class on the next run rather than type it.
        unresolvable_superclass: "sig.skipped.unresolvable-superclass",
        # Issue #744 — a project subclass overrides this method and its override is NOT emitted, so the
        # declaration would be inherited by a subclass it does not describe.
        overridden_by_unsigned_subclass: "sig.skipped.overridden-by-unsigned-subclass",
        # ADR-112 WD4 — `sig_gen.inline_declared: skip` is set and the inline reader declares this member, so
        # a `sig/` copy would be a second declaration of it for a Steep that reads the inline annotations too.
        inline_declared: "sig.skipped.inline-declared",
        # ADR-112 WD4 — the member's class, or one it is nested in, is generic by an inline declaration (`# @rbs
        # generic T`) and `sig/` does not declare it yet. sig-gen writes no class type parameters, and a header
        # without them fails the class's definition build.
        inline_generic_class: "sig.skipped.inline-generic-class",
        # ADR-112 WD4 — the member is declared inline and in `sig/`, and the two disagree. A refusal, not a
        # skip: `--write` and `--check` exit 1 until a person reconciles them or passes `--overwrite`.
        inline_differs: "sig.skipped.inline-differs"
      }.freeze
    end
  end
end
