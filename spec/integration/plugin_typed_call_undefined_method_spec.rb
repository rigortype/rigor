# frozen_string_literal: true

# Issue #653 — a call whose return type came from a plugin's `dynamic_return` MUST NOT also be reported
# `call.undefined-method` against the receiver's RBS.
#
# The plugin tier sits ABOVE `RbsDispatch` in `MethodDispatcher#resolve`, so when a plugin answers, the RBS
# never had a turn: the engine typed the site from the plugin. Reading the same receiver's RBS afterwards to
# prove the call "undefined" contradicts the type the engine itself assigned, on the same line of the same
# run. It also creates a perverse incentive — before this fix, ADDING a four-line partial `sig/` for a class
# a plugin already covered turned every covered call site into an error, so the cheapest way to a clean run
# was to delete your signatures.
#
# The fixture is deliberately plugin-agnostic (an inline `dynamic_return` plugin + a hand-written partial
# RBS) so it pins the ENGINE contract rather than any one bundled plugin's behaviour.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a plugin-typed call and call.undefined-method (#653)" do
  # Types `Frameworkish.logger` — a reader the partial RBS below deliberately does not declare. The returned
  # nominal is itself RBS-less, which is what makes the downstream `.info` call lenient.
  let(:reader_plugin) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "readertest", version: "0.1.0")

      dynamic_return methods: [:logger] do |call_node, _scope|
        receiver = call_node.receiver
        next nil unless receiver.is_a?(Prism::ConstantReadNode)
        next nil unless receiver.name == :Frameworkish

        Rigor::Type::Combinator.nominal_of("Frameworkish::Logger")
      end
    end
    stub_const("FakeReaderPlugin", klass)
    klass
  end

  # The realistic shape the issue reports: a project's own `sig/`, or a community RBS, declaring SOME of the
  # singleton surface and not the reader the plugin models.
  let(:partial_rbs) do
    <<~RBS
      module Frameworkish
        def self.env: () -> String
      end
    RBS
  end

  def run_analysis(source, plugins:)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "frameworkish.rbs"), partial_rbs)
      File.write(File.join(dir, "demo.rb"), source)
      run_configured(dir, plugins)
    end
  end

  def run_configured(dir, plugins)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => [File.join(dir, "demo.rb")],
        "signature_paths" => [File.join(dir, "sig")],
        "plugins" => plugins
      )
    )
    Dir.chdir(dir) do
      guarded_run(
        Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        )
      )
    end
  end

  def requirer
    plugin = reader_plugin
    lambda do |_name|
      Rigor::Plugin.register(plugin)
      true
    end
  end

  def rules(result) = result.diagnostics.map(&:qualified_rule)
  def dumps(result) = result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)

  it "does not fire undefined-method at the plugin-typed call site" do
    result = run_analysis(<<~RUBY, plugins: ["rigor-readertest"])
      Rigor.dump_type(Frameworkish.logger)
      Frameworkish.logger.info("x")
    RUBY
    expect(rules(result)).not_to include("call.undefined-method")
    # The must-still-RESOLVE half: a class collapsed to `Dynamic` would also produce zero diagnostics, so
    # silence alone proves nothing. The plugin's answer has to be the type at the site.
    expect(dumps(result)).to eq(["dump_type: Frameworkish::Logger"])
  end

  it "CONTROL: the same call DOES fire undefined-method without the plugin" do
    # Discriminates the example above. Without a plugin answer the partial RBS is the only source, `logger`
    # is genuinely absent from it, and the rule fires — so the silence above is the suppression working and
    # not a fixture that cannot report the rule at all.
    result = run_analysis("Frameworkish.logger.info(\"x\")\n", plugins: [])
    expect(rules(result)).to include("call.undefined-method")
  end

  it "keeps the declared reader type-checking against its RBS signature" do
    # `env` IS declared, so the RBS stays authoritative where it speaks: the site types `String` (not the
    # plugin's nominal, not `Dynamic`), and a wrong call against that signature still fires.
    result = run_analysis(<<~RUBY, plugins: ["rigor-readertest"])
      Rigor.dump_type(Frameworkish.env)
      Frameworkish.env(1)
    RUBY
    expect(dumps(result)).to eq(["dump_type: String"])
    expect(rules(result)).to include("call.wrong-arity")
  end

  it "holds inside a module body, a singleton def and a nested instance def" do
    # A class / method body starts from a FRESH scope (`StatementEvaluator#build_fresh_body_scope`), which
    # copies only some of the per-node advisory tables across. The record has to reach the check rule at
    # every nesting depth, so a body-scope construction that stopped threading it would break the
    # suppression silently — the reported repro is nested, and a top-level-only fixture would miss it.
    result = run_analysis(<<~RUBY, plugins: ["rigor-readertest"])
      module MyApp
        Rigor.dump_type(Frameworkish.logger)

        def self.probe
          Frameworkish.logger.info("x")
        end

        class Inner
          def run
            Frameworkish.logger.info("y")
          end
        end
      end
    RUBY
    expect(rules(result)).not_to include("call.undefined-method")
    expect(dumps(result)).to eq(["dump_type: Frameworkish::Logger"])
  end

  it "still fires undefined-method for a call neither the RBS nor the plugin answers" do
    # The mandatory must-still-fire half: the suppression is per CALL SITE, not per receiver class. The
    # plugin answers `logger` on this very receiver, and `nope` on the same receiver still reports.
    result = run_analysis(<<~RUBY, plugins: ["rigor-readertest"])
      Frameworkish.logger.info("x")
      Frameworkish.nope
    RUBY
    messages = result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
    expect(messages).to eq(["undefined method `nope' for singleton(Frameworkish)"])
  end
end
