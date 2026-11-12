# frozen_string_literal: true

# #2764 — `dynamic_return_rule_applies?` read `call_node.name` for its `methods:` / `file_methods:`
# gates, but `Registry#build_name_gates` leaves a plugin name-ungated when ANY of its rules is
# receivers-only, has a callable `methods:`, or has `file_methods:` — and such a plugin is then
# offered the nameless nodes of #2717 (the `&:sym` BlockArgumentNode, the compound write nodes).
# The NoMethodError was absorbed by `dynamic_return_type`'s rescue, which nil-ed the plugin's
# whole answer and silently skipped every rule declared after the name-gated one.
#
# The fixture is an inline plugin plus a hand-written RBS, so the spec pins the ENGINE contract
# rather than a bundled plugin's rules.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "the dynamic_return name gate over nameless nodes (#2764)" do
  let(:widget_rbs) do
    <<~RBS
      class Widget
        attr_accessor price: Integer
        def []: (Integer) -> Integer
        def []=: (Integer, Integer) -> Integer
      end
    RBS
  end

  # Typed receivers for every form, so each dispatch reaches the rules' receiver gates.
  let(:prelude) { "w = Widget.new\nxs = [Widget.new]\nh = { a: Widget.new }\n" }

  # Every node shape #2717 pins as reaching an ungated plugin, plus an ordinary `w.price` read so
  # the name-gated rules have a CallNode to fire on.
  let(:nameless_forms) do
    <<~RUBY
      xs.map(&:price)
      h.transform_values(&:price)
      w.price += 1
      w.price ||= 1
      w.price &&= 1
      w[0] += 1
      w[0] ||= 1
      w[0] &&= 1
      w.price
    RUBY
  end

  # `seen` maps a rule label to the node classes its block was offered; the blocks answer nil so
  # the RBS still types the calls and the spec observes only what the engine hands the rules.
  def plugin_class(seen, &)
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "nametest", version: "0.1.0")
      class_exec(seen, &)
    end
    stub_const("FakeNameGatePlugin", klass)
    klass
  end

  def run_analysis(source, klass)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "widget.rbs"), widget_rbs)
      File.write(File.join(dir, "demo.rb"), "#{prelude}#{source}")
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "signature_paths" => [File.join(dir, "sig")],
          "plugins" => ["rigor-nametest"]
        )
      )
      Dir.chdir(dir) do
        guarded_run(
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil, plugin_requirer: requirer(klass)
          )
        )
      end
    end
  end

  def requirer(klass)
    lambda do |_name|
      Rigor::Plugin.register(klass)
      true
    end
  end

  def seen_hash
    Hash.new { |hash, key| hash[key] = [] }
  end

  # The node classes a name-gated rule's block was offered must all be CallNodes — the gate
  # declines the nameless nodes rather than raising.
  def expect_only_call_nodes(seen, label)
    expect(seen[label].uniq - [Prism::CallNode]).to be_empty
    expect(seen[label]).to include(Prism::CallNode)
  end

  describe "a callable methods: rule declared before a receivers-only rule" do
    it "still offers the &:sym BlockArgumentNode to the receivers-only rule" do
      seen = seen_hash
      klass = plugin_class(seen) do |seen_nodes|
        dynamic_return methods: -> { [:price] } do |call_node, _scope|
          seen_nodes[:name_gated] << call_node.class
          nil
        end

        dynamic_return receivers: ["Widget"] do |call_node, _scope|
          seen_nodes[:receivers_only] << call_node.class
          nil
        end
      end

      run_analysis(nameless_forms, klass)

      expect(seen[:receivers_only]).to include(Prism::BlockArgumentNode)
      expect_only_call_nodes(seen, :name_gated)
    end
  end

  describe "a static methods: Array rule declared before a receivers-only rule" do
    it "declines every nameless node instead of raising" do
      seen = seen_hash
      klass = plugin_class(seen) do |seen_nodes|
        dynamic_return methods: [:price] do |call_node, _scope|
          seen_nodes[:name_gated] << call_node.class
          nil
        end

        dynamic_return receivers: ["Widget"] do |call_node, _scope|
          seen_nodes[:receivers_only] << call_node.class
          nil
        end
      end

      run_analysis(nameless_forms, klass)

      expect(seen[:receivers_only]).to include(
        Prism::BlockArgumentNode, Prism::CallOperatorWriteNode, Prism::IndexOrWriteNode
      )
      expect_only_call_nodes(seen, :name_gated)
    end
  end

  describe "a file_methods: callable rule declared before a receivers-only rule" do
    it "declines every nameless node instead of raising" do
      seen = seen_hash
      klass = plugin_class(seen) do |seen_nodes|
        dynamic_return file_methods: ->(_path) { [:price] }, receivers: ["Widget"] do |call_node, _scope|
          seen_nodes[:name_gated] << call_node.class
          nil
        end

        dynamic_return receivers: ["Widget"] do |call_node, _scope|
          seen_nodes[:receivers_only] << call_node.class
          nil
        end
      end

      run_analysis(nameless_forms, klass)

      expect(seen[:receivers_only]).to include(
        Prism::BlockArgumentNode, Prism::CallOperatorWriteNode, Prism::IndexOrWriteNode
      )
      expect_only_call_nodes(seen, :name_gated)
    end
  end
end
