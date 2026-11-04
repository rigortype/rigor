# Plugin source: a class that inherits `Rigor::Plugin::Base`, its hook values typed by `sig/rigor/plugin/base.rbs`.
# Each line the spec reads is marked `# surface: <name>`.
class SurfacePlugin < Rigor::Plugin::Base
  node_rule(Prism::CallNode) do |node, scope, _path, file_context, _context|
    scope.discovered_method?("Foo", :bar, :instance) # surface: undeclared
    scope.environment.class_ordering("A", "B") # surface: undeclared-environment
    scope.type_of(node) # surface: declared
    scope.respond_to?(:type_of) # surface: object-member
    joined = node.receiver ? scope : file_context
    joined.discovered_method?("Foo", :bar, :instance) # surface: lost-at-join
    maybe = node.receiver && scope
    maybe&.environment&.class_ordering("A", "B") # surface: lost-through-safe-navigation
    maybe&.discovered_method?("Foo", :bar, :instance) # surface: nilable-receiver
    nil
  end

  # A helper parameter has no RBS, so its value is untyped: nothing to read a surface from.
  def helper(scope)
    scope.discovered_method?("Foo", :bar, :instance) # surface: untyped-helper
  end
end

# A plugin that reaches `Rigor::Plugin::Base` through a project base class.
class SurfaceBase < Rigor::Plugin::Base
end

class IndirectPlugin < SurfaceBase
  node_rule(Prism::CallNode) do |_node, scope, _path, _file_context, _context|
    scope.discovered_method?("Foo", :bar, :instance) # surface: indirect
    nil
  end
end
