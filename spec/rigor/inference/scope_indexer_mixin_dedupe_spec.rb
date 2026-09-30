# frozen_string_literal: true

require "spec_helper"

# #1573 and #1587 — the producers keep the FIRST position of a repeated mixin, as Ruby's skip of a module
# already in the ancestry does, for `include` (since #1173), `prepend` and `extend`. A module written to both
# the include and the prepend table of one class is a body the tables cannot represent (`[M, C, M]`), so the
# instance side of that class is named unpositioned.
RSpec.describe "mixin tables: repeated targets and both-kind targets" do
  def scope_for(source)
    root = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
  end

  it "keeps a repeated prepend at its first position" do
    scope = scope_for("module P; end\nmodule Q; end\nclass C; prepend P; prepend Q; prepend P; end\n")
    expect(scope.discovered_prepends["C"]).to eq(%w[Q P])
  end

  it "keeps a repeated extend at its first position" do
    scope = scope_for("module E1; end\nmodule E2; end\nclass C; extend E1; extend E2; extend E1; end\n")
    expect(scope.discovered_extends["C"]).to eq(%w[E2 E1])
  end

  it "names the instance side unpositioned when a module is both included and prepended" do
    scope = scope_for(<<~RUBY)
      module M; end
      class C; include M; prepend M; end
      class D; prepend M; end
      class E; include M; end
    RUBY
    expect(scope.discovery.unpositioned_mixins["C"]).to include(include: include("*"))
    expect(scope.discovery.unpositioned_mixins["D"]).to be_nil
    expect(scope.discovery.unpositioned_mixins["E"]).to be_nil
  end

  it "names the instance side unpositioned in either statement order" do
    scope = scope_for("module M; end\nclass C; prepend M; include M; end\n")
    expect(scope.discovery.unpositioned_mixins["C"]).to include(include: include("*"))
  end
end
