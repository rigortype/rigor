# ADR-128 WD5's seam: a plugin hands its hook `scope` (`_Scope`) to `Rigor::Reflection`, whose RBS takes
# `scope: Scope`. Under ADR-130 the value is untyped to assignability, so no `call.argument-type-mismatch`.
class SeamPlugin < Rigor::Plugin::Base
  node_rule(Prism::CallNode) do |_node, scope, _path, _file_context, _context|
    Rigor::Reflection.project_method_defined("Foo", :bar, kind: :instance, source: :def, scope: scope) # surface: seam
    Rigor::Reflection.nominal_for_name("Foo", scope: scope) # surface: seam-optional
    nil
  end
end
