# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Round-3 review of #1578. `ResolutionChain#settle` reads EVERY node of a chain (a fork, an unpositioned edge, a
# second declaring file), and a `:master` verdict changes the answer, but `search` files edges only for the
# root and the entries ahead of the answer. A file edited after the answer entry (here `q.rb`, which `Base`
# includes as `Q`, behind `Base#foo`'s own definition) could flip the verdict without re-checking the consumer.
# `settle` therefore files the whole chain's class edges, whichever way it goes.
#
# The oracle is a full `--no-cache` run of the same tree; the driver is `IncrementalSession`, as in
# `class_existence_incremental_spec.rb`.
RSpec.describe "unsettled chain verdict — incremental" do
  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                            environment: shared_environment)
  end

  def diagnostics(list)
    list.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    diagnostics(guarded_run(runner).diagnostics)
  end

  let(:tree) do
    {
      "base.rb" => "class Base\n  include Q\n\n  def foo = 1\nend\n",
      "q.rb" => "module R\nend\n\nmodule Q\nend\n",
      "m.rb" => "module M\n  def foo = \"m\"\nend\n\nmodule A\n  include M\nend\n",
      "c.rb" => "class C < Base\n  include A\nend\n",
      "f.rb" => "module Factory\n  def self.build = C.new\nend\n",
      "b.rb" => "Factory.build.foo.upcase\n"
    }
  end

  # Runs the baseline, applies the edits, and returns `[warm, cold]` after the recheck. The baseline is silent
  # (`C#foo` is `M#foo`, a String), so a cold run that fires afterwards proves the edit moved the answer.
  def warm_and_cold(files, edits)
    Dir.mktmpdir do |dir|
      files.each { |name, source| File.write(File.join(dir, name), source) }
      session = session_for(dir)
      expect(diagnostics(guarded_baseline(session))).to eq([])
      edits.each { |name, source| File.write(File.join(dir, name), source) }
      [diagnostics(guarded_recheck(session).diagnostics), full_run(dir)]
    end
  end

  it "re-checks the consumer when a module past the answer gains an unpositioned edge" do
    warm, cold = warm_and_cold(tree, "q.rb" => "module R\nend\n\nmodule Q\n  include R if ENV[\"X\"]\nend\n")
    expect(cold).to eq([["b.rb", 1]])
    expect(warm).to eq(cold)
  end

  it "re-checks the consumer when a new file reopens a module past the answer with a second edge" do
    files = tree.merge("q.rb" => "module R\nend\n\nmodule S\nend\n\nmodule Q\n  include R\nend\n")
    warm, cold = warm_and_cold(files, "q2.rb" => "module Q\n  include S\nend\n")
    expect(cold).to eq([["b.rb", 1]])
    expect(warm).to eq(cold)
  end
end
