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
  def run_analysis(source, plugin)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "lib.rb"), library)
      File.write(File.join(dir, "app.rb"), %(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => ["rigor-refinedtest"])
      )
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
end
