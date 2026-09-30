# frozen_string_literal: true

require "spec_helper"

# #1587 and #1573 — a repeated `include` keeps its FIRST position (since #1173), a repeated `prepend` is kept
# in the table and dropped by the chain, and a repeated `extend` names the singleton side unpositioned. A module
# written to both the include and the prepend table of one class is a body the tables cannot represent
# (`[M, C, M]`), so the instance side of that class is named unpositioned.
RSpec.describe "mixin tables: repeated targets and both-kind targets" do
  def scope_for(source)
    root = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
  end

  # The prepend table keeps every statement, nearest first, so the readers that walk it raw see what they always
  # saw; the resolution chain drops a same-owner repeat (Ruby skips it), the first statement winning (#1587).
  it "keeps every prepend statement in the table and lets the chain keep the first" do
    scope = scope_for(<<~RUBY)
      module P; def a = 1; end
      module Q; def b = 1; end
      class C; prepend P; prepend Q; prepend P; end
    RUBY
    expect(scope.discovered_prepends["C"]).to eq(%w[P Q P])
    chain = Rigor::Scope::ResolutionChain.for(scope, "C", :instance, :methods)
    expect(chain.entries.map(&:name)).to eq(%w[Q P C])
    expect(chain.skip_count).to eq(0)
  end

  # Round-3 review (a fuzz program): `M2` was prepended to `D` empty and includes `M4` before `D` prepends `M4`,
  # so Ruby's `D` is `[M2, M4, D, ...]` and `M2#foo` runs. Deduplicating the repeated `prepend M2` in the table
  # put `M4` nearer and moved the readers' own fallback answer to `M4#foo`; the table keeps every statement, so
  # the fallback answers as it always did.
  it "answers the first definer Ruby runs where a repeated prepend surrounds a later include" do
    scope = scope_for(<<~RUBY)
      module M0; def foo = "m0"; end
      module M2; def foo = "m2"; end
      module M4; def foo = 4; end
      class C; def foo = "c"; end
      class D < C; def foo = "d"; end
      class C; include M2; end
      class D; prepend M2; end
      module M2; include M4; end
      class D; prepend M4; end
      class D; prepend M2; end
      class D; include M0; end
    RUBY
    expect(scope.user_def_through_ancestors("D", :foo).last).to eq("M2")
  end

  # The extend table keeps its later-statement position (the folded singleton tables read that order), so a
  # repeat names the singleton side unpositioned and every reader answers what it always did (#1573 stays open).
  it "names the singleton side unpositioned on a repeated extend" do
    scope = scope_for(<<~RUBY)
      module E1; end
      module E2; end
      class C; extend E1; extend E2; extend E1; end
      class D; extend E1; end
    RUBY
    expect(scope.discovered_extends["C"]).to eq(%w[E1 E2])
    expect(scope.discovery.unpositioned_mixins["C"]).to include(extend: include("*"))
    expect(scope.discovery.unpositioned_mixins["D"]).to be_nil
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
