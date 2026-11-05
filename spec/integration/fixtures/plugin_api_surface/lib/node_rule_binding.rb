# `node_rule`'s block binds `node` from the class argument (#2686).
class BindingPlugin < Rigor::Plugin::Base
  def self.register(node_class)
    node_rule(node_class) do |node, _scope, _path, _file_context, _context|
      node.predicate # surface: unknown-class
      Rigor.dump_type(node) # surface: unknown-class-type
      nil
    end
  end

  def self.register_either(flag)
    node_rule(flag ? Prism::IfNode : Prism::UnlessNode) do |node, _scope, _path, _file_context, _context|
      Rigor.dump_type(node) # surface: class-union-type
      nil
    end
  end

  def self.register_mixed(flag, node_class)
    node_rule(flag ? Prism::IfNode : node_class) do |node, scope, _path, _file_context, _context|
      Rigor.dump_type(node) # surface: mixed-union-type
      Rigor.dump_type(scope) # surface: mixed-union-scope
      nil
    end
  end

  node_rule(Prism::IfNode) do |node, scope, _path, _file_context, _context|
    node.predicate # surface: no-overload-class
    node.not_a_member # surface: no-overload-class-miss
    Rigor.dump_type(scope) # surface: no-overload-class-scope
    nil
  end

  node_rule(Prism::CallNode) do |node, _scope, _path, _file_context, _context|
    node.receiver # surface: overload-class
    nil
  end

  node_file_context do |root, _scope|
    Rigor.dump_type(root) # surface: other-hook
  end
end

# A project's own `node_rule` keeps its declared binding.
class OwnRegistry
  def self.node_rule(_node_class) = nil
end

OwnRegistry.node_rule(Prism::IfNode) do |node|
  Rigor.dump_type(node) # surface: own-node-rule
end
