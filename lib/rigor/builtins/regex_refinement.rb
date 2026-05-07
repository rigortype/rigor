# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Builtins
    # Maps a curated table of canonical regex sub-patterns onto the
    # imported refinement carriers Rigor already ships
    # (`decimal-int-string`, `hex-int-string`, `octal-int-string`,
    # `lowercase-string`, `uppercase-string`, `numeric-string`).
    # See `docs/type-specification/imported-built-in-types.md` for
    # the registry the refinements come from and `docs/MILESTONES.md`
    # § "v0.1.1 — Planned" Track 1 slice 1 for the binding scope of
    # this recogniser.
    #
    # The intended consumer is `Inference::Narrowing.analyse_match_write`:
    # given `if /(?<year>\d+)/ =~ str; year; end`, the v0.1.0
    # baseline narrows `year` to plain `String`; v0.1.1 introspects
    # the regex source and narrows further to
    # `decimal-int-string` whenever the named-capture body matches
    # one of the rows in {RULES}.
    #
    # Recognised body shapes (each row admits the `+` quantifier
    # and the bounded `{n}` / `{n,m}` forms with `n >= 1`):
    #
    #   - `\d`                     -> decimal-int-string
    #   - `\h`                     -> hex-int-string
    #   - `[0-9a-fA-F]`            -> hex-int-string
    #   - `[0-9a-f]`, `[0-9A-F]`   -> hex-int-string
    #   - `[0-7]`                  -> octal-int-string
    #   - `[a-z]`                  -> lowercase-string
    #   - `[A-Z]`                  -> uppercase-string
    #   - `[[:digit:]]`            -> numeric-string
    #
    # Anything outside the table returns `nil` so the calling
    # narrowing site falls back to its previous behaviour
    # (plain `String`). Arbitrary regex semantic equivalence is
    # undecidable, so the table is intentionally a small audited
    # set of canonical shapes rather than a general equivalence
    # checker.
    module RegexRefinement
      # `+` (one-or-more) or `{n}` / `{n,m}` (n >= 1, m >= n).
      # The bound check is enforced separately by
      # {valid_bounds?} after the structural match succeeds, so
      # forms like `\d{0,5}` or `\d{5,3}` reject even though they
      # parse syntactically.
      QUANTIFIER_SOURCE = '(?:\+|\{\d+(?:,\d+)?\})'
      private_constant :QUANTIFIER_SOURCE

      RULES = [
        [/\A\\d#{QUANTIFIER_SOURCE}\z/, :decimal_int_string],
        [/\A\\h#{QUANTIFIER_SOURCE}\z/, :hex_int_string],
        [/\A\[0-9a-fA-F\]#{QUANTIFIER_SOURCE}\z/, :hex_int_string],
        [/\A\[0-9a-f\]#{QUANTIFIER_SOURCE}\z/, :hex_int_string],
        [/\A\[0-9A-F\]#{QUANTIFIER_SOURCE}\z/, :hex_int_string],
        [/\A\[0-7\]#{QUANTIFIER_SOURCE}\z/, :octal_int_string],
        [/\A\[a-z\]#{QUANTIFIER_SOURCE}\z/, :lowercase_string],
        [/\A\[A-Z\]#{QUANTIFIER_SOURCE}\z/, :uppercase_string],
        [/\A\[\[:digit:\]\]#{QUANTIFIER_SOURCE}\z/, :numeric_string]
      ].freeze
      private_constant :RULES

      BOUND_RE = /\{(\d+)(?:,(\d+))?\}\z/
      private_constant :BOUND_RE

      module_function

      # @param body [String, nil] a regex sub-pattern, typically the
      #   inner body of a `(?<name>body)` named capture. Anchors
      #   (`\A`, `\z`, `^`, `$`) are not stripped — the recogniser
      #   table targets bodies that the regex engine treats as
      #   anchored to the capture group bounds.
      # @return [Rigor::Type, nil] the matching imported refinement
      #   carrier, or `nil` if `body` is not a recognised shape.
      def for_capture_body(body)
        return nil if body.nil? || body.empty?

        rule = RULES.find { |pattern, _| pattern.match?(body) }
        return nil if rule.nil?
        return nil unless valid_bounds?(body)

        Type::Combinator.public_send(rule.last)
      end

      # Filters the bounded-quantifier forms to ones whose lower
      # bound is at least 1 and whose upper bound (if any) is at
      # least the lower bound. Without this, `\d{0,5}` would be
      # accepted even though it admits the empty string, which is
      # not a valid `decimal-int-string`.
      def valid_bounds?(body)
        m = BOUND_RE.match(body)
        return true if m.nil?

        low = Integer(m[1])
        return false if low < 1

        high = m[2] && Integer(m[2])
        return true if high.nil?

        low <= high
      end
    end
  end
end
