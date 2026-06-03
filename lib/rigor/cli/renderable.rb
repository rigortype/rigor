# frozen_string_literal: true

require "optionparser"

module Rigor
  class CLI
    # Output-format dispatch shared by the `--format text|json` renderers.
    #
    # Each renderer included this and then implemented `render_text` /
    # `render_json`; the `render(data, format:)` entry point — route by
    # the format string, raise one consistent `OptionParser::InvalidArgument`
    # on anything else — was copied verbatim into every one. Centralising
    # it keeps the unsupported-format wording and the text/json contract
    # in a single place as new renderers and formats are added.
    module Renderable
      def render(data, format:)
        case format
        when "text" then render_text(data)
        when "json" then render_json(data)
        else
          raise OptionParser::InvalidArgument, "unsupported format: #{format}"
        end
      end
    end
  end
end
