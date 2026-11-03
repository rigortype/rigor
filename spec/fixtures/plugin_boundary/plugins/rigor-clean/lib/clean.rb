# frozen_string_literal: true

# Negative control for the plugin-boundary gate: a plugin that stays inside the interfaces draws nothing.
module PluginBoundaryFixture
  module Clean
    module_function

    def read(scope, node)
      scope.type_of(node)
      scope.environment.rbs_module?("Kernel")
    end
  end
end
