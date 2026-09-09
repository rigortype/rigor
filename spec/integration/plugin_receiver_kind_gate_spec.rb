# frozen_string_literal: true

# Issue #701 — a `dynamic_return receivers:` entry names the receiver KIND. A rule written for `Widget#price`
# must not answer `Widget.price`, because since #653 a plugin's answer suppresses that call site's
# `call.undefined-method` — so an instance rule answering on the class silenced a genuine class-level miss on
# the strength of a type the plugin was never asked to produce.
#
# The fixture is deliberately plugin-agnostic (an inline `dynamic_return` plugin + a hand-written RBS that
# declares the INSTANCE method only) so it pins the ENGINE contract rather than a bundled plugin's rules.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "the dynamic_return receiver-kind gate (#701)" do
  # The RBS a project would really write for `Widget#price`: the instance method is declared, and the class
  # level is silent about `price` — which is what makes `Widget.price` a genuine miss.
  let(:widget_rbs) do
    <<~RBS
      class Widget
        def price: () -> Integer
      end
    RBS
  end

  def plugin_class(receivers)
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "kindtest", version: "0.1.0")

      dynamic_return receivers: receivers, methods: [:price] do |_call_node, _scope|
        Rigor::Type::Combinator.nominal_of("Money")
      end
    end
    # The loader reads `klass.name` to build its Blueprint, so the class needs one.
    stub_const("FakeKindPlugin", klass)
    klass
  end

  def run_analysis(source, receivers)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "widget.rbs"), widget_rbs)
      File.write(File.join(dir, "demo.rb"), source)
      run_configured(dir, receivers)
    end
  end

  def run_configured(dir, receivers)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => [File.join(dir, "demo.rb")],
        "signature_paths" => [File.join(dir, "sig")],
        "plugins" => ["rigor-kindtest"]
      )
    )
    Dir.chdir(dir) do
      guarded_run(
        Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer(receivers)
        )
      )
    end
  end

  def requirer(receivers)
    klass = plugin_class(receivers)
    lambda do |_name|
      Rigor::Plugin.register(klass)
      true
    end
  end

  def undefined_messages(result)
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  def dumps(result) = result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)

  describe "an instance rule — receivers: [\"Widget\"]" do
    it "reports the class-level miss it never modelled" do
      result = run_analysis("Widget.price\n", ["Widget"])
      expect(undefined_messages(result)).to eq(["undefined method `price' for singleton(Widget)"])
    end

    it "still answers on the instance" do
      # The must-still-answer half: a gate that declined everything would also produce the silence above.
      result = run_analysis("Rigor.dump_type(Widget.new.price)\n", ["Widget"])
      expect(dumps(result)).to eq(["dump_type: Money"])
      expect(undefined_messages(result)).to be_empty
    end
  end

  describe "a singleton rule — receivers: [\"singleton(Widget)\"]" do
    it "answers on the class object, and its answer suppresses the miss (#653)" do
      result = run_analysis("Rigor.dump_type(Widget.price)\n", ["singleton(Widget)"])
      expect(dumps(result)).to eq(["dump_type: Money"])
      expect(undefined_messages(result)).to be_empty
    end

    it "leaves the instance call to the RBS" do
      result = run_analysis("Rigor.dump_type(Widget.new.price)\n", ["singleton(Widget)"])
      expect(dumps(result)).to eq(["dump_type: Integer"])
    end
  end

  describe "a both-kinds rule — receivers: [\"Widget\", \"singleton(Widget)\"]" do
    it "answers on either receiver" do
      result = run_analysis(<<~RUBY, ["Widget", "singleton(Widget)"])
        Rigor.dump_type(Widget.price)
        Rigor.dump_type(Widget.new.price)
      RUBY
      expect(dumps(result)).to eq(["dump_type: Money", "dump_type: Money"])
      expect(undefined_messages(result)).to be_empty
    end
  end
end
