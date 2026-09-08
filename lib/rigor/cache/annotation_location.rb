# frozen_string_literal: true

require "rbs"

module Rigor
  module Cache
    # The `RBS::AST::Annotation` location carry (issue #799): the two halves of the `marshal_dump` /
    # `marshal_load` pair {file:lib/rigor/cache/rbs_environment_marshal_patch.rb the env-cache Marshal patch}
    # installs on `RBS::AST::Annotation`, plus the buffer a reconstructed location points at. That file's
    # header carries the why; this one is the how.
    #
    # Nothing here reconstructs the annotation's SOURCE — the cached env has no file contents, and a
    # consumer that wants the text already has `Annotation#string`. What it reconstructs is the pair of
    # `(line, column)` answers `RBS::Location` gives, so a diagnostic positioned on the directive reads the
    # same line warm as it does cold.
    module AnnotationLocation
      # The two positions {Buffer} distinguishes. `RBS::Location` addresses its buffer by character
      # offset, and the reconstruction has no content to offset into, so the offsets are used as tags:
      # 0 is "the start pair", 1 is "the end pair".
      START_POS = 0
      END_POS = 1

      # A content-less `RBS::Buffer` that answers `pos_to_loc` from the pairs the cold parse had.
      #
      # Answering there is all it takes: `RBS::Location#start_line` and its three siblings are C methods
      # that resolve the offset through `buffer.pos_to_loc`, so the reconstructed Location reports the real
      # position without the buffer having to hold (or synthesize) the file it came from. The alternative —
      # a synthetic content string of `line - 1` newlines — is exact only while an annotation stays on one
      # line, and `%a{...}` may span two.
      class Buffer < ::RBS::Buffer
        def initialize(name:, start_loc:, end_loc:)
          super(name: name, content: "")
          @start_loc = start_loc
          @end_loc = end_loc
        end

        def pos_to_loc(pos)
          pos == START_POS ? @start_loc : @end_loc
        end
      end

      module_function

      # @return `[name, start_line, start_column, end_line, end_column]`, or nil when there is
      #   no location to carry. Fail-soft: a location whose buffer cannot answer is dumped as nil rather
      #   than failing the whole environment's dump.
      def dump(location)
        return nil if location.nil?

        buffer = location.buffer
        name = buffer.respond_to?(:name) ? buffer.name.to_s : nil
        [name, location.start_line, location.start_column, location.end_line, location.end_column]
      rescue StandardError
        nil
      end

      # @param payload — what {dump} produced.
      def load(payload)
        return nil if payload.nil?

        name, start_line, start_column, end_line, end_column = payload
        name = ::RBS::Location::CACHED_BUFFER_NAME if name.nil? || name.empty?
        buffer = Buffer.new(name: name, start_loc: [start_line, start_column], end_loc: [end_line, end_column])
        ::RBS::Location.new(buffer: buffer, start_pos: START_POS, end_pos: END_POS)
      rescue StandardError
        nil
      end
    end
  end
end
