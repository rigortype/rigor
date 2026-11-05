# frozen_string_literal: true

require "rbs"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #2828 — how overload selection reads a parameter spelled `singleton(T)` over a method-level type
      # variable `T`. RBS parses it as a class singleton whose name is the bare, relative `T`, and the
      # translator reads that as a class named `T`: an unloadable class whose singleton refuses every class object
      # the analyzer process has loaded (`Acceptance` rules a loaded class out of an unloadable target's
      # subtypes). With `Resolv` loaded, `Resolv::DNS#getresources: [T < Resource] (dns_name, singleton(T)) ->
      # Array[T] | ...` then lost to the base overload.
      #
      # Selection instead reads the parameter as "a class object" the variable admits: `singleton(X)` for a
      # class upper bound `X`, and `Module` otherwise, which takes any class or module object and refuses an
      # instance. Only names the overload declares in its own `type_params` are read this way; any other
      # unresolved `singleton(X)` keeps the translator's reading.
      #
      # {.selecting} hands the selector the overloads rewritten where a parameter needs it and maps the selected
      # rewrites back, so the return translation and the argument binding (`RbsDispatch#singleton_param_binding`)
      # still read the declared `singleton(T)`.
      module SingletonTypeParams
        module_function

        # Yields the overloads to select among and answers the block's selection, with each rewrite mapped back to
        # its declaration. Nearly every method needs no rewrite, and then `declared` is yielded as is.
        def selecting(declared)
          return yield(declared) unless declared.any? { |method_type| rewrites?(method_type) }

          originals = {}.compare_by_identity
          rewritten = declared.map do |method_type|
            next method_type unless rewrites?(method_type)

            rewrite = rewrite(method_type)
            originals[rewrite] = method_type
            rewrite
          end
          yield(rewritten).map { |method_type| originals.fetch(method_type, method_type) }
        end

        def rewrites?(method_type)
          params = method_type.respond_to?(:type_params) ? method_type.type_params : nil
          return false if params.nil? || params.empty?

          fun = method_type.type
          return false unless fun.respond_to?(:required_positionals)

          any_variable_singleton?(fun.required_positionals, params) ||
            any_variable_singleton?(fun.optional_positionals, params) ||
            any_variable_singleton?(fun.trailing_positionals, params)
        end

        def any_variable_singleton?(list, type_params)
          list.any? { |param| variable_singleton?(param.type, type_params) }
        end

        def variable_singleton?(type, type_params)
          return false unless type.is_a?(RBS::Types::ClassSingleton)

          name = type.name
          return false if name.absolute? || !name.namespace.empty?

          type_params.any? { |type_param| type_param.name == name.name }
        end

        # One parameter of `method_type` as selection reads it: `call.argument-type-mismatch` checks a call the
        # same way, and otherwise declines every overload with a `singleton(T)` parameter as naming a class nothing
        # defines.
        def selection_param(param, method_type)
          type_params = method_type.type_params
          return param unless variable_singleton?(param.type, type_params)

          param.map_type { |type| class_object_type(type.name.name, type_params) }
        end

        def rewrite(method_type)
          type_params = method_type.type_params
          fun = method_type.type.map_type do |type|
            variable_singleton?(type, type_params) ? class_object_type(type.name.name, type_params) : type
          end
          RBS::MethodType.new(type_params: type_params, type: fun, block: method_type.block,
                              location: method_type.location)
        end

        # Built per rewrite rather than held in a constant: an RBS type is not `Ractor.shareable?` (#1064), and a
        # rewrite happens only for the few overloads that spell `singleton(T)`.
        def module_type
          RBS::Types::ClassInstance.new(
            name: RBS::TypeName.new(name: :Module, namespace: RBS::Namespace.root), args: [], location: nil
          )
        end

        def class_object_type(name, type_params)
          type_param = type_params.find { |tp| tp.name == name }
          bound = type_param.upper_bound
          return module_type unless bound.is_a?(RBS::Types::ClassInstance)

          RBS::Types::ClassSingleton.new(name: bound.name, location: nil)
        end
      end
    end
  end
end
