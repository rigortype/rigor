# frozen_string_literal: true

require "spec_helper"

# ADR-57 N5's overridable-method gate answers from two bounded `Thread.current` memos
# (`override_gate_buckets`, `method_definers_index`) keyed on the IDENTITY of the scope's frozen
# discovery tables. Because the memos are bounded rather than accumulating, a key that stops matching
# must drop the memo rather than shadow it, and the integration fixture cannot see that: it analyses a
# single file, so it only ever presents one set of tables. These examples alternate scopes within one
# thread, which is what the real run does (each file's pre-passes type under the project-seed tables and
# its main pass under the file's merged tables).
#
# Each pair below shares one key object with `a` and differs in another, so a memo keyed on too few of
# the tables answers `a`'s question for it:
#
#   b  shares `a`'s def table, differs in `discovered_superclasses` — `Sub` no longer inherits `Base`.
#   c  shares `a`'s ancestry and singleton tables, differs in the def table — `Sub` no longer defines
#      `flag`, so the inverted `method_name -> [owner names]` index must be rebuilt.
RSpec.describe Rigor::Inference::ExpressionTyper do
  let(:node) { Prism.parse("def flag = false").value.statements.body.first }
  let(:shared_defs) { { "Base" => { flag: node }, "Sub" => { flag: node } }.freeze }
  let(:other_defs) { { "Base" => { flag: node }, "Sub" => { other: node } }.freeze }
  let(:no_singletons) { {}.freeze }
  let(:related) { { "Sub" => "Base" }.freeze }
  let(:unrelated) { {}.freeze }
  let(:no_includes) { {}.freeze }

  def scope_with(defs, supers)
    base = Rigor::Scope.empty
    base.with_discovery(
      base.discovery.with(discovered_def_nodes: defs, discovered_singleton_def_nodes: no_singletons,
                          discovered_superclasses: supers, discovered_includes: no_includes)
    )
  end

  def overridden?(scope)
    described_class.new(scope: scope).send(:overridden_in_project?, "Base", :flag, :instance)
  end

  it "answers each scope from its own discovery tables when scopes alternate in one thread" do
    a = scope_with(shared_defs, related)
    b = scope_with(shared_defs, unrelated)
    c = scope_with(other_defs, related)

    expect(overridden?(a)).to be(true)
    expect(overridden?(b)).to be(false)
    expect(overridden?(a)).to be(true)
    expect(overridden?(c)).to be(false)
    expect(overridden?(a)).to be(true)
  end
end
