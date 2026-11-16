# frozen_string_literal: true

require_relative "../diagnostic"
require_relative "rule_ids"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — the `# rigor:disable` / `# rigor:disable-file` markers: reading them out of a file's comments,
      # dropping the diagnostics they cover, and the `suppression.*` diagnostics about a malformed marker.
      #
      # Entry points: {.filter_suppressed} (built-in rows), {.filter_plugin_suppressed} (plugin rows) and
      # {.suppression_marker_diagnostics}. The token vocabulary (`resolve_rule_token`, `expand_rule_tokens`,
      # `config_disabled?`, `plugin_row_disabled?`) stays in `rule_ids.rb`, which {SeverityStamp} reads without the
      # engine; this module calls into it and nothing else in `CheckRules`.
      module Suppression
        module_function

        # v0.0.2 #6 — diagnostic suppression. Three kinds of
        # suppression compose:
        #
        # - **Project-level**: `disabled_rules` is the
        #   project's `.rigor.yml` `disable:` list. Any
        #   diagnostic whose `rule` is in the list is dropped.
        # - **File-level** (v0.1.2): `# rigor:disable-file <rule1>,
        #   <rule2>` anywhere in the file suppresses the matching
        #   diagnostic for every line. `# rigor:disable-file all`
        #   suppresses every built-in rule across the file. Convention is
        #   to put the comment near the top, but Rigor accepts it
        #   anywhere — the comment scope is "this file" regardless
        #   of position.
        # - **In-source line**: `# rigor:disable <rule1>, <rule2>`
        #   on the same line as the offending expression
        #   suppresses the matching diagnostic for that line
        #   only. `# rigor:disable all` on a line suppresses
        #   every built-in rule on that line. A plugin's rows are
        #   not passed here; see {.filter_plugin_suppressed}.
        #
        # Both in-source forms are recognised only when the
        # marker is the FIRST thing in the comment, so a
        # directive quoted inside ordinary prose — as the bullets
        # above quote it — is not a directive. See the pattern
        # constants below.
        #
        # Diagnostics with `rule == nil` (parse errors, path
        # errors, internal analyzer errors) are NEVER
        # suppressed — they represent failures the user cannot
        # silence away.
        def filter_suppressed(diagnostics, comments:, disabled_rules:)
          line_suppressions, file_suppressions = parse_suppression_comments(comments)
          disabled = CheckRules.expand_rule_tokens(disabled_rules)

          diagnostics.reject do |diagnostic|
            rule = diagnostic.rule
            next false if rule.nil?
            next true if CheckRules.config_disabled?(rule, disabled)
            next true if file_suppressions.include?("all") || file_suppressions.include?(rule)

            line_rules = line_suppressions[diagnostic.line]
            line_rules && (line_rules.include?("all") || line_rules.include?(rule))
          end
        end

        # Issue #1953 — the in-source markers over the rows a plugin emitted while `path` was analysed
        # (`#diagnostics_for_file` and node rules). A row answers to a `plugin.<id>.<rule>` or `plugin.<id>` token
        # only ({.plugin_row_disabled?}); a bare id and `all` keep reaching built-in rows alone. `comments` are
        # `path`'s, so a row the plugin positioned in another file is left to the `disable:` list and the baseline.
        # The `disable:` list itself is applied to these rows by {SeverityStamp}, on every run shape.
        def filter_plugin_suppressed(diagnostics, path:, comments:)
          return diagnostics if diagnostics.empty?

          line_suppressions, file_suppressions = parse_suppression_comments(comments)
          return diagnostics if line_suppressions.empty? && file_suppressions.empty?

          diagnostics.reject do |diagnostic|
            next false unless diagnostic.path == path
            next true if CheckRules.plugin_row_disabled?(diagnostic, file_suppressions)

            line_rules = line_suppressions.fetch(diagnostic.line, nil)
            !line_rules.nil? && CheckRules.plugin_row_disabled?(diagnostic, line_rules)
          end
        end

        # Every suppression-recognition pattern below is anchored with `\A` against the COMMENT SLICE —
        # Prism hands us a slice that starts at the `#`, so `\A#` means "the marker is the first thing in
        # the comment". A real directive always has that shape, in both the whole-line form and the
        # trailing `code # rigor:disable <rule>` form; prose that merely quotes a directive
        # (`... like `# rigor:disable-file all` ...`) has text before the inner `#` and no longer
        # activates anything. Two consequences worth naming: a doc-tool `##` comment never activates (the
        # second `#` is neither whitespace nor the marker word), and an `=begin`/`=end` block comment
        # never activates either (its slice starts at `=begin`). Unanchored, these patterns silently
        # file-suppressed this very file — see issue #306.
        LINE_SUPPRESSION_PATTERN = /\A#\s*rigor:disable(?!-file)\s+(?<rules>[\w.,\s-]+)/
        private_constant :LINE_SUPPRESSION_PATTERN

        FILE_SUPPRESSION_PATTERN = /\A#\s*rigor:disable-file\s+(?<rules>[\w.,\s-]+)/
        private_constant :FILE_SUPPRESSION_PATTERN

        # A `rigor:disable[-file]` marker word regardless of whether any rule tokens follow. Used only by the
        # `suppression.empty` detection — the two suppression patterns above require at least one token
        # character, so a bare `# rigor:disable` never reaches them. The lookahead keeps
        # `rigor:disable-something-else` from counting as a marker.
        BARE_SUPPRESSION_MARKER = /\A#\s*rigor:disable(?<file>-file)?(?![\w-])(?<rest>.*)/
        private_constant :BARE_SUPPRESSION_MARKER

        # A `rigor:` marker word that is NOT part of Rigor's suppression grammar but reads like an attempted
        # suppression — the RuboCop-reflex spellings `rigor:disable-next-line <rules>` and
        # `rigor:enable <rules>`. These are invisible to both suppression patterns above (the hyphenated
        # suffix fails LINE_SUPPRESSION_PATTERN's `\s+` and BARE_SUPPRESSION_MARKER's lookahead), so without
        # surveillance they silently suppress nothing. Matches `disable-<suffix>` for any suffix other than
        # `file`, and `enable` with or without a suffix.
        UNKNOWN_SUPPRESSION_MARKER =
          /\A#\s*rigor:(?<marker>disable-(?!file(?![\w-]))[\w-]+|enable(?:-[\w-]+)?)(?![\w-])(?<rest>.*)/
        private_constant :UNKNOWN_SUPPRESSION_MARKER

        # @return pair of
        #   `(line_suppressions, file_suppressions)`. Line
        #   suppressions are keyed by source line number; file
        #   suppressions apply to every line.
        def parse_suppression_comments(comments)
          line_suppressions = Hash.new { |h, k| h[k] = Set.new }
          file_suppressions = Set.new
          comments.each do |comment|
            source = comment_text(comment)
            if (match = FILE_SUPPRESSION_PATTERN.match(source))
              absorb_suppression_tokens(match[:rules], file_suppressions)
            elsif (match = LINE_SUPPRESSION_PATTERN.match(source))
              absorb_suppression_tokens(match[:rules], line_suppressions[comment.location.start_line])
            end
          end
          [line_suppressions, file_suppressions]
        end

        # The comment's text for the suppression regexps. A comment is not validated by Ruby, so it may hold a
        # byte that is invalid in the file's encoding, and a regexp raises on such a string; the marker grammar
        # is ASCII, so scrubbing the bad bytes loses nothing. Positions come from `comment.location`, which is
        # byte-offset based and untouched.
        def comment_text(comment)
          text = comment.location.slice
          text.valid_encoding? ? text : text.scrub("?")
        end

        def absorb_suppression_tokens(raw, target)
          raw.to_s.split(/[\s,]+/).reject(&:empty?).each do |token|
            target.merge(CheckRules.expand_token(token))
          end
        end

        # PHPStan-`IgnoreParseErrorRule`-modelled surveillance over the suppression markers themselves: a
        # malformed or ineffective `# rigor:disable` / `# rigor:disable-file` comment must not silently no-op
        # (the typo'd `# rigor:disable call.undefined-metod` suppresses nothing and the user never learns).
        # Emits `suppression.unknown-rule` for every marker token that resolves to no known identifier, and
        # `suppression.empty` for a marker that lists no rules at all. The MATCHING semantics are deliberately
        # unchanged — an unknown token is still kept verbatim per the diagnostic-policy spec — so this is
        # additive surveillance only. Both diagnostics run before {.filter_suppressed} and flow through it,
        # so they are themselves suppressible (`# rigor:disable suppression.unknown-rule`) with no regress:
        # that token is known, so acknowledging it never re-fires the rule.
        def suppression_marker_diagnostics(path, comments)
          comments.each_with_object([]) do |comment, diagnostics|
            source = comment_text(comment)
            if (match = FILE_SUPPRESSION_PATTERN.match(source))
              validate_suppression_tokens(match[:rules], "rigor:disable-file", path, comment, diagnostics)
            elsif (match = LINE_SUPPRESSION_PATTERN.match(source))
              validate_suppression_tokens(match[:rules], "rigor:disable", path, comment, diagnostics)
            else
              diagnose_bare_suppression_marker(path, comment, source, diagnostics)
            end
          end
        end

        def validate_suppression_tokens(raw, marker, path, comment, diagnostics)
          tokens = raw.to_s.split(/[\s,]+/).reject(&:empty?)
          if tokens.empty?
            diagnostics << empty_suppression_diagnostic(path, comment, marker)
            return
          end

          tokens.each do |token|
            next if known_suppression_token?(token)

            diagnostics << unknown_suppression_rule_diagnostic(path, comment, marker, token)
          end
        end

        # A comment carrying the marker word but not the token-bearing suppression grammar. A remainder of
        # nothing but whitespace / commas is a genuinely empty marker (`# rigor:disable`); anything else is
        # left alone as an ordinary comment, matching the parse path, which never treats it as a
        # suppression either. Prose that merely quotes a marker is already excluded a step earlier by the
        # `\A` anchor, since the quotation is not at the start of the comment.
        def diagnose_bare_suppression_marker(path, comment, source, diagnostics)
          bare = BARE_SUPPRESSION_MARKER.match(source)
          if bare
            return unless bare[:rest].match?(/\A[\s,]*\z/)

            marker = bare[:file] ? "rigor:disable-file" : "rigor:disable"
            diagnostics << empty_suppression_diagnostic(path, comment, marker)
            return
          end

          diagnose_unknown_suppression_marker(path, comment, source, diagnostics)
        end

        # `# rigor:disable-next-line <rule>` / `# rigor:enable <rule>` — a marker word Rigor's grammar does
        # not recognise but that reads as an attempted suppression (the RuboCop reflex). Fires only when the
        # marker opens the comment and the remainder is empty or looks like a rule list, so prose mentioning
        # the spelling in backticks stays an ordinary comment — the same escape the empty-marker detection
        # observes.
        def diagnose_unknown_suppression_marker(path, comment, source, diagnostics)
          unknown = UNKNOWN_SUPPRESSION_MARKER.match(source)
          return if unknown.nil?

          rest = unknown[:rest]
          return unless rest.match?(/\A[\s,]*\z/) || rest.match?(/\A\s+[\w.,\s-]+\z/)

          diagnostics << unknown_suppression_marker_diagnostic(path, comment, unknown[:marker])
        end

        # True when a suppression token resolves to a diagnostic identifier some producer can emit: a
        # canonical CheckRules id, a legacy alias, the `all` wildcard, a family wildcard, a bare
        # non-catalogue engine id, or a dotted id under a known non-check family (`rbs_extended.*`,
        # `dynamic.*`, `rbs.*`, `pre-eval.*`, and any `plugin.`-prefixed id — plugins load dynamically, so
        # their rule vocabulary cannot be enumerated here and under-warning is the FP-safe direction).
        def known_suppression_token?(token)
          return true if %w[all pre-eval].include?(token)
          return true if ALL_RULES.include?(token) || LEGACY_RULE_ALIASES.key?(token) ||
                         RULE_FAMILIES.include?(token) || NON_CHECK_DIAGNOSTIC_IDS.include?(token)

          family, rest = token.split(".", 2)
          !rest.nil? && NON_CHECK_DIAGNOSTIC_FAMILIES.include?(family)
        end

        def unknown_suppression_rule_diagnostic(path, comment, marker, token)
          Diagnostic.new(
            path: path,
            line: comment.location.start_line,
            column: comment.location.start_column + 1,
            message: "unknown rule `#{token}` in `# #{marker}` — the token matches no known rule, alias, " \
                     "or family, so this suppression has no effect. Likely a typo; `rigor explain <rule>` " \
                     "lists the canonical ids.",
            severity: :warning,
            rule: RULE_SUPPRESSION_UNKNOWN_RULE,
            source_family: :builtin
          )
        end

        def unknown_suppression_marker_diagnostic(path, comment, marker)
          Diagnostic.new(
            path: path,
            line: comment.location.start_line,
            column: comment.location.start_column + 1,
            message: "unrecognised suppression marker `rigor:#{marker}` — Rigor's markers are " \
                     "`# rigor:disable <rules>` (suppresses on its own line) and " \
                     "`# rigor:disable-file <rules>`, so this comment suppresses nothing.",
            severity: :warning,
            rule: RULE_SUPPRESSION_UNKNOWN_MARKER,
            source_family: :builtin
          )
        end

        def empty_suppression_diagnostic(path, comment, marker)
          Diagnostic.new(
            path: path,
            line: comment.location.start_line,
            column: comment.location.start_column + 1,
            message: "`# #{marker}` lists no rules, so this suppression has no effect. Name the rules to " \
                     "suppress (`# #{marker} call.undefined-method`) or use `# #{marker} all`.",
            severity: :warning,
            rule: RULE_SUPPRESSION_EMPTY,
            source_family: :builtin
          )
        end
      end
    end
  end
end
