# frozen_string_literal: true

require "prism"

require_relative "../acceptance"

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #2321 — the declines {DeclaredParamWrites} applies to a write whose value is an expression over declared
      # parameters, beyond the ones a bare read (`@x = x`) shares. Each says the expression's type, evaluated with the
      # parameters bound to their declared types, may not be the type the ivar holds at runtime:
      #
      # - a parameter whose declared type holds `untyped` at any depth (`Array[untyped]`, #2325): the answer is built
      #   on the part the author left untyped;
      # - an optional parameter whose default value's type is not within its declared type
      #   (`def initialize(x = nil)` under `(?Integer x)`): the value may run on the default, which the binding does not
      #   carry;
      # - an argument of any call in the value (`a + b`, `a + (b > 0 ? b : 0.5)`, `a[i]`, `Array(x)`, `super(…)`,
      #   `yield(…)`), typed under the parameter bindings, whose type is anything but a literal or an instance of a
      #   class no RBS class names as its superclass: the engine picks the first overload such an argument matches
      #   (`Integer#+` given `Integer | Float` answers `Integer`), not the join of every overload it may reach. A
      #   receiver dispatches per member and is not declined. A splat or keyword argument types as neither, so it
      #   declines too.
      module DerivedParamValue
        module_function

        # Whether a write over the parameters `names`, declared `types`, is not credited for a parameter it reads.
        def declined?(names, types, def_node, scope)
          names.any? do |name|
            carries_dynamic?(types[name]) || default_outside?(def_node, name, types[name], scope)
          end
        end

        # Whether a call in `value` takes an argument whose type, under the parameter bindings of `bound`, may match an
        # overload narrower than itself.
        def overload_sensitive_argument?(value, bound)
          return false unless value.is_a?(Prism::Node)

          if value.is_a?(Prism::CallNode) || value.is_a?(Prism::SuperNode) || value.is_a?(Prism::YieldNode)
            arguments = value.arguments&.arguments || []
            return true if arguments.any? { |argument| overload_sensitive?(bound.type_of(argument), bound) }
          end
          value.rigor_each_child { |child| return true if overload_sensitive_argument?(child, bound) }
          false
        end

        def carries_dynamic?(type)
          case type
          when Type::Dynamic then true
          when Type::Union, Type::Intersection then type.members.any? { |member| carries_dynamic?(member) }
          when Type::Nominal then type.type_args.any? { |arg| carries_dynamic?(arg) }
          when Type::Tuple then type.elements.any? { |element| carries_dynamic?(element) }
          when Type::HashShape then type.pairs.each_value.any? { |pair_value| carries_dynamic?(pair_value) }
          # No RBS parameter spelling yields a refinement over `untyped`; the arm keeps the walk total.
          when Type::Difference, Type::Refined then carries_dynamic?(type.base)
          else false
          end
        end

        # Whether an argument of this declared type may match an overload narrower than itself.
        def overload_sensitive?(type, scope)
          case type
          when Type::Constant then false
          when Type::Nominal then !leaf_class?(type.class_name, scope&.environment)
          else true
          end
        end

        def leaf_class?(class_name, environment)
          return false if environment.nil? || environment.rbs_module?(class_name)
          # A guard: a validated RBS signature names no unknown class, so this answers only for a broken environment.
          return false unless environment.class_known?(class_name)

          superclasses = environment.rbs_loader&.superclass_names
          return false if superclasses.nil? || superclasses.empty?

          !superclasses.include?(class_name.delete_prefix("::"))
        end

        # Whether `name` is an optional parameter of `def_node` whose default value's type is not within `declared`.
        def default_outside?(def_node, name, declared, scope)
          default = default_value(def_node.parameters, name)
          return false if default.nil?

          default_type = scope.type_of(default)
          return true if carries_dynamic?(default_type)

          !Acceptance.accepts(declared, default_type).yes? && !empty_collection_within?(declared, default_type)
        end

        # An empty `[]` or `{}` default is within any `Array[T]` or `Hash[K, V]` the declaration names, which the
        # acceptance check answers only `maybe` (the empty literal has no element type to compare).
        def empty_collection_within?(declared, default_type)
          collection =
            if default_type.is_a?(Type::Tuple) && default_type.elements.empty? then "Array"
            elsif default_type.is_a?(Type::HashShape) && default_type.pairs.empty? then "Hash"
            end
          return false if collection.nil?

          members = declared.is_a?(Type::Union) ? declared.members : [declared]
          members.any? { |member| member.is_a?(Type::Nominal) && member.class_name == collection }
        end

        def default_value(parameters, name)
          candidates = parameters.optionals + parameters.keywords
          candidates.find { |param| param.respond_to?(:value) && param.name == name }&.value
        end
      end
    end
  end
end
