# frozen_string_literal: true

module Rigor
  module Analysis
    # Detects when a `.rb` file is actually an ERB template — a Rails
    # generator `templates/foo.rb` shape that uses `<%= ... %>` to
    # interpolate identifiers. Prism rejects the template as invalid
    # Ruby and the analyzer emits one parse-error diagnostic per scrap
    # the parser tripped over (≈ 20 on Redmine's
    # `lib/generators/redmine_plugin_model/templates/migration.rb`),
    # all of them noise from the user's perspective. The runner / worker
    # consults this detector before turning parse errors into
    # diagnostics; an ERB-shaped source is silently skipped.
    #
    # Detection is byte-level on the raw source: any occurrence of the
    # `%>` closing marker proves the file is an ERB template. `%>`
    # cannot appear in valid Ruby — `%` is a binary operator that
    # requires an operand on its right side, never `>`. The opening
    # `<%` is ambiguous in principle (`x<%y` parses as `x < %y`, a
    # comparison against a `%`-literal) but a real Ruby file with that
    # shape would still not contain the closing `%>`.
    module ErbTemplateDetector
      ERB_CLOSING_MARKER = /%>/

      module_function

      # @param parse_result [Prism::ParseResult]
      # @return [Boolean] true when the parsed source looks like an
      #   ERB template (parse errors expected; analysis should skip).
      def template?(parse_result)
        source = parse_result.source.source
        return false unless source.is_a?(String) && !source.empty?

        ERB_CLOSING_MARKER.match?(source)
      end
    end
  end
end
