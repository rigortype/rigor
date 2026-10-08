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

  # The precision half: the entries past an answer file a negative class edge only when they are PROJECT entries
  # and the answer is not the root's own. A namespaced file that merely shares a last segment with an external
  # ancestor (`Admin::Comparable`) or with a project module the answer precedes must not re-check the consumer.
  it "does not re-check a consumer when an unrelated namespaced file reuses an ancestor's last segment" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "h.rb"), "module Helpers\n  def foo = 1\nend\n")
      File.write(File.join(dir, "c.rb"), "class C\n  include Comparable\n  include Helpers\nend\n")
      File.write(File.join(dir, "b.rb"), "C.new.foo\n")
      session = session_for(dir)
      guarded_baseline(session)
      File.write(File.join(dir, "x.rb"), "module Admin\n  module Comparable\n  end\n\n  module Helpers\n  end\nend\n")
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(File.join(dir, "x.rb"))
      expect(recheck.affected).not_to include(File.join(dir, "b.rb"))
    end
  end

  # ADR-119 C1b — `SourceArity` declines (`UNKNOWN`) where a mark is not discharged for the name, and the decline is
  # a verdict another file's edit can lift or impose, so a declined walk records everything it read. The oracle is a
  # full `--no-cache` run of the same tree.
  describe "SourceArity's declined chain (ADR-119 C1b)" do
    def arity(list)
      list.select { |d| d.rule == "call.wrong-arity" }.map { |d| [File.basename(d.path), d.line] }.sort
    end

    def full_arity_run(dir)
      runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                           environment: shared_environment)
      arity(guarded_run(runner).diagnostics)
    end

    # `C` answers `foo(x)` itself, so the receiver's typing files no edge past the root; the arity read still
    # declines while a conditional mixin `Q` could answer it, and what lets it stand is read only there.
    let(:tree) do
      {
        "c.rb" => "class C\n  def foo(x) = x\n  include Q if ENV[\"X\"]\nend\n",
        "b.rb" => "C.new.foo\n"
      }
    end

    def warm_and_cold(files, edits, baseline:)
      Dir.mktmpdir do |dir|
        files.each { |name, source| File.write(File.join(dir, name), source) }
        session = session_for(dir)
        expect(arity(guarded_baseline(session))).to eq(baseline)
        edits.each { |name, source| File.write(File.join(dir, name), source) }
        [arity(guarded_recheck(session).diagnostics), full_arity_run(dir)]
      end
    end

    it "re-checks a declined consumer when an edit lifts a `method_missing` hook out of the mark's closure" do
      files = tree.merge("q.rb" => "module Q\n  include R\nend\n",
                         "r.rb" => "module R\n  def method_missing(*) = 2\nend\n")
      warm, cold = warm_and_cold(files, { "r.rb" => "module R\n  def bar = 2\nend\n" }, baseline: [])
      expect(cold).to eq([["b.rb", 1]])
      expect(warm).to eq(cold)
    end

    # ADR-119 A1 (#1622): `C` answers itself at its chain's head, so no mark or fork elsewhere declines the read,
    # except one that may prepend onto `C`. A superclass's `inherited` hook that prepends lists `"*"` on `Base`, and
    # the read declines; `settle` files `Base` although the answer is the root's own.
    it "re-checks an own-definer consumer when its superclass gains a hook that may prepend onto it" do
      files = { "base.rb" => "class Base
end
", "c.rb" => "class C < Base
  def foo(x) = x
end
",
                "b.rb" => "C.new.foo
" }
      hooked = "module P
  def foo(*) = 1
end

class Base
  def self.inherited(sub)
    super
    " \
               "sub.prepend(P)
  end
end
"
      warm, cold = warm_and_cold(files, { "base.rb" => hooked }, baseline: [["b.rb", 1]])
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end

    it "re-checks a firing consumer when a second file puts a hook into the mark's closure" do
      files = tree.merge("q.rb" => "module Q\n  include R\nend\n", "r.rb" => "module R\n  def bar = 2\nend\n")
      warm, cold = warm_and_cold(files, { "r.rb" => "module R\n  def method_missing(*) = 2\nend\n" },
                                 baseline: [["b.rb", 1]])
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end
  end
end
