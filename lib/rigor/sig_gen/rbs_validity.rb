# frozen_string_literal: true

require "rbs"

module Rigor
  module SigGen
    # Parses what sig-gen is about to emit, before it is emitted.
    #
    # Two rendering bugs have shipped RBS that `rbs` itself rejects — a non-identifier record key
    # (`{ :"data-contrast" => T }`) and a `&block` constructor parameter rendered before the parens
    # (`(**untyped, ?{ (?) -> void })`). Both were found downstream, as a poisoned `sig/` tree: the file is
    # quarantined, its types vanish, and (for a project adopting `reject-unparseable-signatures`) the build
    # fails. A generator that can poison its own consumer's build is worth guarding at the source.
    #
    # So this is not a check for ONE bug — it is the guard that turns the whole rendering-bug *class* from a
    # silent bad artifact into a caught error naming the method that could not be rendered. It is cheap: the
    # text is already in memory, and `RBS::Parser` is the same C parser the consumer will use, so it is exactly
    # the oracle that matters (not an approximation of it).
    module RbsValidity
      # A rendered method line (`def foo: () -> String`) is a fragment, not a compilation unit — it has to be
      # wrapped to be parsed at all. The wrapper name is irrelevant to the parse and never reaches disk.
      PROBE_CLASS = "RigorSigGenProbe"

      module_function

      # @param line [String] a rendered RBS method line, e.g. `def self.parse: (String) -> Integer`.
      # @return [String, nil] the parse error's first line, or nil when the line is valid.
      def method_line_error(line)
        return nil if line.nil?

        source_error("class #{PROBE_CLASS}\n  #{line}\nend\n")
      end

      # @param source [String] a complete `.rbs` file's text.
      # @return [String, nil] the parse error's first line, or nil when the file is valid.
      def source_error(source)
        ::RBS::Parser.parse_signature(::RBS::Buffer.new(name: "(rigor sig-gen)", content: source))
        nil
      rescue ::RBS::ParsingError => e
        e.message.to_s.lines.first.to_s.strip
      end
    end
  end
end
