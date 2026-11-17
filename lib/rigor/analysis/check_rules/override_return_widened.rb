# frozen_string_literal: true

require_relative "../../type"
require_relative "../diagnostic"
require_relative "override_support"
require_relative "rule_ids"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `def.override-return-widened` (ADR-35 slice 2): an override whose declared return is
      # wider than the one it inherits.
      #
      # The one entry point is {.diagnostic}, called by `CheckRules.main_pass_node_diagnostics`. It reads
      # {OverrideSupport} and calls nothing else in `CheckRules`.
      module OverrideReturnWidened
        module_function

        # ADR-35 slice 2 — `def.override-return-widened`. The Liskov signature rule for returns
        # (covariance): an override may *narrow* the return it inherits (return a more specific type) but
        # MUST NOT *widen* it. A caller holding the supertype uses the result as the parent's return type;
        # a wider override return breaks that use.
        #
        # WD1 gate (proper, type-direction): both the override and the shadowed ancestor method must carry
        # an explicitly-authored RBS signature. The override side is gated by `defined_on?` (the RBS
        # method is declared on the overriding class itself, not merely inherited); the parent side is the
        # nearest project-discovered ancestor whose RBS declares the method. Inference-only either side →
        # silent.
        #
        # Fires only on a proven (`:no`) widening; generic / `untyped` / `self` parent returns degrade to
        # `Dynamic[Top]` and accept everything, so they stay silent (FP-safe). `self`/`instance` are
        # translated with `self_type: nil` on both sides, so a parent `-> self` and an override `-> self`
        # never fire.
        def diagnostic(path, def_node, scope_index)
          resolved = OverrideSupport.resolve_authored_override(def_node, scope_index)
          return nil if resolved.nil?

          scope, override_method, parent_class, parent_method = resolved
          parent_type_vars = OverrideSupport.ancestor_instantiation_type_vars(scope, parent_class)
          override_return = OverrideSupport.declared_return_union(override_method, scope.environment)
          parent_return = OverrideSupport.declared_return_union(parent_method, scope.environment,
                                                                type_vars: parent_type_vars)
          return nil if override_return.nil? || parent_return.nil?
          return nil if OverrideSupport.dynamic_top?(parent_return) # untyped / unbound-generic parent contract
          return nil if void_over_nil?(override_method, parent_return)

          return nil unless parent_return.accepts(override_return).no?

          build_override_return_widened_diagnostic(
            path, def_node, parent_class, parent_return, override_return
          )
        end

        # A `-> void` override of a parent return of exactly `nil` (or `NilClass`) is exempt (#3046): both
        # say "no useful value", and callers cannot use a void return. Keyed on the declared `void` of every
        # arm (the translator reads `void` as top, so a `-> top` override still fires); any non-nil parent
        # return still fires.
        def void_over_nil?(override_method, parent_return)
          return false unless nil_type?(parent_return)

          override_method.method_types.all? { |mt| mt.type.return_type.is_a?(::RBS::Types::Bases::Void) }
        end

        # `nil`, or the nominal `NilClass`, whose only value it is.
        def nil_type?(type)
          return type.value.nil? if type.is_a?(Type::Constant)

          type.is_a?(Type::Nominal) && type.class_name == "NilClass" && type.type_args.empty?
        end

        def build_override_return_widened_diagnostic(path, def_node, parent_class, parent_return, override_return)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_RETURN_WIDENED,
            path: path,
            message: "return type of `#{def_node.name}' widened from #{parent_return.describe(:short)} " \
                     "to #{override_return.describe(:short)} (overrides #{parent_class}##{def_node.name}); " \
                     "breaks substitutability",
            severity: :warning,
            method_name: def_node.name.to_s
          )
        end

        private_class_method :void_over_nil?, :nil_type?, :build_override_return_widened_diagnostic
      end
    end
  end
end
