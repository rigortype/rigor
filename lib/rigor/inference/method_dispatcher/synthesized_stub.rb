# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # The synthesized-stub tier (ADR-5 robustness): a call on a type Rigor invented so that a project signature
      # would build answers `Dynamic[Top]` instead of falling through to `call.undefined-method`. Its place in the
      # order is `MethodDispatcher`'s `STUB_TIERS`.
      module SynthesizedStub
        module_function

        # ADR-5 robustness — returns `Dynamic[Top]` when the receiver is an instance or singleton
        # of a type Rigor synthesized (a missing-namespace module or a referenced-type stub). The
        # stub has no methods, so the call would otherwise reach the user-class fallback and
        # surface `call.undefined-method`; the honest answer for a type Rigor invented is "unknown
        # shape", i.e. `Dynamic[Top]`. Returns nil (declines) for any real type.
        def try_dispatch(context)
          receiver_type = context.receiver
          environment = context.environment
          return nil if environment.nil?

          loader = environment.rbs_loader
          return nil if loader.nil? || !loader.respond_to?(:synthesized_type_names)

          names = loader.synthesized_type_names
          return nil if names.empty?

          class_name =
            case receiver_type
            when Type::Nominal, Type::Singleton then receiver_type.class_name.to_s.sub(/\A::/, "")
            end
          return nil unless class_name && names.include?(class_name)

          Type::Combinator.untyped
        end
      end
    end
  end
end
