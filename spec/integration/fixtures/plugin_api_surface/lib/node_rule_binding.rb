# `node_rule`'s block binds `node` from the class argument (#2686).
class BindingPlugin < Rigor::Plugin::Base
  def self.register(node_class)
    node_rule(node_class) do |node, _scope, _path, _file_context, _context|
      node.predicate # surface: unknown-class
      nil
    end
  end

  node_rule(Prism::IfNode) do |node, _scope, _path, _file_context, _context|
    node.predicate # surface: no-overload-class
    node.not_a_member # surface: no-overload-class-miss
    nil
  end

  node_rule(Prism::CallNode) do |node, _scope, _path, _file_context, _context|
    node.receiver # surface: overload-class
    nil
  end
end
