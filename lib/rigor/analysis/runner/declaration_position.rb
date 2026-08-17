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
      module DeclarationPosition
        CONFIG_PATH = ".rigor.yml"
        RUBY_EXTENSION = ".rb"
        private_constant :RUBY_EXTENSION

        module_function

        # @param finding [#location, #spelling]
        # @param sources [Hash{String => String}] in-memory sources, for the buffer-backed run path
        # @return [Array(String, Integer)] `[path, line]`
        def of(finding, sources: {})
          location = finding.location
          return [CONFIG_PATH, 1] if location.nil?

          path, _, raw_line = location.rpartition(":")
          return [CONFIG_PATH, 1] if path.empty?

          line = raw_line.to_i
          line = 1 unless line.positive?
          return [path, line] unless path.end_with?(RUBY_EXTENSION)

          [path, inline_line(path, finding.spelling, sources) || line]
        end

        # rbs-inline's writer re-emits the author's own comment block ABOVE the annotation it generates,
        # so a line number read out of the synthesized buffer drifts from the `.rb` line the author
        # actually wrote — by the length of every method body above it. The annotation's own text is
        # unique enough to find again, so the Ruby file is what answers. One read, and only when a
        # finding already exists.
        def inline_line(path, spelling, sources)
          return nil if spelling.nil?

          source = sources[path] || File.read(path)
          source.each_line.with_index(1) { |line, number| return number if line.include?(spelling) }
          nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
