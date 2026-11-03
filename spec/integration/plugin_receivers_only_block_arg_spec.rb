# frozen_string_literal: true

# #2717 — a `dynamic_return` rule declared with `receivers:` and no `methods:` gate is not screened by the name
# gate, so the engine offers it every call on its receiver kind, and some of those calls do not dispatch with a
# `Prism::CallNode`. The engine passes four families of node as `call_node`:
#
# - the compound writes (`x.attr op= v`, `x.attr ||= v`, `x.attr &&= v`, and the `x[i]` forms), through
#   `ExpressionTyper#attribute_compound_read_type` and `#index_read_dispatch`;
# - the `&:symbol` block argument, through `ExpressionTyper#symbol_block_return_type` (an Array element) and
#   `#apply_hash_block` (a Hash pair).
#
# Each example below drives one form and pins the exact set of node classes the rule is offered, so a rule author
# knows the plugin-facing `call_node` is the union in sig/rigor/plugin/base.rbs. The engine is deliberately
# unchanged: the contract is pinned here, and a rule that reads a `CallNode`-only member guards in the plugin.
#
# The fixture is an inline plugin plus a hand-written RBS, so the spec pins the ENGINE contract rather than a
# bundled plugin's rules.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "the nodes a receivers-only dynamic_return rule is offered (#2717)" do
  let(:widget_rbs) do
    <<~RBS
      class Widget
        attr_accessor price: Integer
        def []: (Integer) -> Integer
        def []=: (Integer, Integer) -> Integer
      end
    RBS
  end

  # Typed receivers for every form, so each dispatch reaches the rule's receiver gate.
  let(:prelude) { "w = Widget.new\nxs = [Widget.new]\nh = { a: Widget.new }\n" }

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
        guarded_run(
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil, plugin_requirer: requirer
          )
        )
      end
    end
  end

  # The distinct node classes the rule was offered for one form, in first-seen order.
  def offered(form)
    seen = []
    run_analysis(prelude + form + "\n", seen)
    seen.uniq
  end

  describe "the &:symbol block argument" do
    it "is offered a Prism::BlockArgumentNode for an Array element: `xs.map(&:price)`" do
      expect(offered("xs.map(&:price)")).to contain_exactly(Prism::BlockArgumentNode)
    end

    it "is offered a Prism::BlockArgumentNode for a Hash pair: `h.transform_values(&:price)`" do
      expect(offered("h.transform_values(&:price)")).to contain_exactly(Prism::BlockArgumentNode)
    end
  end

  describe "a compound attribute write" do
    it "is offered a Prism::CallOperatorWriteNode for `w.price += 1`" do
      expect(offered("w.price += 1")).to contain_exactly(Prism::CallOperatorWriteNode)
    end

    it "is offered a Prism::CallOrWriteNode for `w.price ||= 1`" do
      expect(offered("w.price ||= 1")).to contain_exactly(Prism::CallOrWriteNode)
    end

    it "is offered a Prism::CallAndWriteNode for `w.price &&= 1`" do
      expect(offered("w.price &&= 1")).to contain_exactly(Prism::CallAndWriteNode)
    end
  end

  describe "a compound index write" do
    it "is offered a Prism::IndexOperatorWriteNode for `w[0] += 1`" do
      expect(offered("w[0] += 1")).to contain_exactly(Prism::IndexOperatorWriteNode)
    end

    it "is offered a Prism::IndexOrWriteNode for `w[0] ||= 1`" do
      expect(offered("w[0] ||= 1")).to contain_exactly(Prism::IndexOrWriteNode)
    end

    it "is offered a Prism::IndexAndWriteNode for `w[0] &&= 1`" do
      expect(offered("w[0] &&= 1")).to contain_exactly(Prism::IndexAndWriteNode)
    end
  end

  describe "an ordinary call" do
    it "is offered a Prism::CallNode for a direct `w.price` read" do
      expect(offered("w.price")).to contain_exactly(Prism::CallNode)
    end
  end
end
