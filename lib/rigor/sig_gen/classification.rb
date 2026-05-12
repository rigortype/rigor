# frozen_string_literal: true

module Rigor
  module SigGen
    # The five classifications a candidate method falls into
    # after the generator has compared the inferred return
    # type against the project's existing RBS.
    #
    # The strings are the diagnostic-family identifiers ADR-14
    # reserves under `sig.*`; the MVP carries them as plain
    # symbols on the method candidate and renders the matching
    # identifier in JSON / text output. They are added to the
    # diagnostic family hierarchy in `docs/type-specification/
    # diagnostic-policy.md` even though slice 1 does not yet
    # emit them as diagnostics.
    module Classification
      NEW_FILE = :new_file
      NEW_METHOD = :new_method
      TIGHTER_RETURN = :tighter_return
      EQUIVALENT = :equivalent
      SKIPPED = :skipped

      DIAGNOSTIC_IDS = {
        NEW_FILE => "sig.generated.new-file",
        NEW_METHOD => "sig.generated.new-method",
        TIGHTER_RETURN => "sig.generated.tighter-return"
      }.freeze

      SKIP_DIAGNOSTIC_IDS = {
        complex_shape: "sig.skipped.complex-shape",
        user_authored: "sig.skipped.user-authored",
        untyped_return: "sig.skipped.untyped-return"
      }.freeze
    end
  end
end
