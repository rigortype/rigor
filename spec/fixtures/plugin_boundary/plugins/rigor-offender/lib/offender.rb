# frozen_string_literal: true

# Positive control for the ADR-128 WD4 plugin-boundary gate (`spec/rigor/plugin_boundary_spec.rb`). It sits under
# a fixture plugin root, so the recorder attributes these calls to a plugin. Each `reach_*` method makes one call
# that no interface carries; `within_interface` makes only calls the interfaces promise.
module PluginBoundaryFixture
  module Offender
    module_function

    # `locals` is an `attr_reader` (it fires only `:c_call`); `user_def_through_ancestors` is a Ruby method
    # (it fires `:call`). Neither is on `_Scope`.
    def reach_scope(scope)
      scope.locals
      scope.discovered_methods
    end

    def reach_inference
      Rigor::Inference::DeclarationWalk::Context.root(nesting: [])
    end

    # An instance method of an Inference object: the receiver is no module, so only the class's ancestry says it
    # is engine-internal.
    def reach_inference_instance
      Rigor::Inference::DeclarationWalk::Context.root(nesting: []).nesting
    end

    def within_interface(scope, node)
      scope.type_of(node)
      scope.self_type
      scope.local(:x)
      scope.source_path
      scope.environment.nominal_for_name("String")
      scope.nil?
      scope.respond_to?(:locals)
      nil
    end
  end
end
