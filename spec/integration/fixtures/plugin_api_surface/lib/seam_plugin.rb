# ADR-128 WD5's seam: a plugin hands its hook `scope` (`_Scope`) to an engine signature that takes the backing class.
# Under ADR-130 the value is untyped to assignability, so no `call.argument-type-mismatch`.
class SeamPlugin < Rigor::Plugin::Base
  node_rule(Prism::CallNode) do |_node, scope, _path, _file_context, _context|
    ScopeTaker.take(scope) # surface: seam
    ScopeTaker.take(1) # surface: seam-control
    # `Rigor::Reflection`'s `scope: Scope` is a keyword position, which `call.argument-type-mismatch` does not check
    # today, so these two lines are silent whatever `scope` is. They pin only that the real call shape draws nothing.
    Rigor::Reflection.project_method_defined("Foo", :bar, kind: :instance, source: :def, scope: scope) # surface: seam-reflection
    Rigor::Reflection.nominal_for_name("Foo", scope: scope) # surface: seam-reflection-optional
    nil
  end
end

# A positional `Rigor::Scope` parameter, which the argument rule checks (`sig/seam.rbs`).
class ScopeTaker
  def self.take(_scope) = nil
end
