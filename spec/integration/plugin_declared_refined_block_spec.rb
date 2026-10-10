# frozen_string_literal: true

# Issue #1667 (ADR-121 WD5) — a block a library method runs under `Proc#refined`, declared by a plugin.
#
# The real-world use of Ruby 4.1's `Proc#refined` is a method that takes `&block` and runs it under its own
# refinements (`Ctx.new.instance_exec(&block.refined(SymSyntax))`; activerecord-refined's `where`, `select`,
# `joins`, … do exactly this). Nothing at the block's site shows it, so a `block_as_methods:` entry declares it with
# `refinements:`, and the modules are in effect in the block body after its lexical list.
#
# Every expectation below is the answer CRuby gives when `build` runs its block that way.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "Plugin-declared refined blocks (#1667)" do
  let(:library) do
    <<~RUBY
      module SymSyntax
        refine Symbol do
          def [](other) = "\#{self}.\#{other}"
          def shout = to_s.upcase
        end
      end

      class Ctx
        def ctx_only = 1
      end

      def build(&block)
        Ctx.new.instance_exec(&block.refined(SymSyntax))
      end

      def run_lexical(&block)
        block.refined(SymSyntax).call
      end

      class Lib
        def run_lexical(&block) = block.refined(SymSyntax).call
      end

      module Registry
        def self.add(name, &block) = nil
      end
    RUBY
  end

  def plugin_class(*entries)
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "refinedtest", version: "0.1.0", block_as_methods: entries)
    end
    stub_const("FakePluginRefinedTest", klass)
    klass
  end

  def entry(**overrides)
    Rigor::Plugin::Macro::BlockAsMethod.new(
      receiver_constraint: "Object", method_names: [:build], self_type: "Ctx", refinements: ["SymSyntax"], **overrides
    )
  end

  # `[line, rule]` for every error in `app.rb`, and the `dump_type` answers in order.
  def run_analysis(source, plugin, sig: nil)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "lib.rb"), library)
      File.write(File.join(dir, "app.rb"), %(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      settings = { "paths" => [File.join(dir, "lib.rb"), File.join(dir, "app.rb")], "plugins" => ["rigor-refinedtest"] }
      if sig
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(File.join(dir, "sig", "app.rbs"), sig)
        settings["signature_paths"] = [File.join(dir, "sig")]
      end
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(settings))
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(plugin)
            true
          end
        )
        summarize(guarded_run(runner))
      end
    end
  ensure
    Rigor::Plugin.unregister!
  end

  def summarize(result)
    app = result.diagnostics.select { |d| d.path.to_s.end_with?("app.rb") }
    errors = app.select { |d| d.severity == :error }.map { |d| [d.line - 2, d.qualified_rule] }
    types = app.filter_map { |d| d.message.delete_prefix("dump_type: ") if d.message.start_with?("dump_type") }
    { errors: errors, types: types }
  end

  # The issue's two caller lines, then the controls: a nested block inherits, a refined call outside the block and
  # a call to an unrelated method keep reporting.
  it "puts the declared refinements in effect in the block body and its nested blocks" do
    result = run_analysis(<<~RUBY, plugin_class(entry))
      build { :authors[:age] }
      build { :a.shout }
      build { [1].each { :nested.shout } }
      :outside.shout
      [1].each { :b.shout }
    RUBY

    expect(result[:errors]).to eq([[4, "call.undefined-method"], [5, "call.undefined-method"]])
  end

  # CRuby defines a `def` written in the block with the block's cref, and a class body's cref inherits the outer
  # one's refinements, so both see the declared modules.
  it "carries the declared refinements into a def and a class body written in the block" do
    result = run_analysis(<<~RUBY, plugin_class(entry))
      build do
        def helper = :a.shout
        class Nested
          :b.shout
        end
      end
      def outside = :c.shout
    RUBY

    expect(result[:errors]).to eq([[7, "call.undefined-method"]])
  end

  it "keeps reporting both lines without `refinements:`" do
    result = run_analysis(<<~RUBY, plugin_class(entry(refinements: [])))
      build { :authors[:age] }
      build { :a.shout }
    RUBY

    expect(result[:errors]).to eq([[1, "call.argument-type-mismatch"], [2, "call.undefined-method"]])
  end

  # An unknown module refines nothing Rigor can see: no silencing, no diagnostic.
  it "silences nothing for a declared module that refines nothing" do
    result = run_analysis(<<~RUBY, plugin_class(entry(refinements: ["NoSuchSyntax"])))
      build { :a.shout }
    RUBY

    expect(result[:errors]).to eq([[1, "call.undefined-method"]])
  end

  # ADR-121 WD7 — a declared module is the plugin's declaration, not code Rigor failed to read, so it is never
  # opaque: with a lexical `using` in the file, the declared module nothing declares still silences nothing.
  it "silences nothing for a declared module that refines nothing, in a file with a lexical `using`" do
    result = run_analysis(<<~RUBY, plugin_class(entry(refinements: ["NoSuchSyntax"])))
      module Other; refine(Integer) { def zz = 1 }; end
      using Other
      build { :a.shout }
    RUBY

    expect(result[:errors]).to eq([[3, "call.undefined-method"]])
  end

  # `self_type: :lexical` — `block.refined(M).call` runs the block where it was written, with the caller's `self`.
  it "keeps the caller's self for a `:lexical` entry" do
    lexical = entry(method_names: [:run_lexical], self_type: :lexical)
    result = run_analysis(<<~RUBY, plugin_class(lexical))
      class Caller
        def go
          run_lexical do
            dump_type(self)
            :a.shout
          end
        end
      end
    RUBY

    expect(result).to eq(errors: [], types: ["Caller"])
  end

  # Issue #1717 — a `:lexical` block copies the caller's `self`. Inside a block whose own `self` is unknown that is the
  # enclosing method's guess, so an explicit `self.m` in it stays unchecked, as it is in the enclosing block, whatever
  # the receiver the call is matched on.
  it "keeps a `:lexical` block's self unknown where the caller's is" do
    lexical = entry(receiver_constraint: "Lib", method_names: [:run_lexical], self_type: :lexical)
    sig = <<~RBS
      class Caller
        def go: () -> void
      end
      class Lib
        def run_lexical: () { () -> untyped } -> untyped
      end
      module Registry
        def self.add: (Symbol) { (untyped) -> untyped } -> nil
      end
    RBS
    result = run_analysis(<<~RUBY, plugin_class(lexical), sig: sig)
      class Caller
        def go
          self.direct_miss
          Registry.add(:x) do
            self.opaque_miss
            Lib.new.run_lexical { self.lexical_miss }
          end
          Lib.new.run_lexical { self.known_miss }
        end
      end
    RUBY

    expect(result[:errors]).to eq([[3, "call.undefined-method"], [8, "call.undefined-method"]])
  end
end
