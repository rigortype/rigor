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
      # as that arm's return and fired `call.undefined-method` on correct code. {.contested?} asks the
      # environment, which reads RBS, whether any arm declared before the chosen one names a class or module the
      # argument's class is, or may be, and pass 0 then declines.
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

        # Whether an overload declared before `declared[index]` may take the arguments.
        def contested?(declared, index, arg_types, environment)
          return true if environment.nil?

          (0...index).any? do |position|
            any_declared_class_name?(declared[position]) { |name| may_take?(name, arg_types, environment) }
          end
        end

        # `:unknown` counts: an ordering the environment cannot answer is no proof that the arm is out.
        def may_take?(param_name, arg_types, environment)
          arg_types.any? do |arg|
            %i[equal subclass unknown].include?(environment.class_ordering(class_name_of(arg), param_name))
          end
        end

        # Whether a class or module name an overload's positional parameters spell, through `?` and `|`, meets
        # the block.
        def any_declared_class_name?(method_type, &)
          fun = method_type.type
          return false unless fun.respond_to?(:required_positionals)

          [fun.required_positionals, fun.optional_positionals, fun.trailing_positionals].any? do |params|
            params.any? { |param| class_name_in?(param.type, &) }
          end
        end

        def class_name_in?(rbs_type, &)
          case rbs_type
          when RBS::Types::ClassInstance then yield rbs_type.name.to_s.delete_prefix("::")
          when RBS::Types::Optional then class_name_in?(rbs_type.type, &)
          when RBS::Types::Union then rbs_type.types.any? { |member| class_name_in?(member, &) }
          else false
          end
        end
      end
    end
  end
end
