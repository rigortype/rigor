# frozen_string_literal: true

require_relative "hashing/xxh3"

module Rigor
  # `rigor lens`: a declaration map of the requested files with type provenance, computed as `rigor check` computes
  # them (ADR-113; the output contract is docs/internal-spec/lens.md).
  module Lens
    SCHEMA = "lens/v0"
    # Bumped on every breaking change to the `lens/v0` document (docs/internal-spec/lens.md § Status).
    REVISION = 1
    CAPABILITIES = %w[class module method attribute constant module_function builder alias body_return
                      diagnostics inputs].freeze

    module_function

    # A Prism location as the document's span object: 1-based lines, 0-based byte columns and offsets.
    def span(location)
      { "start_line" => location.start_line, "start_column" => location.start_column,
        "end_line" => location.end_line, "end_column" => location.end_column,
        "start_offset" => location.start_offset, "end_offset" => location.end_offset }
    end

    # The span from the first to the last of a site's contract comments, or nil when it has none.
    def contract_span(comments)
      return nil if comments.empty?

      first = comments.first.location
      last = comments.last.location
      { "start_line" => first.start_line, "start_column" => first.start_column, "end_line" => last.end_line,
        "end_column" => last.end_column, "start_offset" => first.start_offset, "end_offset" => last.end_offset }
    end

    def digest(bytes)
      "xxh3-64:#{Hashing::XXH3.file_hash(bytes)}"
    end
  end
end

require_relative "lens/run"
require_relative "lens/document"
