# Not plugin source. Each method's parameter is typed by an interface through `sig/engine_side.rbs` or `base.rbs`, so
# the value carries the facet, but the rule judges only code inside a `Rigor::Plugin::Base` subclass.
class EngineHelper
  def walk(scope)
    scope.discovered_method?("Foo", :bar, :instance) # surface: not-a-plugin
  end
end

module Rigor
  module Plugin
    # `Base`'s own hooks hand interface values to engine helpers; they are engine code.
    class Base
      def node_rule_diagnostics(path:, scope:, root:)
        scope.discovered_method?(path, root, :instance) # surface: engine-base
        []
      end
    end
  end
end
