# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# #1730. A module `extend`ed onto N can reshape N's INSTANCE side: its `def self.extended(base) = base.include(Y)`
# runs against N at the `extend`, and its instance `def included(o) = o.include(Z)` becomes N's own hook and runs
# against N's includers. Neither is a fact of the tables, and the extended module sits on N's singleton chain, so
# N's instance readers used to answer as if nothing had moved: `call.wrong-arity` from `Base#greet` on a call Ruby
# answers from `Y#greet`. The resolution chain now marks N's instance side unpositioned (`"*"`) when a module N
# extends records `"*"` on its own instance side and defines such a hook, and the readers decline. The oracle for
# the warm cases is a full `--no-cache` run of the same tree; the driver is `IncrementalSession`.
RSpec.describe "a hook on an extended module — instance-side taint" do
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

  let(:greeters) do
    "module Y\n  def greet(name) = name\nend\n\nclass Base\n  def greet = \"hi\"\nend\n"
  end

  describe "a cold run" do
    it "declines a call an `extended` hook's include answers" do
      cm = "module ClassMethods\n  def self.extended(base)\n    base.include(Y)\n  end\nend\n"
      expect(cold("g.rb" => greeters, "cm.rb" => cm,
                  "k.rb" => "class K < Base\n  extend ClassMethods\nend\nK.new.greet(\"bob\")\n")).to eq([])
    end

    it "declines a call on an includer of a module that extends one with an instance `included` hook" do
      hookish = "module Hookish\n  def included(o)\n    super\n    o.include(Y)\n  end\nend\n"
      user = "module N\n  extend Hookish\nend\n\nclass C < Base\n  include N\nend\nC.new.greet(\"bob\")\n"
      expect(cold("g.rb" => greeters, "h.rb" => hookish, "c.rb" => user)).to eq([])
    end

    it "puts a refinement in effect through a `using` of a module whose extended hook includes the refiner" do
      source = <<~RUBY
        module A
          refine(String) { def shout = upcase }
        end
        module CM
          def self.extended(base)
            base.include(A)
          end
        end
        module D
          extend CM
        end
        using D
        "a".shout
      RUBY
      expect(cold("u.rb" => source)).to eq([])
    end

    it "still reports when the extended module's hook mixes nothing in" do
      cm = "module ClassMethods\n  def self.extended(base) = nil\nend\n"
      expect(cold("g.rb" => greeters, "cm.rb" => cm,
                  "k.rb" => "class K < Base\n  extend ClassMethods\nend\nK.new.greet(\"bob\")\n"))
        .to eq([["k.rb", 4, "call.wrong-arity"]])
    end

    it "still reports when the extended module mixes into its parameter outside a hook" do
      cm = "module ClassMethods\n  def self.setup(base)\n    base.include(Y)\n  end\nend\n"
      expect(cold("g.rb" => greeters, "cm.rb" => cm,
                  "k.rb" => "class K < Base\n  extend ClassMethods\nend\nK.new.greet(\"bob\")\n"))
        .to eq([["k.rb", 4, "call.wrong-arity"]])
    end
  end

  describe "a warm run" do
    let(:hooked) { "module ClassMethods\n  def self.extended(base)\n    base.include(Y)\n  end\nend\n" }
    let(:plain) { "module ClassMethods\n  def self.extended(base) = nil\nend\n" }
    let(:files) do
      { "g.rb" => greeters, "k.rb" => "class K < Base\n  extend ClassMethods\nend\n", "b.rb" => "K.new.greet(\"bob\")\n" }
    end

    def walk(initial, steps)
      Dir.mktmpdir do |dir|
        initial.each { |name, source| File.write(File.join(dir, name), source) }
        session = Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                                          environment: shared_environment)
        baseline = rows(guarded_baseline(session))
        expect(baseline).to eq(full_run(dir))
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
      walk(files.merge("cm.rb" => plain), [{ "cm.rb" => hooked }, { "cm.rb" => plain }, { "cm.rb" => hooked }]) do |warm, cold|
        colds << cold
        expect(warm).to eq(cold)
      end
      expect(colds).to eq([[], [["b.rb", 1, "call.wrong-arity"]], []])
    end

    it "matches a cold run when a new file reopens the extended module to add the hook" do
      reopen = "module ClassMethods\n  def self.extended(base)\n    base.include(Y)\n  end\nend\n"
      walk(files.merge("cm.rb" => "module ClassMethods\nend\n"), [{ "cm_hook.rb" => reopen }]) do |warm, cold|
        expect(cold).to eq([])
        expect(warm).to eq(cold)
      end
    end
  end
end
