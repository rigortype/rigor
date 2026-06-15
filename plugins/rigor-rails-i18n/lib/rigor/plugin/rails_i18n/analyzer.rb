# frozen_string_literal: true

require "did_you_mean"
require "prism"

module Rigor
  module Plugin
    class RailsI18n < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for `t(...)` /
      # `I18n.t(...)` / `I18n.translate(...)` calls with a
      # literal-string first argument. Calls with a non-literal
      # key (variable, expression) are silently passed through —
      # the plugin only validates what it can prove statically.
      #
      # ## What gets emitted per recognised call
      #
      # - `plugin.rails-i18n.translation-call` (info) names the
      #   key and the locales it resolves in.
      # - `plugin.rails-i18n.unknown-key` (error) when the key
      #   is missing from every loaded locale; the message
      #   includes a did-you-mean suggestion drawn from the
      #   index.
      # - `plugin.rails-i18n.missing-locale` (warning) when the
      #   key resolves in some configured locales but is absent
      #   from at least one. Suppressed when the call passes
      #   `default:` (the user has signalled they're aware of
      #   the partial coverage).
      # - `plugin.rails-i18n.wrong-interpolation` (error) when
      #   the call's interpolation hash uses keys that don't
      #   match the value's `%{var}` placeholders, or omits a
      #   required placeholder.
      module Analyzer
        TRANSLATE_METHODS = %i[t translate].freeze

        # Methods that are always I18n receivers (`I18n.t`,
        # `::I18n.t`).
        I18N_RECEIVER_NAMES = %w[I18n ::I18n].freeze

        # Matches controller file paths so lazy keys (`.key`)
        # can be expanded to `<controller_scope>.<action>.<key>`.
        # Captures the path segment between `controllers/` and
        # `_controller.rb` (e.g. `users`, `admin/users`).
        CONTROLLER_PATH_RE = %r{(?:^|/)controllers/(.+)_controller\.rb$}

        # Reserved option keys — these are recognised by I18n
        # itself and not treated as interpolation variables.
        RESERVED_OPTION_KEYS = %i[
          default scope locale count raise throw fallback
          fallback_in_progress separator deep_interpolation
        ].to_set.freeze

        # Key prefixes Rails / `rails-i18n` ship in every
        # locale by default. Projects whose own locale files
        # don't redeclare them still get them at runtime (via
        # the `rails-i18n` gem's bundled locale catalogues).
        # `t('date.order')` is the canonical Mastodon case —
        # used by `Settings::Date::Order` and date-of-birth
        # selects, never authored project-side. Skip
        # `unknown-key` for these; downstream interpolation
        # checks have nothing to validate without a leaf entry
        # so they decline silently too.
        RAILS_SHIPPED_KEY_PREFIXES = %w[
          date.
          time.
          datetime.
          support.array.
          errors.format
          errors.messages.
          number.
          helpers.select.
          helpers.submit.
          helpers.label.
          i18n.transliterate.
          activerecord.errors.messages.
          activerecord.errors.models.
        ].freeze

        # One translation-call observation. Carries no path/location —
        # the caller (the `node_rule` block) positions it via
        # `Plugin::Base#diagnostic`.
        Violation = Struct.new(:rule, :severity, :message, keyword_init: true)

        module_function

        def rails_shipped_key?(literal_key)
          key_str = literal_key.to_s
          RAILS_SHIPPED_KEY_PREFIXES.any? { |prefix| key_str.start_with?(prefix) }
        end

        # @param path [String]
        # @param root [Prism::Node]
        # @param locale_index [LocaleIndex]
        # @param configured_locales [Array<String>]
        # @return [Array<Diagnostic>]
        # The translation violations for a single call node, or `[]`
        # when it is not a recognised `t` / `translate` call with a
        # literal key. ADR-37: the engine owns the walk; `action` (the
        # enclosing method, for lazy `t('.key')` expansion) comes from
        # the node-rule `NodeContext`, and `controller_scope` from the
        # file path.
        #
        # @param call_node [Prism::Node]
        # @param locale_index [LocaleIndex]
        # @param configured_locales [Array<String>]
        # @param controller_scope [String, nil]
        # @param action [String, nil]
        # @return [Array<Violation>]
        def violations_for(call_node:, locale_index:, configured_locales:, controller_scope:, action:)
          return [] unless call_node.is_a?(Prism::CallNode) && translate_call_candidate?(call_node)

          raw_key = literal_key_for(call_node)
          return [] if raw_key.nil?

          literal_key = expand_key(raw_key, controller_scope: controller_scope, action: action)
          return [] if literal_key.nil?

          options = options_hash(call_node)
          entry = locale_index.find(literal_key)
          if entry.nil?
            # CLDR pluralization namespace: `t('accounts.posts', count: n)`
            # resolves through a `.one` / `.other` child — not missing.
            return [] if locale_index.pluralization_namespace?(literal_key)
            # Rails / rails-i18n ship `date.order`, `time.am`, etc. in
            # every locale at runtime even when project files omit them.
            return [] if rails_shipped_key?(literal_key)

            return [unknown_key_violation(literal_key, locale_index)]
          end

          violations = [translation_call_info(literal_key, entry)]
          missing_in_locales = locale_index.missing_locales_for(literal_key, configured_locales: configured_locales)
          if !options[:has_default] && !missing_in_locales.empty?
            violations << missing_locale_violation(literal_key, missing_in_locales)
          end
          violations.concat(interpolation_violations(literal_key, entry, options))
          violations
        end

        # Derives the Rails controller scope from the file path,
        # e.g. `app/controllers/admin/users_controller.rb` → `admin.users`.
        # Returns nil for non-controller paths.
        def controller_scope_from_path(path)
          m = CONTROLLER_PATH_RE.match(path.to_s)
          return nil unless m

          m[1].tr("/", ".")
        end

        # Expands a lazy key (starting with `.`) to its full
        # dotted path using the controller scope and action name.
        # Returns the raw key unchanged for absolute keys.
        # Returns nil for lazy keys outside a controller context
        # or without an enclosing action — these are silently
        # skipped to avoid false positives.
        def expand_key(raw_key, controller_scope:, action:)
          return raw_key unless raw_key.start_with?(".")
          return nil unless controller_scope && action

          "#{controller_scope}.#{action}#{raw_key}"
        end

        def translate_call_candidate?(node)
          return false unless TRANSLATE_METHODS.include?(node.name)
          return true if node.receiver.nil?

          receiver_name = constant_receiver_name(node.receiver)
          I18N_RECEIVER_NAMES.include?(receiver_name)
        end

        # Extracts the literal-string first argument when
        # present. Returns nil for variable / expression keys —
        # only literal keys are statically validated.
        def literal_key_for(call_node)
          args = call_node.arguments&.arguments || []
          return nil if args.empty?

          first = args.first
          return nil unless first.is_a?(Prism::StringNode)

          first.unescaped
        end

        # Pulls the interpolation hash from the call's
        # arguments. The trailing `Hash` argument (or
        # `Prism::KeywordHashNode`) carries both reserved I18n
        # options (`default:`, `scope:`, …) and interpolation
        # variables. Returns:
        #   {
        #     :has_default     => bool,
        #     :all_keys        => Set<Symbol>     (every assoc key in the hash),
        #     :non_reserved    => Set<Symbol>     (keys NOT in RESERVED_OPTION_KEYS),
        #     :hash_node       => Prism::Node (or nil)
        #   }
        #
        # Note: a reserved option key (e.g. `count:`) can
        # also serve as an interpolation value when the
        # locale's leaf string has `%{count}`. The analyzer
        # therefore checks the missing-placeholder set
        # against `all_keys` (so `count:` satisfies a
        # `%{count}` placeholder) and the
        # extra-placeholder set against `non_reserved` (so
        # `default:` / `scope:` are never reported as
        # extra interpolation arguments).
        def options_hash(call_node)
          args = call_node.arguments&.arguments || []
          last = args.last
          empty = { has_default: false, all_keys: Set.new, non_reserved: Set.new, hash_node: nil }
          return empty unless hash_like?(last)

          assoc_keys = collect_assoc_keys(last)
          all_keys = assoc_keys.to_set
          non_reserved = assoc_keys.reject { |k| RESERVED_OPTION_KEYS.include?(k) }.to_set
          {
            has_default: assoc_keys.include?(:default),
            all_keys: all_keys,
            non_reserved: non_reserved,
            hash_node: last
          }
        end

        def hash_like?(node)
          node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
        end

        def collect_assoc_keys(hash_node)
          # Both `Prism::HashNode` and `Prism::KeywordHashNode`
          # expose `#elements`, so a single path handles both.
          hash_node.elements.filter_map do |element|
            next nil unless element.is_a?(Prism::AssocNode)

            key_node = element.key
            case key_node
            when Prism::SymbolNode then key_node.unescaped.to_sym
            when Prism::StringNode then key_node.unescaped.to_sym
            end
          end
        end

        def translation_call_info(literal_key, entry)
          locales_text = entry.locales.sort.join(", ")
          Violation.new(
            severity: :info,
            rule: "translation-call",
            message: "`t('#{literal_key}')` resolves in #{locales_text}"
          )
        end

        def unknown_key_violation(literal_key, locale_index)
          suggestions = DidYouMean::SpellChecker.new(dictionary: locale_index.keys).correct(literal_key)
          suggestion_part = suggestions.empty? ? "" : " (did you mean `#{suggestions.first}`?)"
          Violation.new(
            severity: :error,
            rule: "unknown-key",
            message: "missing translation key `#{literal_key}` in any locale#{suggestion_part}"
          )
        end

        def missing_locale_violation(literal_key, missing_locales)
          locales_text = missing_locales.to_a.sort.join(", ")
          Violation.new(
            severity: :warning,
            rule: "missing-locale",
            message: "`t('#{literal_key}')` is missing from locale(s) #{locales_text}"
          )
        end

        def interpolation_violations(literal_key, entry, options)
          required = entry.all_placeholders
          all_provided = options[:all_keys].to_set(&:to_s)
          non_reserved_provided = options[:non_reserved].to_set(&:to_s)
          missing = required - all_provided
          extra = non_reserved_provided - required

          [].tap do |violations|
            unless missing.empty?
              violations << Violation.new(
                severity: :error,
                rule: "wrong-interpolation",
                message: "`t('#{literal_key}')` expects interpolation #{format_keys(missing)}, " \
                         "got #{format_keys(non_reserved_provided)}"
              )
            end

            unless extra.empty?
              violations << Violation.new(
                severity: :warning,
                rule: "extra-interpolation",
                message: "`t('#{literal_key}')` does not use interpolation #{format_keys(extra)} " \
                         "(known placeholders: #{format_keys(required)})"
              )
            end
          end
        end

        def format_keys(set)
          return "(none)" if set.empty?

          set.to_a.sort.map { |k| "`#{k}`" }.join(", ")
        end

        def constant_receiver_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_name(node)
          end
        end

        def constant_path_name(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          case current
          when nil then "::#{parts.join('::')}"
          when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
          end
        end
      end
    end
  end
end
