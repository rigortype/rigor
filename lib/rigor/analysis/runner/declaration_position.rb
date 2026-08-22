# frozen_string_literal: true

module Rigor
  module Analysis
    class Runner
      # Where an `effect.unknown-label` finding is positioned (ADR-103 WD14; #384).
      #
      # The declaration, not the method: this is a fact about what the author wrote, and the fix is on
      # that line. A `.rbs` position is the right answer here even though its sibling deliberately avoids
      # one (the `rbs_extended.unsatisfied-conformance` precedent) — there is no Ruby `def` that could
      # carry the typo. A value written in configuration has no location at all and lands at
      # `.rigor.yml:1`, the `rbs.coverage.quarantined-signature` precedent.
      # A declaration's `location` is already the position a reader can open, `.rbs` and rbs-inline
      # alike: the synthesized-buffer line is re-anchored onto the Ruby file where the envelope is
      # built ({Rigor::Effects::InlineAnchor}, #432), so this module only has to split it. Doing the
      # re-anchoring here as well used to be the fix, and it could not tell two identically-spelled
      # annotations in one file apart — every finding in it landed on the first.
      module DeclarationPosition
        CONFIG_PATH = ".rigor.yml"

        module_function

        # @param finding [#location]
        # @return [Array(String, Integer)] `[path, line]`
        def of(finding)
          location = finding.location
          return [CONFIG_PATH, 1] if location.nil?

          path, _, raw_line = location.rpartition(":")
          return [CONFIG_PATH, 1] if path.empty?

          line = raw_line.to_i
          [path, line.positive? ? line : 1]
        end
      end
    end
  end
end
