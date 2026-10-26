# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # The positional argument lists a call with a precise union argument stands for (#2379): one per combination
      # of the union arguments' members, since the runtime selects an overload per value. `RbsDispatch` selects an
      # overload for each list and joins their returns.
      module ArgumentDistribution
        # The most lists {.lists} spells out when more than one argument is a union. One union argument is linear in
        # its members and is not capped.
        LIMIT = 8
        private_constant :LIMIT

        # {.lists}' answer past {LIMIT}: the call's overloads cannot be read per value, and it answers `Dynamic[top]`.
        OVER_LIMIT = :over_limit

        module_function

        # The lists, nil when no argument is a union, or {OVER_LIMIT}.
        def lists(arg_types)
          unions = arg_types.count { |arg| arg.is_a?(Type::Union) }
          return nil if unions.zero?

          if unions > 1
            count = arg_types.reduce(1) { |product, arg| arg.is_a?(Type::Union) ? product * arg.members.size : product }
            return OVER_LIMIT if count > LIMIT
          end

          arg_types.reduce([[]]) do |partials, arg|
            members = arg.is_a?(Type::Union) ? arg.members : [arg]
            partials.flat_map { |partial| members.map { |member| partial + [member] } }
          end
        end
      end
    end
  end
end
