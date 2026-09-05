# frozen_string_literal: true

require_relative "hint"

module Rigor
  module Triage
    # ADR-23 § "Heuristic catalogue" — the six v1 recognisers.
    #
    # {.recognise} runs them in order over the diagnostic stream. Each recogniser sees only the diagnostics not yet
    # claimed by an earlier one, so a `5.minutes` diagnostic counted by H1 (ActiveSupport) is not re-counted by H2
    # (monkey-patch).
    #
    # WD3 / slice 4: recognisers key on the structured `qualified_rule` first; where they additionally need the receiver
    # type or method name they read the structured `Diagnostic#receiver_type` / `#method_name` fields, falling back to
    # parsing the diagnostic message only when those are absent. A parse failure degrades to "skip this diagnostic" —
    # never a crash.
    module Catalogue # rubocop:disable Metrics/ModuleLength
      module_function

      UNDEFINED_METHOD_RULE = "call.undefined-method"
      UNRESOLVED_TOPLEVEL_RULE = "call.unresolved-toplevel"

      # `undefined method `foo' for <receiver>`
      UNDEF_METHOD = /\Aundefined method [`'"]([^`'"]+)['"`] for (.+)\z/

      # ActiveSupport `core_ext` selectors, grouped by the core class they extend. Survey-grounded (the dominant
      # clusters from the five-project survey + the Mastodon measurement).
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

      # ActiveRecord query-builder methods. When flagged on an `Array[...]` receiver they signal a relation
      # misinference.
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

      # WD6 (ADR-23): H5 (systemic cluster) and H6 (genuine bugs) are the only count-based, severity-agnostic
      # recognisers, so they alone risk reading plugin recognition trace (`:info` `*.model-call` / `*.helper`, …) as a
      # "systemic cluster" or a "genuine bug" — frightening working code. They are guarded against `:info` unless
      # `include_info` restores the pre-v0.2.3 behaviour. Every other recogniser keys on an error/warning rule
      # (H1/H2/H2K/H4/H7) or intentionally reads an info notice (H3 — the `gem-without-rbs` `rbs.coverage.missing-gem`),
      # so the full pool is correct for them.
      INFO_GUARDED = %i[h5_systemic_cluster h6_genuine_bugs].freeze
      private_constant :INFO_GUARDED

      # @param include_info [Boolean] let H5/H6 see `:info` diagnostics
      def recognise(diagnostics, include_info: false)
        claimed = {}.compare_by_identity
        recognisers.filter_map do |recogniser|
          pool = diagnostics.reject { |d| claimed[d] }
          pool = pool.reject { |d| d.severity == :info } if INFO_GUARDED.include?(recogniser) && !include_info
          hint, matched = send(recogniser, pool)
          next unless hint

          matched.each { |d| claimed[d] = true }
          hint
        end
      end

      # H4 (ActiveRecord query methods) runs before H2 (generic monkey-patch): a known AR method on `Array[...]`
      # deserves the precise relation-misinference hint, not the generic "project core-ext" guess H2 would otherwise
      # claim it for.
      #
      # H2K (known project patch) runs before the generic H2: the engine has already proved the defining site via the
      # `project_definition_site` field (ADR-17), so those diagnostics get the high-confidence file-naming hint rather
      # than the spread-based guess. H7 (unresolved toplevel) runs before the systemic / genuine-bug catch-alls so
      # toplevel resolution misses route to `pre_eval:` (ADR-34) instead of reading as scattered bugs.
      def recognisers
        %i[h1_activesupport h4_ar_relation h3_gem_without_rbs
           h2k_known_project_patch h2_monkey_patch h7_unresolved_toplevel
           h5_systemic_cluster h6_genuine_bugs]
      end

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
          action: "Add rigor-activesupport-core-ext to `plugins:` in .rigor.yml " \
                  "(it is an RBS-bundle plugin — ADR-25)."
        ), matched]
      end

      # ADR-17 / WD3 slice 4: the `call.undefined-method` rule sets `project_definition_site` when the project itself
      # defines the called method on the receiver class somewhere in the file set (a reopened core/stdlib/gem class the
      # dispatcher does not apply cross-file). That is direct evidence — not a spread heuristic — so this recogniser is
      # `:likely` and names the defining files outright. It runs before the generic H2.
      def h2k_known_project_patch(pool)
        matched = pool.select(&:project_definition_site)
        return nil if matched.empty?

        files = matched.map { |d| d.project_definition_site.sub(/:\d+\z/, "") }
                       .uniq.sort
        [Hint.new(
          id: "project-monkey-patch-known", confidence: :likely,
          diagnostic_count: matched.size,
          summary: "#{matched.size} undefined-method site(s) resolve to project " \
                   "definitions in #{files.first(3).join(', ')} — reopened core/" \
                   "stdlib/gem classes Rigor does not apply cross-file",
          action: "List #{files.size == 1 ? 'this file' : 'these files'} in " \
                  "`.rigor.yml`'s `pre_eval:` (ADR-17): #{files.join(', ')}"
        ), matched]
      end

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

      # ADR-34: `call.unresolved-toplevel` fires on a toplevel implicit-self call (no receiver, outside any def / class
      # / module) that resolves against no visible contributor. The canonical opt-out is `pre_eval:` — the file is
      # usually a script relying on methods defined by a monkey-patch or a required helper Rigor did not walk. Grouped,
      # not per-site, so the report names the cluster once.
      def h7_unresolved_toplevel(pool)
        matched = pool.select { |d| rule_of(d) == UNRESOLVED_TOPLEVEL_RULE }
        return nil if matched.empty?

        files = matched.map(&:path).uniq.sort
        [Hint.new(
          id: "unresolved-toplevel", confidence: :possible,
          diagnostic_count: matched.size,
          summary: "#{matched.size} toplevel call(s) resolve to nothing visible " \
                   "across #{files.size} file(s) (#{top_methods(matched, parser: :toplevel)})",
          action: "If a monkey-patch or required helper defines these, list its " \
                  "file in `.rigor.yml`'s `pre_eval:` (ADR-17); otherwise they may " \
                  "be genuine typos or missing requires."
        ), matched]
      end

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

      # WD3 / slice 4: prefer the structured `receiver_type` / `method_name` fields the `call.undefined-method` rule now
      # populates; fall back to parsing the message only when they are absent (older diagnostics, plugin-emitted rules).
      # Either way the receiver token is normalised through `receiver_class`.
      def parse_undefined_method(diag)
        return nil unless rule_of(diag) == UNDEFINED_METHOD_RULE

        method, receiver_token = structured_undefined_method(diag) ||
                                 message_undefined_method(diag)
        return nil unless method

        receiver = receiver_class(receiver_token)
        return nil unless receiver

        { method: method, receiver: receiver }
      end

      def structured_undefined_method(diag)
        return nil unless diag.method_name && diag.receiver_type

        [diag.method_name, diag.receiver_type]
      end

      def message_undefined_method(diag)
        m = UNDEF_METHOD.match(diag.message)
        m && [m[1], m[2]]
      end

      # Normalises a message receiver token to a class name. The fold logic is shared with the selector axis — see
      # {Triage.normalize_receiver}.
      def receiver_class(token)
        Triage.normalize_receiver(token)
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

      # `parser: :undefined_method` (default) reads the method from the parsed `undefined-method` shape; `parser:
      # :toplevel` reads the structured `method_name` field directly (the `unresolved-toplevel` rule carries no receiver
      # to parse).
      def top_methods(diagnostics, limit: 5, parser: :undefined_method)
        names = diagnostics.filter_map do |d|
          parser == :toplevel ? d.method_name : parse_undefined_method(d)&.fetch(:method)
        end
        names.tally.sort_by { |method, count| [-count, method] }
             .first(limit).map { |method, count| "#{method}×#{count}" }.join(" ")
      end

      def rule_of(diag)
        diag.qualified_rule
      end
    end
  end
end
