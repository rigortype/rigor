# frozen_string_literal: true

require "prism"
require "rigor/plugin"
require "rigor/source/literals"

module Rigor
  module Plugin
    # Example plugin: validates `validate(:name, value)` calls
    # against a user-declared regex pattern table. Demonstrates
    # **plugin → analyzer collaboration**: the plugin asks Rigor's
    # type system whether each `value` argument is a provably
    # literal string (via `Type::Combinator.literal_string_compatible?`,
    # introduced in v0.0.9), and if so, runs the configured regex
    # against the literal value at lint time.
    #
    # Compared with the AST-only approach used by the earlier
    # examples, this one **does not reimplement** literal-string
    # tracking. Rigor already folds `"user@" + "example.com"`
    # to a literal-string carrier through its
    # `LiteralStringFolding` tier; the plugin reads that fact
    # back through `Scope#type_of` and uses it. Plugins that
    # need to know "is this a literal string?" should reach for
    # the engine surface rather than re-implementing string
    # propagation.
    #
    # ## Configuration
    #
    # Patterns are declared in `.rigor.yml`:
    #
    #     plugins:
    #       - gem: rigor-pattern
    #         config:
    #           patterns:
    #             email: '\A[^\s@]+@[^\s@]+\z'
    #             uuid:  '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
    #
    # ## Diagnostics
    #
    # | Event                                           | Severity | Rule              |
    # | ---                                             | ---      | ---               |
    # | literal arg matches the named pattern           | `:info`  | `literal-match`   |
    # | literal arg does NOT match the named pattern    | `:error` | `literal-mismatch`|
    # | provably literal-string but exact value unknown | `:info`  | `literal-unknown` |
    # | call site references an unknown pattern name    | `:error` | `unknown-pattern` |
    #
    # Calls whose `value` argument is not provably a literal
    # (e.g. `validate(:email, params[:email])`) stay silent —
    # the plugin defers to runtime for those.
    class Pattern < Rigor::Plugin::Base
      manifest(
        id: "pattern",
        version: "0.1.0",
        description: "Statically validates literal arguments to validate(:name, value) calls.",
        config_schema: {
          "method_name" => :string,
          "patterns" => :hash
        }
      )

      DEFAULT_METHOD_NAME = "validate"

      def init(_services)
        @method_name = config.fetch("method_name", DEFAULT_METHOD_NAME).to_sym
        raw_patterns = config.fetch("patterns", {})
        @patterns = raw_patterns.transform_values { |source| Regexp.new(source) }
      rescue RegexpError => e
        raise "rigor-pattern: invalid regex in config: #{e.message}"
      end

      # ADR-37 — per-call validation over the engine-owned walk.
      # `validate_call?` gates on the configured `method_name` with
      # ≥2 args; the plugin ships no traversal of its own.
      node_rule Prism::CallNode do |node, scope, path|
        next [] if @patterns.empty?
        next [] unless validate_call?(node)

        found = analyse_call(path, scope, node)
        found ? [found] : []
      end

      # ADR-52 slice 4 — return-type contribution via the compiled
      # dispatch DSL. The `methods:` callable resolves after `#init`
      # so `@method_name` is available. Runtime `validate` returns
      # its `value` argument when the regex matches and raises
      # otherwise, so on a successful match we narrow the call
      # site's return type to the value argument's type (typically
      # `Constant<String>` after Rigor's literal-string folding).
      # Mismatches keep the existing `literal-mismatch` diagnostic
      # and stay at the RBS-level untyped return. The engine wraps
      # the bare `Rigor::Type` return in a `FlowContribution`
      # automatically.
      dynamic_return methods: -> { [@method_name] } do |call_node, scope|
        next nil unless validate_call?(call_node)

        pattern_name = literal_symbol_arg(call_node, 0)
        next nil if pattern_name.nil?

        pattern = @patterns[pattern_name.to_s]
        next nil if pattern.nil?

        value_node = call_node.arguments.arguments[1]
        next nil if value_node.nil?

        value_type = scope.type_of(value_node)
        next nil unless services.type.literal_string_compatible?(value_type)

        next nil if literal_mismatch?(value_type, pattern)

        value_type
      end

      private

      def validate_call?(call_node)
        return false unless call_node.is_a?(Prism::CallNode)
        return false unless call_node.name == @method_name
        return false if call_node.arguments.nil?

        call_node.arguments.arguments.size >= 2
      end

      def literal_mismatch?(value_type, pattern)
        return false unless value_type.is_a?(Rigor::Type::Constant)
        return false unless value_type.value.is_a?(String)

        !pattern.match?(value_type.value)
      end

      def analyse_call(path, scope, call)
        pattern_name = literal_symbol_arg(call, 0)
        return nil unless pattern_name # not the shape we care about

        pattern = @patterns[pattern_name.to_s]
        unless pattern
          known = @patterns.keys.sort.map { |k| ":#{k}" }.join(", ")
          return diagnostic(
            call, path: path,
                  severity: :error,
                  rule: "unknown-pattern",
                  message: "no pattern named :#{pattern_name} in plugin config (declared: #{known.empty? ? '(none)' : known})"
          )
        end

        value_node = call.arguments.arguments[1]
        return nil if value_node.nil?

        # Use the per-file entry scope's `type_of` so the plugin
        # rides Rigor's existing literal-string folding rather
        # than reimplementing it. `Type::Combinator.literal_string_compatible?`
        # is the engine-side predicate the v0.0.9 literal-string
        # carrier publishes.
        value_type = scope.type_of(value_node)
        evaluate_value(path, value_node, pattern, pattern_name, value_type)
      end

      def evaluate_value(path, value_node, pattern, pattern_name, value_type)
        return nil unless services.type.literal_string_compatible?(value_type)

        if value_type.is_a?(Rigor::Type::Constant) && value_type.value.is_a?(String)
          value = value_type.value
          if pattern.match?(value)
            diagnostic(
              value_node, path: path,
                          severity: :info,
                          rule: "literal-match",
                          message: "literal #{value.inspect} matches :#{pattern_name}"
            )
          else
            diagnostic(
              value_node, path: path,
                          severity: :error,
                          rule: "literal-mismatch",
                          message: "literal #{value.inspect} does not match :#{pattern_name} (#{pattern.source})"
            )
          end
        else
          # Provably literal-string-compatible but the exact
          # value is not a `Type::Constant` — typically a
          # refinement carrier produced through interpolation
          # of a non-Constant literal-string. Surface as an
          # info note so the user sees the engine collaboration
          # without false-positive errors.
          diagnostic(
            value_node, path: path,
                        severity: :info,
                        rule: "literal-unknown",
                        message: "argument is literal-string-compatible but exact value is not statically known; :#{pattern_name} pattern check skipped"
          )
        end
      end

      def literal_symbol_arg(call, index)
        args = call.arguments&.arguments
        Rigor::Source::Literals.symbol_name(args && args[index])
      end
    end

    Rigor::Plugin.register(Pattern)
  end
end
