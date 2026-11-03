# frozen_string_literal: true

# #2717 — a `dynamic_return` rule declared with `receivers:` and NO `methods:` gate is consulted for every call on
# its receiver kind, including the `&:symbol` block path. There the engine dispatches with the
# `Prism::BlockArgumentNode` itself as `call_node` (`ExpressionTyper#symbol_block_return_type`), not a
# `Prism::CallNode`. This spec pins that the rule receives that node, so a rule author knows the plugin-facing
# `call_node` is a `CallNode | BlockArgumentNode` union (sig/rigor/plugin/base.rbs). The engine is deliberately
# unchanged: the contract is pinned here, and the rule's guard lives in the plugin.
#
# The fixture is an inline plugin plus a hand-written RBS, so the spec pins the ENGINE contract rather than a
# bundled plugin's rules.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a receivers-only dynamic_return rule and the &:symbol block path (#2717)" do
  let(:widget_rbs) do
    <<~RBS
      class Widget
        def price: () -> Integer
      end
    RBS
  end

  # Records the class of every `call_node` the rule is offered. The rule answers nil, so the RBS still types the
  # call and the spec observes only what the engine hands the rule.
  def plugin_class(seen)
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "blockargtest", version: "0.1.0")

      dynamic_return receivers: ["Widget"] do |call_node, _scope|
        seen << call_node.class
        nil
      end
    end
    stub_const("FakeBlockArgPlugin", klass)
    klass
  end

  def run_analysis(source, seen)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "widget.rbs"), widget_rbs)
      File.write(File.join(dir, "demo.rb"), source)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "signature_paths" => [File.join(dir, "sig")],
          "plugins" => ["rigor-blockargtest"]
        )
      )
      klass = plugin_class(seen)
      requirer = lambda do |_name|
        Rigor::Plugin.register(klass)
        true
      end
      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        ).run
      end
    end
  end

  it "offers the rule a Prism::BlockArgumentNode for `xs.map(&:price)`, not a CallNode" do
    seen = []
    run_analysis("xs = [Widget.new]\nxs.map(&:price)\n", seen)
    expect(seen).to include(Prism::BlockArgumentNode)
    expect(seen).not_to include(Prism::SymbolNode)
  end

  it "still offers the rule a Prism::CallNode for a direct `Widget#price` call" do
    seen = []
    run_analysis("Widget.new.price\n", seen)
    expect(seen).to include(Prism::CallNode)
    expect(seen).not_to include(Prism::BlockArgumentNode)
  end
end
