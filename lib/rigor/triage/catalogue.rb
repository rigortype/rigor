# frozen_string_literal: true

require_relative "hint"

module Rigor
  module Triage
    # ADR-23 § "Heuristic catalogue" — the six v1 recognisers.
    #
    # {.recognise} runs them in order over the diagnostic stream.
    # Each recogniser sees only the diagnostics not yet claimed by
    # an earlier one, so a `5.minutes` diagnostic counted by H1
    # (ActiveSupport) is not re-counted by H2 (monkey-patch).
    #
    # WD3: recognisers key on the structured `qualified_rule`
    # first; where they additionally need the receiver type or
    # method name they parse the diagnostic message. A parse
    # failure degrades to "skip this diagnostic" — never a crash.
    module Catalogue
      module_function

      UNDEFINED_METHOD_RULE = "call.undefined-method"

      # `undefined method `foo' for <receiver>`
      UNDEF_METHOD = /\Aundefined method [`'"]([^`'"]+)['"`] for (.+)\z/

      # ActiveSupport `core_ext` selectors, grouped by the core
      # class they extend. Survey-grounded (the dominant clusters
      # from the five-project survey + the Mastodon measurement).
      AS_NUMERIC = %w[
        day days hour hours minute minutes second seconds week weeks
        fortnight fortnights month months year years
        byte bytes kilobyte kilobytes megabyte megabytes gigabyte gigabytes
        terabyte terabytes petabyte petabytes exabyte exabytes
        ago since from_now in_milliseconds
      ].freeze
      AS_STRING = %w[
        squish squish! strip_heredoc html_safe underscore camelize camelcase
        pluralize singularize titleize titlecase humanize dasherize
        parameterize tableize classify constantize safe_constantize
        demodulize deconstantize foreign_key indent indent! truncate
        truncate_words to_datetime to_date to_time exclude? at from
        remove remove! mb_chars upcase_first downcase_first
      ].freeze
      AS_HASH = %w[
        deep_dup deep_merge deep_merge! symbolize_keys symbolize_keys!
        stringify_keys stringify_keys! deep_symbolize_keys deep_stringify_keys
        deep_transform_keys deep_transform_keys! deep_transform_values
        except! with_indifferent_access assert_valid_keys
        reverse_merge reverse_merge! extract!
      ].freeze
      AS_ARRAY = %w[
        to_sentence in_groups_of in_groups second third fourth fifth
        forty_two extract_options! wrap deep_dup
      ].freeze
      AS_TIMEDATE = %w[
        zone current beginning_of_day end_of_day beginning_of_week
        end_of_week beginning_of_month end_of_month beginning_of_year
        end_of_year next_week prev_week next_month prev_month
        tomorrow yesterday all_day all_week all_month advance
        ago since change to_fs
      ].freeze
      AS_BY_CLASS = {
        "Integer" => AS_NUMERIC, "Float" => AS_NUMERIC, "Numeric" => AS_NUMERIC,
        "String" => AS_STRING, "Symbol" => AS_STRING,
        "Hash" => AS_HASH, "Array" => AS_ARRAY,
        "Time" => AS_TIMEDATE, "Date" => AS_TIMEDATE,
        "DateTime" => AS_TIMEDATE, "ActiveSupport::TimeWithZone" => AS_TIMEDATE
      }.freeze
      private_constant :AS_NUMERIC, :AS_STRING, :AS_HASH, :AS_ARRAY, :AS_TIMEDATE

      # ActiveRecord query-builder methods. When flagged on an
      # `Array[...]` receiver they signal a relation misinference.
      AR_QUERY_METHODS = %w[
        where joins includes preload eager_load references select
        order reorder distinct group having limit offset pluck
        find_by find_each find_in_batches in_batches none rewhere
        unscope merge except_query extending
      ].freeze
      private_constant :AR_QUERY_METHODS

      SYSTEMIC_THRESHOLD = 8       # (file, rule) count → "systemic"
      MONKEY_PATCH_MIN_FILES = 3   # same (method, receiver) across N files
      GENUINE_BUG_MAX_COUNT = 5    # rule total ≤ N → "likely genuine bug"
      private_constant :SYSTEMIC_THRESHOLD, :MONKEY_PATCH_MIN_FILES, :GENUINE_BUG_MAX_COUNT

      # @param diagnostics [Array<Analysis::Diagnostic>]
      # @return [Array<Hint>]
      def recognise(diagnostics)
        claimed = {}.compare_by_identity
        recognisers.filter_map do |recogniser|
          pool = diagnostics.reject { |d| claimed[d] }
          hint, matched = send(recogniser, pool)
          next unless hint

          matched.each { |d| claimed[d] = true }
          hint
        end
      end

      # H4 (ActiveRecord query methods) runs before H2 (generic
      # monkey-patch): a known AR method on `Array[...]` deserves
      # the precise relation-misinference hint, not the generic
      # "project core-ext" guess H2 would otherwise claim it for.
      def recognisers
        %i[h1_activesupport h4_ar_relation h3_gem_without_rbs
           h2_monkey_patch h5_systemic_cluster h6_genuine_bugs]
      end

      # --- H1 — likely ActiveSupport core_ext --------------------
      def h1_activesupport(pool)
        matched = pool.select do |d|
          parsed = parse_undefined_method(d)
          parsed && activesupport?(parsed[:receiver], parsed[:method])
        end
        return nil if matched.empty?

        [Hint.new(
          id: "activesupport-core-ext", confidence: :likely,
          diagnostic_count: matched.size,
          summary: "undefined-method on core classes (#{top_methods(matched)}) — " \
                   "ActiveSupport monkey-patches these",
          action: "Wire the rigor-activesupport-core-ext RBS bundle via " \
                  "`signature_paths:` in .rigor.yml."
        ), matched]
      end

      # --- H2 — likely a project monkey-patch / refinement -------
      def h2_monkey_patch(pool)
        groups = undefined_method_groups(pool).select do |(_method, _recv), diags|
          diags.map(&:path).uniq.size >= MONKEY_PATCH_MIN_FILES
        end
        return nil if groups.empty?

        matched = groups.values.flatten(1)
        [Hint.new(
          id: "project-monkey-patch", confidence: :possible,
          diagnostic_count: matched.size,
          summary: "same method undefined across many files " \
                   "(#{describe_groups(groups)}) — likely a project core-ext / refinement",
          action: "Register the defining file via `pre_eval:` (ADR-17), " \
                  "or add an RBS overlay for the method."
        ), matched]
      end

      # --- H3 — gem ships no RBS ---------------------------------
      def h3_gem_without_rbs(pool)
        notice = pool.find { |d| d.message.match?(/gem\(s\).*have no RBS available/) }
        return nil unless notice

        count = notice.message[/\A(\d+) gem/, 1] || "some"
        [Hint.new(
          id: "gem-without-rbs", confidence: :likely, diagnostic_count: 1,
          summary: "#{count} Gemfile.lock gem(s) ship no RBS — undefined-method " \
                   "diagnostics on their classes are expected, not bugs",
          action: "`rbs collection install`, ship `sig/` in the gem, or opt the " \
                  "gem into `dependencies.source_inference:` (ADR-10)."
        ), [notice]]
      end

      # --- H4 — possible ActiveRecord relation misinference ------
      def h4_ar_relation(pool)
        matched = pool.select do |d|
          parsed = parse_undefined_method(d)
          parsed && AR_QUERY_METHODS.include?(parsed[:method]) &&
            parsed[:receiver].start_with?("Array[")
        end
        return nil if matched.empty?

        [Hint.new(
          id: "activerecord-relation-misinference", confidence: :possible,
          diagnostic_count: matched.size,
          summary: "ActiveRecord query methods (#{top_methods(matched)}) flagged " \
                   "on an `Array[...]` receiver",
          action: "Enable rigor-activerecord; if it persists the receiver is an " \
                  "engine misinference (an AR relation read as Array) — worth a Rigor issue."
        ), matched]
      end

      # --- H5 — systemic single-file cluster ---------------------
      def h5_systemic_cluster(pool)
        bucket = pool.group_by { |d| [d.path, rule_of(d)] }
                     .select { |_key, diags| diags.size >= SYSTEMIC_THRESHOLD }
                     .max_by { |_key, diags| diags.size }
        return nil unless bucket

        (path, rule), matched = bucket
        [Hint.new(
          id: "systemic-file-cluster", confidence: :likely,
          diagnostic_count: matched.size,
          summary: "#{matched.size}× `#{rule}` concentrated in #{path}",
          action: "Likely systemic in this file — one fix may clear many; " \
                  "or a strong baseline candidate (ADR-22)."
        ), matched]
      end

      # --- H6 — low-count scattered rules = likely genuine bugs --
      def h6_genuine_bugs(pool)
        small = pool.group_by { |d| rule_of(d) }
                    .select { |rule, diags| rule && diags.size.between?(1, GENUINE_BUG_MAX_COUNT) }
        return nil if small.empty?

        matched = small.values.flatten(1)
        rules = small.map { |rule, diags| "#{rule}×#{diags.size}" }.sort.join(", ")
        [Hint.new(
          id: "genuine-bugs", confidence: :likely,
          diagnostic_count: matched.size,
          summary: "low-count, scattered rules (#{rules})",
          action: "Review these first — low-count diagnostics are usually the " \
                  "localised bugs Rigor caught, not systemic noise."
        ), matched]
      end

      # --- shared helpers ----------------------------------------

      def parse_undefined_method(diag)
        return nil unless rule_of(diag) == UNDEFINED_METHOD_RULE

        m = UNDEF_METHOD.match(diag.message)
        return nil unless m

        receiver = receiver_class(m[2])
        return nil unless receiver

        { method: m[1], receiver: receiver }
      end

      # Normalises a message receiver token to a class name.
      # Integer / string / symbol literals fold to their class;
      # `Foo[...]` keeps the `Array[...]` form (H4 needs it);
      # `singleton(Foo)` and bare `Foo` fold to `Foo`.
      def receiver_class(token)
        t = token.strip
        return "Integer" if t.match?(/\A-?\d+\z/)
        return "Float"   if t.match?(/\A-?\d+\.\d+\z/)
        return "String"  if t.start_with?('"', "'")
        return "Symbol"  if t.start_with?(":")

        singleton = t[/\Asingleton\(([\w:]+)\)\z/, 1]
        return singleton if singleton
        return t if t.start_with?("Array[")

        nominal = t[/\A([\w:]+)\[/, 1]
        return nominal if nominal
        return t if t.match?(/\A[\w:]+\z/)

        nil
      end

      def activesupport?(receiver, method)
        AS_BY_CLASS[receiver]&.include?(method) || false
      end

      def undefined_method_groups(pool)
        pairs = pool.filter_map do |d|
          parsed = parse_undefined_method(d)
          parsed ? [[parsed[:method], parsed[:receiver]], d] : nil
        end
        pairs.group_by(&:first).transform_values { |group| group.map(&:last) }
      end

      def describe_groups(groups)
        groups.keys.first(3).map { |method, recv| "`#{method}` on #{recv}" }.join(", ")
      end

      def top_methods(diagnostics, limit: 5)
        diagnostics.filter_map { |d| parse_undefined_method(d)&.fetch(:method) }
                   .tally.sort_by { |method, count| [-count, method] }
                         .first(limit).map { |method, count| "#{method}×#{count}" }.join(" ")
      end

      def rule_of(diag)
        diag.qualified_rule
      end
    end
  end
end
