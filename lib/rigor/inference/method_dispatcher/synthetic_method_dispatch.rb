# frozen_string_literal: true

require_relative "../../type"
require_relative "call_context"
require_relative "rbs_dispatch"

module Rigor
  module Inference
    module MethodDispatcher
      # The synthetic-method tier (ADR-16 Tier B / Tier C): a method a plugin's macro table synthesised for the
      # receiver's class answers from the `SyntheticMethodIndex` the environment carries. Its place in the order
      # is `MethodDispatcher`'s `SYNTHETIC_TIERS`, below `RbsDispatch` and above the project-patched tier.
      #
      # Named for the dispatch and not `SyntheticMethod`: that is {Rigor::Inference::SyntheticMethod}, the record the
      # index holds, and a module of the same name here would shadow it for every tier.
      #
      # Two entries beside {#try_dispatch}: {#synthetic_method_member?}, which `MethodDispatcher.plugin_member_answers?`
      # asks, and {#synthetic_method_class_name}, which {ProjectPatched} keys its registry lookup on.
      module SyntheticMethodDispatch
        module_function

        # ADR-16 synthetic-method tier. Slice 2b shipped the floor — a match short-circuits at the
        # right precedence (above dep-source / discovered / user-class-fallback; below RBS) and
        # returns `Dynamic[T]`. Slice 6 (precision promotion):
        # - Tier B path (slice 6a, `provenance[:origin_module]` recorded by the slice-3b scanner):
        #   redispatch on `Nominal[origin_module]` via `RbsDispatch` so the module's authored RBS
        #   return type wins. Devise's `valid_password?` returns `bool`, not `Dynamic[T]`.
        # - Tier C path (slice 6b, plain `return_type:` string from the manifest's emit table):
        #   look up `environment.nominal_for_name(return_type)` so `attribute :avatar,
        #   Types::String` emits a synthetic reader returning
        #   `Nominal[ActiveStorage::Attached::One]` (when the class is in RBS). Unparameterised
        #   class names only — parameterised forms (`Array[String]`, `Hash[K, V]`) and
        #   plugin-supplied utility-type names (`Pick<T, K>`) require routing through the full
        #   ADR-13 `Plugin::TypeNodeResolver` chain, which slice 6 does not yet wire in (the
        #   resolver chain is consulted only for `%a{rigor:v1:…}` payloads as of ADR-13 slice 3).
        def try_dispatch(context)
          receiver_type = context.receiver
          method_name = context.method_name
          arg_types = context.args
          block_type = context.block_type
          environment = context.environment
          index = environment&.synthetic_method_index
          return nil if index.nil? || index.empty?

          class_name = synthetic_method_class_name(receiver_type)
          return nil if class_name.nil?

          matches = case receiver_type
                    when Type::Singleton then index.lookup_singleton(class_name, method_name)
                    else index.lookup_instance(class_name, method_name)
                    end
          return nil if matches.empty?

          promoted = promote_synthetic_match(matches, method_name, arg_types, block_type, environment)
          promoted || Type::Combinator.untyped
        end

        # The synthetic-method half of {MethodDispatcher.plugin_member_answers?} — the same `(class_name,
        # method_name, kind)` probe {#try_dispatch} makes, without the return-type promotion the veto has no use for.
        def synthetic_method_member?(receiver_type, method_name, environment)
          index = environment&.synthetic_method_index
          return false if index.nil? || index.empty?

          class_name = synthetic_method_class_name(receiver_type)
          return false if class_name.nil?

          matches = if receiver_type.is_a?(Type::Singleton)
                      index.lookup_singleton(class_name, method_name)
                    else
                      index.lookup_instance(class_name, method_name)
                    end
          !matches.empty?
        rescue StandardError
          false
        end

        # First non-nil promotion wins. Tier B (origin_module) and Tier C (return_type nominal
        # lookup) are tried in the same registration-order pass per WD11 first-wins — the slice-3b
        # scanner sets `origin_module` for Tier B entries and leaves it absent for Tier C, so the
        # two paths self-route per match.
        def promote_synthetic_match(matches, method_name, arg_types, block_type, environment)
          return nil if environment.nil?

          matches.each do |synthetic|
            promoted =
              promote_via_origin_module(synthetic, method_name, arg_types, block_type, environment) ||
              promote_via_return_type(synthetic, environment)
            return promoted if promoted
          end
          nil
        end

        # Slice 6a-TierB. For Tier B emissions (origin_module recorded in provenance), redispatch
        # the call on the included module's `Nominal[...]` type via `RbsDispatch`. Returns nil when
        # the SyntheticMethod is not a Tier B entry or when the origin_module is not in the RBS
        # env.
        def promote_via_origin_module(synthetic, method_name, arg_types, block_type, environment)
          module_name = synthetic.provenance[:origin_module]
          return nil unless module_name

          module_type = Type::Combinator.nominal_of(module_name)
          RbsDispatch.try_dispatch(
            CallContext.build(
              receiver: module_type, method_name: method_name, args: arg_types,
              environment: environment, block_type: block_type
            )
          )
        end

        # Slice 6b-TierC. For Tier C emissions, look up the manifest-declared `return_type:` string
        # via `environment.nominal_for_name`. Skips the placeholder `"untyped"` (Tier B's
        # record-but-do-not-resolve marker from the slice-3b scanner) and the `"void"` keyword
        # (RBS-style absent return). Falls back to nil when the class is not in the env — caller
        # then returns Dynamic[T].
        TIER_C_PLACEHOLDER_RETURNS = %w[untyped void].freeze
        private_constant :TIER_C_PLACEHOLDER_RETURNS

        def promote_via_return_type(synthetic, environment)
          return_type = synthetic.return_type
          return nil if return_type.nil? || TIER_C_PLACEHOLDER_RETURNS.include?(return_type)

          environment.nominal_for_name(return_type)
        end

        def synthetic_method_class_name(receiver_type)
          case receiver_type
          when Type::Nominal, Type::Singleton then receiver_type.class_name
          end
        end
      end
    end
  end
end
