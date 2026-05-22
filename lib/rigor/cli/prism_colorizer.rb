# frozen_string_literal: true

require "prism"

module Rigor
  class CLI
    # Re-lexes Ruby source with Prism and wraps each token in an
    # ANSI colour escape, producing IRB-style syntax highlighting.
    #
    # Rigor ships no runtime dependencies (ADR-0), so the `irb`
    # gem's `IRB::Color` is not available; this module reproduces
    # the same effect from Prism's own token stream. `rigor
    # annotate` re-parses its annotated output through here before
    # printing.
    module PrismColorizer
      module_function

      RESET = "\e[0m"

      # token category => ANSI SGR parameters.
      CATEGORY_SGR = {
        comment: "90",      # bright black (faint grey)
        keyword: "33",      # yellow
        literal_kw: "36",   # cyan   — nil / true / false / self
        number: "34",       # blue
        string: "32",       # green
        symbol: "36",       # cyan
        constant: "1;34",   # bold blue
        variable: "34",     # blue   — @ivar / @@cvar / $gvar
        default: nil
      }.freeze

      LITERAL_KEYWORDS = %i[
        KEYWORD_NIL KEYWORD_TRUE KEYWORD_FALSE KEYWORD_SELF
        KEYWORD___FILE__ KEYWORD___LINE__ KEYWORD___ENCODING__
      ].freeze

      VARIABLE_TOKENS = %i[INSTANCE_VARIABLE CLASS_VARIABLE GLOBAL_VARIABLE].freeze

      # @param source [String] Ruby source.
      # @return [String] the source with ANSI colour escapes, or
      #   the input unchanged when lexing surfaces an error.
      def colorize(source)
        result = Prism.lex(source)
        return source unless result.errors.empty?

        render(source, result.value)
      end

      def render(source, lexed)
        out = +""
        offset = 0
        previous_type = nil
        lexed.each do |entry|
          token = entry.first
          location = token.location
          out << source[offset...location.start_offset]
          break if token.type == :EOF

          text = source[location.start_offset...location.end_offset]
          out << paint(text, effective_category(token.type, previous_type))
          offset = location.end_offset
          previous_type = token.type
        end
        out << (source[offset..] || "")
        out
      end

      # The token after a `SYMBOL_BEGIN` (`:`) carries the symbol
      # name — and Prism lexes `:then` / `:class` etc. as a
      # keyword token — so it is painted with the symbol colour
      # regardless of its own token type.
      def effective_category(token_type, previous_type)
        return :symbol if previous_type == :SYMBOL_BEGIN

        category(token_type)
      end

      def paint(text, category)
        sgr = CATEGORY_SGR.fetch(category)
        return text if sgr.nil? || text.empty?

        # Keep a trailing newline outside the colour span so the
        # reset sits on the token's own line (comments include it).
        trailing = text[/\s*\z/] || ""
        body = trailing.empty? ? text : text[0...-trailing.length]
        return text if body.empty?

        "\e[#{sgr}m#{body}#{RESET}#{trailing}"
      end

      def category(token_type)
        name = token_type.to_s
        return :comment if token_type == :COMMENT
        return :literal_kw if LITERAL_KEYWORDS.include?(token_type)
        return :keyword if name.start_with?("KEYWORD_")
        return :number if number_token?(name)
        return :string if name.start_with?("STRING_", "HEREDOC_") || token_type == :STRING_CONTENT
        return :symbol if name.start_with?("SYMBOL_")
        return :constant if token_type == :CONSTANT
        return :variable if VARIABLE_TOKENS.include?(token_type)

        :default
      end

      def number_token?(name)
        name.start_with?("INTEGER", "FLOAT", "RATIONAL", "IMAGINARY")
      end
    end
  end
end
