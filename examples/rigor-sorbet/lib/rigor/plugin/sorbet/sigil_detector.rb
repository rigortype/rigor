# frozen_string_literal: true

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Reads Sorbet's `# typed: <level>` magic comment from the
      # head of a file. Sorbet's own contract (per
      # [`static.md`](https://sorbet.org/docs/static)) requires
      # the sigil to appear at the top of the file before any
      # Ruby code. We're slightly more lenient here — the sigil
      # may appear after a few comment / blank lines (matching
      # what Sorbet itself accepts in practice) but we stop
      # scanning once we hit a non-comment, non-blank line.
      #
      # Recognised levels: `:ignore` / `:false` / `:true` /
      # `:strict` / `:strong`. Falls back to `:false` (Sorbet's
      # default) when no sigil is present, matching how Sorbet
      # treats sigil-less files.
      #
      # Slice 5 of ADR-11 uses this purely at catalog-harvest
      # time: `# typed: ignore` files are skipped entirely (the
      # plugin records no sigs from them). The other levels are
      # detected for forward compatibility but treated
      # identically — per-call-site sigil honouring (e.g. only
      # firing `T.let` recognition in `# typed: true`+ files)
      # requires threading the file path through
      # `flow_contribution_for`, which lives behind a future
      # plugin-contract widening slice.
      module SigilDetector
        # Sorbet's strictness-level names. Stored as symbols to
        # match the analyzer's existing convention for level
        # identifiers; the `:true` / `:false` symbols here are
        # level *names* (the textual sigil values) and are
        # intentionally distinct from the `true` / `false`
        # boolean literals.
        VALID_LEVELS = %i[ignore false true strict strong].freeze
        DEFAULT_LEVEL = :false # rubocop:disable Lint/BooleanSymbol
        SIGIL_REGEX = /\A\s*#\s*typed\s*:\s*(ignore|false|true|strict|strong)\s*\z/

        # Cap on how many lines we scan before giving up. Sorbet
        # doesn't formally specify a cap, but the sigil
        # convention is "near the top of the file"; 10 lines is
        # generous and bounds the parse cost on enormous files.
        MAX_HEAD_LINES = 10

        module_function

        # @param contents [String] raw file contents.
        # @return [Symbol] one of {VALID_LEVELS}; defaults to
        #   {DEFAULT_LEVEL} for sigil-less or malformed-sigil
        #   files.
        def detect(contents)
          return DEFAULT_LEVEL if contents.nil? || contents.empty?

          contents.each_line.with_index do |line, index|
            break if index >= MAX_HEAD_LINES

            stripped = line.strip
            next if stripped.empty?

            match = SIGIL_REGEX.match(stripped)
            return match[1].to_sym if match
            # First non-blank line that isn't a sigil-shaped
            # comment ends the scan: Sorbet's parser stops at
            # the first directive-or-code line.
            break unless stripped.start_with?("#")
          end

          DEFAULT_LEVEL
        end

        # @param level [Symbol]
        # @return [Boolean] true when `# typed: ignore`. The
        #   harvest pipeline calls this to short-circuit
        #   walking the file's AST.
        def ignored?(level)
          level == :ignore
        end
      end
    end
  end
end
