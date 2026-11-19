# frozen_string_literal: true

require_relative "../../type"
require_relative "../../builtins/static_return_refinements"
require_relative "call_context"
require_relative "shape_dispatch"

module Rigor
  module Inference
    module MethodDispatcher
      # The static-refinement tier: the stdlib methods whose upstream RBS is broader than the documented behaviour
      # (`Kernel#__dir__` declared `() -> String?`, a zero-start slice declared nilable) answer the tightened type
      # from `Rigor::Builtins::StaticReturnRefinements::OVERRIDES`, with the vendored `ruby/rbs` left as it is. Its
      # place in the order is `MethodDispatcher`'s `BUNDLED_OVERRIDE_TIERS`.
      module StaticRefinement
        module_function

        # Consults the Rigor-bundled static refinement table for a (owner-class, method-name,
        # kind) entry. Kernel methods are mixed into every non-BasicObject class, so an
        # implicit-self `__dir__` call (receiver_type = Nominal[ClassName]) is matched by looking
        # up Kernel as the owner. Explicit `Kernel.__dir__` (receiver_type = Singleton[Kernel]) and
        # instance-side calls (receiver_type = Nominal[Klass]) share the `:both` row.
        #
        # The receiver-side ancestor check is intentionally cheap: any non-BasicObject Nominal /
        # Singleton matches every Kernel-owned override. BasicObject explicitly excludes Kernel and
        # is therefore rejected. The narrow risk of a user-defined `def __dir__` shadowing Kernel's
        # method would also alter the runtime answer; users with that configuration opt out via a
        # `signature_paths` overlay declaring their own return type.
        #
        # A union receiver is answered member by member, and only when every member is: each member
        # answers as it would alone (`(Array[String] | String)[0..]` drops the nil of both), and one
        # member no entry refines leaves the whole call to RBS.
        def try_dispatch(context)
          receiver_type = context.receiver
          method_name = context.method_name
          arg_types = context.args
          candidates = Rigor::Builtins::StaticReturnRefinements.owners_for(method_name)
          return nil if candidates.empty?
          if receiver_type.is_a?(Type::Union)
            return try_static_refinement_members(receiver_type, method_name, arg_types, context, candidates)
          end

          owner = static_refinement_owner_for(receiver_type, candidates)
          return nil unless owner

          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          Rigor::Builtins::StaticReturnRefinements.lookup(
            owner_class_name: owner,
            method_name: method_name,
            kind: kind,
            arg_types: arg_types,
            context: context
          )
        end

        def try_static_refinement_members(receiver_type, method_name, arg_types, context, candidates)
          members = receiver_type.members
          return nil unless members.all? { |member| static_refinement_owner_for(member, candidates) }

          results = members.map do |member|
            static_member_answer(member, method_name, arg_types, context)
          end
          return nil if results.any?(&:nil?)

          Type::Combinator.union(*results)
        end

        # A `Tuple` member the table answers is offered to {ShapeDispatch} first, as it is when it is the lone receiver
        # (the precise tiers run ahead of this one) and as `RbsDispatch`'s union path offers it (#3320): `[][0...-1]` is
        # the exact `[]` there, not the `Array[untyped]` projection.
        def static_member_answer(member, method_name, arg_types, context)
          answer = try_dispatch(context.with(receiver: member))
          return answer unless answer && member.is_a?(Type::Tuple)

          ShapeDispatch.try_dispatch(
            CallContext.build(
              receiver: member, method_name: method_name, args: arg_types, block_type: context.block_type
            )
          ) || answer
        end

        # Picks the most specific override owner the receiver honours. For Kernel-owned overrides
        # the receiver simply needs to be a real-class Nominal / Singleton (i.e. not BasicObject
        # and not a Dynamic / Constant / shape carrier — those carriers go through their own
        # narrower tiers).
        def static_refinement_owner_for(receiver_type, candidates)
          receiver_class = static_refinement_class_for(receiver_type)
          return nil unless receiver_class

          return "Kernel" if candidates.include?("Kernel") && receiver_class != "BasicObject"

          candidates.find { |owner| owner == receiver_class }
        end

        def static_refinement_class_for(receiver_type)
          case receiver_type
          when Type::Singleton, Type::Nominal
            receiver_type.class_name
          when Type::Tuple
            "Array"
          end
        end
      end
    end
  end
end
