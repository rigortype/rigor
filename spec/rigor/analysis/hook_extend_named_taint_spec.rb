# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# #1687. `base.extend X` in a `self.included(base)`-style hook reaches the includer's singleton; it reshapes the
# includer's INSTANCE side only through a hook of X's own (`X.extended` mixing into its parameter, or an instance
# `included` X lends the includer). The indexer used to list `"*"` on the hook module's instance side for it, so
# every reader through an includer declined, and `using` of a module including the hook module put every
# refinement in effect. It now lists X by name there: a candidate-set read tests X's closure
# (`ResolutionChain::Relevance`), and the refinement expansion asks whether X's own hooks may mix in
# (`ResolutionChain#off_chain_mixin_reshapes?`). The warm oracle is a full `--no-cache` run of the same tree.
RSpec.describe "a hook's base.extend — named instance-side taint" do
  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def rows(list)
    list.select { |d| %w[call.wrong-arity call.undefined-method].include?(d.rule) }
        .map { |d| [File.basename(d.path), d.line, d.rule] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    rows(guarded_run(runner).diagnostics)
  end

  def cold(files)
    Dir.mktmpdir do |dir|
      files.each { |name, source| File.write(File.join(dir, name), source) }
      full_run(dir)
    end
  end

  let(:refiner) { "module A\n  refine(String) { def shout = upcase }\nend\n" }
  let(:hook_module) { "module Plain\n  def self.included(base)\n    base.extend(X)\n  end\nend\n" }
  let(:using_file) { "module D\n  include Plain\nend\nusing D\n\"a\".shout\n" }
  let(:greeters) { "module Y\n  def greet(name) = name\nend\n\nclass Base\n  def greet = \"hi\"\nend\n" }

  describe "a cold run" do
    it "reports a refined call when the extended module has no hook" do
      files = { "a.rb" => refiner, "x.rb" => "module X\n  def cm = 1\nend\n", "p.rb" => hook_module,
                "u.rb" => using_file }
      expect(cold(files)).to eq([["u.rb", 5, "call.undefined-method"]])
    end

    it "declines a refined call when the extended module's own hook includes the refiner" do
      x = "module X\n  def self.extended(base)\n    base.include(A)\n  end\nend\n"
      expect(cold("a.rb" => refiner, "x.rb" => x, "p.rb" => hook_module, "u.rb" => using_file)).to eq([])
    end

    it "declines a refined call when the hook extends a module it cannot name" do
      plain = "module Plain\n  def self.included(base)\n    base.extend(helper)\n  end\nend\n"
      expect(cold("a.rb" => refiner, "p.rb" => plain, "u.rb" => using_file)).to eq([])
    end

    it "declines an arity read the extended module's `extended` hook may answer" do
      x = "module X\n  def self.extended(base)\n    base.include(Y)\n  end\nend\n"
      k = "class K < Base\n  include Plain\nend\nK.new.greet(\"bob\")\n"
      expect(cold("g.rb" => greeters, "x.rb" => x, "p.rb" => hook_module, "k.rb" => k)).to eq([])
    end

    it "declines an arity read an instance `included` the extended module lends may answer" do
      x = "module X\n  def included(o)\n    super\n    o.include(Y)\n  end\nend\n"
      n = "module N\n  include Plain\nend\n\nclass C < Base\n  include N\nend\nC.new.greet(\"bob\")\n"
      expect(cold("g.rb" => greeters, "x.rb" => x, "p.rb" => hook_module, "c.rb" => n)).to eq([])
    end

    # Review shapes from #1741: the extended module may reshape the includer through any code Ruby runs on the
    # extend, which only {ResolutionChain.extend_clean?} rules out.
    {
      "a chained hook extend" => "module Z\n  def self.extended(b) = b.include(A)\nend\n" \
                                 "module X\n  def self.extended(b) = b.extend(Z)\nend\n",
      "an extend_object hook" => "module X\n  def self.extend_object(b)\n    super\n    b.include(A)\n  end\nend\n",
      "a hook written outside the module body" => "module X; end\ndef X.extended(b) = b.include(A)\n",
      "an extended hook lent by an extended module" => "module Hooky\n  def extended(b) = b.include(A)\nend\n" \
                                                       "module X\n  extend Hooky\nend\n"
    }.each do |shape, x|
      it "declines a refined call through #{shape}" do
        expect(cold("a.rb" => refiner, "x.rb" => x, "p.rb" => hook_module, "u.rb" => using_file)).to eq([])
      end
    end

    # X lends D an instance hook; including D into E runs it. Each is seen by one test of `extend_clean?` alone.
    {
      "an instance hook the walk cannot read as a mixin" =>
        "module X\n  def included(o)\n    super\n    kind = :include\n    o.send(kind, A)\n  end\nend\n",
      "a module included in a way the walk cannot name" =>
        "module W\n  def included(o)\n    super\n    o.include(A)\n  end\nend\n" \
        "module X\n  include(*[W])\nend\n"
    }.each do |shape, x|
      it "declines a refined call through #{shape} on the hook-extended module" do
        user = "module D\n  include Plain\nend\nmodule E\n  include D\nend\nusing E\n\"a\".shout\n"
        expect(cold("a.rb" => refiner, "x.rb" => x, "p.rb" => hook_module, "u.rb" => user)).to eq([])
      end
    end

    it "declines a refined call through a direct extend of a module whose hook extends a hooked module" do
      x = "module Z\n  def self.extended(b) = b.include(A)\nend\nmodule X\n  def self.extended(b) = b.extend(Z)\nend\n"
      expect(cold("a.rb" => refiner, "x.rb" => x, "u.rb" => "module D\n  extend X\nend\nusing D\n\"a\".shout\n")).to eq([])
    end

    it "declines an arity read through a hook-extended ClassMethods with an instance inherited hook" do
      foo = "module Foo\n  def self.included(base)\n    base.extend(ClassMethods)\n  end\n" \
            "  module ClassMethods\n    def inherited(sub)\n      super\n      sub.include(Y)\n    end\n  end\nend\n"
      k = "class Parent < Base\n  include Foo\nend\nclass Child < Parent\nend\nChild.new.greet(\"bob\")\n"
      expect(cold("g.rb" => greeters, "f.rb" => foo, "k.rb" => k)).to eq([])
    end

    # No mixin call: only the instance-hook test sees it.
    it "declines an arity read through a hook-extended module whose instance inherited hook defines methods" do
      foo = "module Foo\n  def self.included(base)\n    base.extend(ClassMethods)\n  end\n" \
            "  module ClassMethods\n    def inherited(sub)\n      super\n      sub.define_method(:greet) { |n| n }\n" \
            "    end\n  end\nend\n"
      k = "class Parent < Base\n  include Foo\nend\nclass Child < Parent\nend\nChild.new.greet(\"bob\")\n"
      expect(cold("g.rb" => greeters, "f.rb" => foo, "k.rb" => k)).to eq([])
    end

    # No hook on X itself: only the unpositioned-mixin test sees the module it includes.
    it "declines an arity read through a hook-extended module that includes a module it cannot name" do
      w = "module W\n  def inherited(sub)\n    super\n    sub.define_method(:greet) { |n| n }\n  end\nend\n"
      foo = "module Foo\n  def self.included(base)\n    base.extend(X)\n  end\nend\n" \
            "module X\n  include(*[W])\nend\n"
      k = "class Parent < Base\n  include Foo\nend\nclass Child < Parent\nend\nChild.new.greet(\"bob\")\n"
      expect(cold("g.rb" => greeters, "w.rb" => w, "f.rb" => foo, "k.rb" => k)).to eq([])
    end

    it "declines an arity read when the extended module's instance included hook extends a hooked module" do
      x = "module Z\n  def self.extended(b) = b.include(Y)\nend\nmodule X\n  def included(o) = o.extend(Z)\nend\n"
      n = "module N\n  include Plain\nend\n\nclass C < Base\n  include N\nend\nC.new.greet(\"bob\")\n"
      expect(cold("g.rb" => greeters, "x.rb" => x, "p.rb" => hook_module, "c.rb" => n)).to eq([])
    end

    it "reports an arity read when the extended module has no hook, and keeps its class methods" do
      x = "module X\n  def cm = 1\nend\n"
      k = "class K < Base\n  include Plain\nend\nK.new.greet(\"bob\")\nK.cm\n"
      expect(cold("g.rb" => greeters, "x.rb" => x, "p.rb" => hook_module, "k.rb" => k))
        .to eq([["k.rb", 4, "call.wrong-arity"]])
    end
  end

  describe "a warm run" do
    let(:plain_x) { "module X\n  def cm = 1\nend\n" }
    let(:hooked_x) { "module X\n  def self.extended(base)\n    base.include(A)\n  end\nend\n" }
    let(:files) { { "a.rb" => refiner, "p.rb" => hook_module, "u.rb" => using_file } }

    def walk(initial, steps)
      Dir.mktmpdir do |dir|
        initial.each { |name, source| File.write(File.join(dir, name), source) }
        session = Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                                          environment: shared_environment)
        expect(rows(guarded_baseline(session))).to eq(full_run(dir))
        steps.each do |edits|
          edits.each do |name, source|
            path = File.join(dir, name)
            source.nil? ? File.delete(path) : File.write(path, source)
          end
          yield rows(guarded_recheck(session).diagnostics), full_run(dir)
        end
      end
    end

    it "matches a cold run as the extended module's hook appears, goes and comes back" do
      colds = []
      steps = [{ "x.rb" => hooked_x }, { "x.rb" => plain_x }, { "x.rb" => hooked_x }]
      walk(files.merge("x.rb" => plain_x), steps) do |warm, cold|
        colds << cold
        expect(warm).to eq(cold)
      end
      expect(colds).to eq([[], [["u.rb", 5, "call.undefined-method"]], []])
    end

    it "matches a cold run when a new file reopens the extended module to add the hook" do
      walk(files.merge("x.rb" => plain_x), [{ "x_hook.rb" => hooked_x }, { "x_hook.rb" => nil }]) do |warm, cold|
        expect(warm).to eq(cold)
      end
    end

    # The arity read tests X's closure (`Relevance`): a new file giving X a hook must un-clean it.
    it "matches a cold run on an arity read when a new file gives the extended module a hook" do
      initial = { "g.rb" => greeters, "x.rb" => plain_x, "p.rb" => hook_module,
                  "k.rb" => "class K < Base\n  include Plain\nend\nK.new.greet(\"bob\")\n" }
      hook = "module X\n  def self.extended(base)\n    base.include(Y)\n  end\nend\n"
      colds = []
      walk(initial, [{ "x_hook.rb" => hook }, { "x_hook.rb" => nil }]) do |warm, cold|
        colds << cold
        expect(warm).to eq(cold)
      end
      expect(colds).to eq([[], [["k.rb", 4, "call.wrong-arity"]]])
    end

    it "matches a cold run when a nearer module of the extended name appears" do
      nested = "module Outer\n  module Plain\n    def self.included(base)\n      base.extend(X)\n    end\n  end\nend\n"
      using = "module D\n  include Outer::Plain\nend\nusing D\n\"a\".shout\n"
      shadow = "module Outer\n  module X\n    def self.extended(base)\n      base.include(A)\n    end\n  end\nend\n"
      initial = { "a.rb" => refiner, "x.rb" => plain_x, "p.rb" => nested, "u.rb" => using }
      walk(initial, [{ "s.rb" => shadow }, { "s.rb" => nil }]) do |warm, cold|
        expect(warm).to eq(cold)
      end
    end
  end
end
