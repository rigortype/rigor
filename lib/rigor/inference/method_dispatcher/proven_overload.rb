# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # The value tests of `OverloadSelector`'s pass 0 (#1344), which reads the overloads in declared order and
      # takes the first one plain-value arguments do not rule out, when that one names each argument's own class.
      #
      # Acceptance reads class relations from the analyzer's own process, which cannot load a project class or
      # module, so it can rule an arm out wrongly: `(Printable)` against `1`, where project RBS includes
      # `Printable` into `Integer`, answers `no`, and taking the `(Integer)` arm declared after it typed the call
      # as that arm's return and fired `call.undefined-method` on correct code. {.contested?} therefore trusts
      # an earlier arm to be out only when it can prove it: every positional parameter, rest included, is a plain
      # class (through `?` and `|`), and both orderings — `Environment#class_ordering`, which asks the host class
      # registry first, and the RBS loader's own — call it disjoint from every argument's class. A type alias,
      # interface or variable proves nothing, and the host registry alone calls `Integer` and `Enumerable`
      # disjoint where project RBS includes one into the other.
      module ProvenOverload
        module_function

        # Every argument is a plain value: a `Constant`, or a `Nominal` with no type arguments.
        def applies?(arg_types)
          !arg_types.empty? && arg_types.all? do |arg|
            arg.is_a?(Type::Constant) || (arg.is_a?(Type::Nominal) && arg.type_args.empty?)
          end
        end

        def names_arg_class?(param, arg) = param.is_a?(Type::Nominal) && param.class_name == class_name_of(arg)

        def class_name_of(arg) = arg.is_a?(Type::Constant) ? arg.value.class.name : arg.class_name

        # Whether an overload declared before `declared[index]` may take the arguments after all.
        def contested?(declared, index, arg_types, environment)
          loader = environment&.rbs_loader
          return true if loader.nil?

          arg_names = arg_types.map { |arg| class_name_of(arg) }
          (0...index).any? { |position| !proven_out?(declared[position], arg_names, environment, loader) }
        end

        def proven_out?(method_type, arg_names, environment, loader)
          fun = method_type.type
          return false unless fun.respond_to?(:required_positionals)

          params = fun.required_positionals + fun.optional_positionals + fun.trailing_positionals
          params += [fun.rest_positionals] if fun.rest_positionals
          params.all? { |param| disjoint_param?(param.type, arg_names, environment, loader) }
        end

        def disjoint_param?(rbs_type, arg_names, environment, loader)
          case rbs_type
          when RBS::Types::ClassInstance
            name = rbs_type.name.to_s.delete_prefix("::")
            arg_names.all? do |arg|
              environment.class_ordering(arg, name) == :disjoint && loader.class_ordering(arg, name) == :disjoint
            end
          when RBS::Types::Optional then disjoint_param?(rbs_type.type, arg_names, environment, loader)
          when RBS::Types::Union then rbs_type.types.all? { |member| disjoint_param?(member, arg_names, environment, loader) }
          else false
          end
        end
      end
    end
  end
end
