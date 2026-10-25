# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # The positional argument lists a call with a precise union argument stands for (#2379): one per combination
      # of the union arguments' members, since the runtime selects an overload per value. `RbsDispatch` selects an
      # overload for each list and joins their returns.
      module ArgumentDistribution
        # The most lists {.lists} spells out; past it the call selects once for the arguments as given.
        LIMIT = 8
        private_constant :LIMIT

        module_function

        # The lists, or nil when no argument is a union or the combinations pass {LIMIT}.
        def lists(arg_types)
          return nil unless arg_types.any?(Type::Union)

          count = arg_types.reduce(1) { |product, arg| arg.is_a?(Type::Union) ? product * arg.members.size : product }
          return nil if count > LIMIT

          arg_types.reduce([[]]) do |partials, arg|
            members = arg.is_a?(Type::Union) ? arg.members : [arg]
            partials.flat_map { |partial| members.map { |member| partial + [member] } }
          end
        end
      end
    end
  end
end
