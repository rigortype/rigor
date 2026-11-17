# frozen_string_literal: true

require "prism"
require_relative "../../source/constant_path"
require_relative "../diagnostic"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — the two `Rigor::Testing` assertion rules: `dump.type` ({.dump_diagnostic},
      # `Rigor::Testing.dump_type(expr)`) and `assert.type-mismatch` ({.assert_diagnostic},
      # `Rigor::Testing.assert_type(expected, expr)`).
      #
      # Both are entry points, called by `CheckRules.call_node_diagnostics`; the module calls nothing else in
      # `CheckRules`.
      module RigorTesting
        module_function

        # Slice 7 phase 19 — PHPStan-style `dump_type(value)`. When the engine recognises a call to
        # `dump_type` (with any of the supported receiver shapes — implicit self after `include
        # Rigor::Testing`, `Rigor::Testing.dump_type`, or `Rigor.dump_type`), it emits an `:info` diagnostic
        # showing the inferred type of the argument expression. The diagnostic does NOT count toward
        # `Result#error_count` so a fixture peppered with `dump_type` calls still passes `rigor check`.
        def dump_diagnostic(path, call_node, scope_index)
          return nil unless rigor_testing_call?(call_node, :dump_type)
          return nil if call_node.arguments.nil? || call_node.arguments.arguments.empty?

          arg = call_node.arguments.arguments.first
          scope = scope_index[arg] || scope_index[call_node]
          return nil if scope.nil?
          return nil if inside_rigor_testing?(scope)

          type = scope.type_of(arg)
          Diagnostic.from_message_loc(
            call_node,
            path: path,
            message: "dump_type: #{type.describe(:short)}",
            severity: :info,
            rule: RULE_DUMP_TYPE
          )
        end

        # Slice 7 phase 19 — PHPStan-style `assert_type("...", value)`. The first argument MUST be a
        # string literal containing the expected `Type#describe(:short)` rendering. When the inferred
        # type's short description does not equal the expected literal, an `:error`-severity diagnostic is
        # emitted; matching calls produce no output. This lets a fixture document its expected types
        # inline: subsequent `rigor check` runs flag any drift.
        def assert_diagnostic(path, call_node, scope_index)
          return nil unless rigor_testing_call?(call_node, :assert_type)
          return nil if call_node.arguments.nil? || call_node.arguments.arguments.size < 2

          expected_node = call_node.arguments.arguments.first
          return nil unless expected_node.is_a?(Prism::StringNode)

          value_node = call_node.arguments.arguments[1]
          scope = scope_index[value_node] || scope_index[call_node]
          return nil if scope.nil?
          return nil if inside_rigor_testing?(scope)

          actual = scope.type_of(value_node).describe(:short)
          expected = expected_node.unescaped.to_s
          return nil if actual == expected

          build_assert_type_diagnostic(path, call_node, expected, actual)
        end

        # Recognises any of:
        #   `dump_type(x)`        (implicit self after `include Rigor::Testing`)
        #   `Testing.dump_type(x)`
        #   `Rigor.dump_type(x)`
        #   `Rigor::Testing.dump_type(x)`
        # The receiver check is purely structural — we do not consult RBS — because the helpers are no-op
        # stubs the user MAY shadow with their own definition; a name clash is the deliberate trade-off for
        # ergonomic invocation.
        RIGOR_TESTING_RECEIVERS = ["Rigor", "Rigor::Testing", "Testing"].freeze
        private_constant :RIGOR_TESTING_RECEIVERS

        # The dump/assert helpers' own implementation methods call back into `Testing.dump_type` /
        # `assert_type` to share the no-op runtime stub. We do NOT want those internal calls to surface
        # diagnostics — they are reflexive plumbing, not user assertions. This filter skips diagnostics
        # when the call site's `self_type` is the `Rigor` or `Rigor::Testing` module itself.
        SELF_REFERENTIAL_SCOPES = ["Rigor", "Rigor::Testing"].freeze
        private_constant :SELF_REFERENTIAL_SCOPES

        def inside_rigor_testing?(scope)
          self_type = scope.self_type
          return false if self_type.nil?
          return false unless self_type.respond_to?(:class_name)

          SELF_REFERENTIAL_SCOPES.include?(self_type.class_name)
        end

        def rigor_testing_call?(call_node, method_name)
          return false unless call_node.name == method_name

          receiver = call_node.receiver
          return true if receiver.nil?

          name = Source::ConstantPath.qualified_name_or_nil(receiver)
          return false if name.nil?

          RIGOR_TESTING_RECEIVERS.include?(name)
        end

        def build_assert_type_diagnostic(path, call_node, expected, actual)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_ASSERT_TYPE,
            path: path,
            message: "assert_type mismatch: expected #{expected.inspect}, got #{actual.inspect}",
            severity: :error
          )
        end

        private_class_method :inside_rigor_testing?, :rigor_testing_call?, :build_assert_type_diagnostic
      end
    end
  end
end
