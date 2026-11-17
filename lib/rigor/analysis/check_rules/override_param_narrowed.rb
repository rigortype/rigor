# frozen_string_literal: true

require_relative "../../inference/rbs_type_translator"
require_relative "../diagnostic"
require_relative "override_support"
require_relative "rule_ids"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `def.override-param-narrowed` (ADR-35 slice 3): an override whose positional parameter
      # is narrower than the one it inherits.
      #
      # The one entry point is {.diagnostic}, called by `CheckRules.main_pass_node_diagnostics`. It reads
      # {OverrideSupport} and calls nothing else in `CheckRules`.
      module OverrideParamNarrowed
        module_function

        # ADR-35 slice 3 — `def.override-param-narrowed`. The Liskov signature rule for parameters
        # (contravariance): an override may *widen* a parameter (accept a supertype — accepting more is
        # safe) but MUST NOT *narrow* it. A caller holding the supertype passes a parent-typed argument; a
        # narrowed override parameter cannot accept it.
        #
        # Direction (ADR-35 WD3, corrected): fire on `override_param.accepts(parent_param) == :no` — the
        # override's (narrowed) slot cannot accept the wider parent argument type. WD4: type comparison at
        # matching POSITIONAL parameter indices only; arity / keyword-requiredness divergence is out of
        # scope for v1. Same WD1 both-sides-authored gate as slice 2; `untyped` / unbound-generic /
        # interface parent params degrade to `Dynamic[Top]` and are skipped (FP-safe). To avoid
        # overload-arm ambiguity, both sides must have exactly one method type.
        def diagnostic(path, def_node, scope_index)
          resolved = OverrideSupport.resolve_authored_override(def_node, scope_index)
          return nil if resolved.nil?

          scope, override_method, parent_class, parent_method = resolved
          parent_type_vars = OverrideSupport.ancestor_instantiation_type_vars(scope, parent_class)
          override_params = positional_param_types(override_method, environment: scope.environment)
          parent_params = positional_param_types(parent_method, type_vars: parent_type_vars,
                                                                environment: scope.environment)
          return nil if override_params.nil? || parent_params.nil?

          index = first_narrowed_param_index(override_params, parent_params)
          return nil if index.nil?

          build_override_param_narrowed_diagnostic(
            path, def_node, parent_class, index, parent_params[index], override_params[index]
          )
        end

        # Translated positional (required + optional) parameter types of a method's single method type, or
        # nil when the method is overloaded (multiple method types — arm mapping is ambiguous) or the
        # parameter list is not introspectable. Per-position translation failures yield `nil` at that slot
        # (skipped by the comparison). `self`/`instance` translate with `self_type: nil` (→
        # `Dynamic[Top]`), matching the return-side handling.
        # `type_vars:` — ADR-35 WD9 tier 1, parent side only. Substitutes the generic-instantiation
        # map (parent class's type params → the subclass's instantiation) so a parent `(T)` parameter
        # is compared at its instantiated type. Empty (the default, and the override side) keeps the
        # pre-WD9 degrade-to-`Dynamic[Top]` behaviour.
        def positional_param_types(method_def, type_vars: {}, environment: nil)
          method_types = method_def.method_types
          return nil unless method_types.size == 1

          func = method_types.first.type
          return nil unless func.respond_to?(:required_positionals)

          (func.required_positionals + func.optional_positionals).map do |param|
            Inference::RbsTypeTranslator.translate(
              param.type, self_type: nil, instance_type: nil, type_vars: type_vars,
                          alias_expander: environment&.rbs_loader
            )
          rescue StandardError
            nil
          end
        end

        # Index of the first positional parameter the override narrows relative to the parent, or nil. A
        # position is a violation when the override's slot cannot accept the parent's argument type
        # (`override_param.accepts(parent_param) == :no`). Positions where either side is
        # missing/untranslatable, or the parent type degraded to `Dynamic[Top]` (untyped / unbound generic
        # / interface), are skipped.
        def first_narrowed_param_index(override_params, parent_params)
          count = [override_params.size, parent_params.size].min
          count.times do |i|
            override_param = override_params[i]
            parent_param = parent_params[i]
            next if override_param.nil? || parent_param.nil?
            next if OverrideSupport.dynamic_top?(parent_param) || OverrideSupport.dynamic_top?(override_param)

            return i if override_param.accepts(parent_param).no?
          end
          nil
        end

        def build_override_param_narrowed_diagnostic(path, def_node, parent_class, index, parent_param, override_param)
          Diagnostic.from_name_loc(
            def_node,
            rule: RULE_OVERRIDE_PARAM_NARROWED,
            path: path,
            message: "parameter #{index + 1} of `#{def_node.name}' narrowed from " \
                     "#{parent_param.describe(:short)} to #{override_param.describe(:short)} " \
                     "(overrides #{parent_class}##{def_node.name}); breaks substitutability",
            severity: :warning,
            method_name: def_node.name.to_s
          )
        end

        private_class_method :positional_param_types, :first_narrowed_param_index,
                             :build_override_param_narrowed_diagnostic
      end
    end
  end
end
