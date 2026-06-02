# frozen_string_literal: true

require "spec_helper"

# Top-level named plugin class for the ADR-25 `#signature_paths`
# tests — resolution needs `Object.const_source_location`, which
# only resolves a named constant. Defined here so the file is
# self-contained under `parallel_test`.
class RigorPluginBaseSpecSigPlugin < Rigor::Plugin::Base
  manifest(id: "base-spec-sig", version: "0.0.1", signature_paths: ["sig"])
end

RSpec.describe Rigor::Plugin::Base do
  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
  end

  describe ".manifest" do
    it "stores a manifest declared at class definition" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "1.2.3", description: "demo plugin")
      end

      expect(klass.manifest).to be_a(Rigor::Plugin::Manifest)
      expect(klass.manifest.id).to eq("demo")
      expect(klass.manifest.description).to eq("demo plugin")
    end

    it "raises when accessed without a prior declaration" do
      klass = Class.new(described_class)
      expect { klass.manifest }.to raise_error(ArgumentError, /did not declare a manifest/)
    end
  end

  describe "#initialize" do
    it "stores the injected services and frozen config" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end

      plugin = klass.new(services: services, config: { "k" => 1 })
      expect(plugin.services).to eq(services)
      expect(plugin.config).to eq({ "k" => 1 })
      expect(plugin.config).to be_frozen
    end

    it "delegates `manifest` to the class" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end
      plugin = klass.new(services: services)
      expect(plugin.manifest).to eq(klass.manifest)
    end

    it "merges manifest config_schema defaults under the user config (ADR-40)" do
      klass = Class.new(described_class) do
        manifest(
          id: "demo", version: "0.1.0",
          config_schema: {
            "dsl_method" => { kind: :string, default: "state_machine" },
            "state_method" => { kind: :string, default: "state" }
          }
        )
      end

      plugin = klass.new(services: services, config: { "state_method" => "phase" })
      expect(plugin.config).to eq({ "dsl_method" => "state_machine", "state_method" => "phase" })
      expect(plugin.config).to be_frozen
    end
  end

  describe "#signature_paths (ADR-25)" do
    it "returns [] when the manifest declares no signature_paths" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end
      expect(klass.new(services: services).signature_paths).to eq([])
    end

    it "resolves declared paths against the plugin gem root" do
      plugin = RigorPluginBaseSpecSigPlugin.new(services: services)
      # The class is defined in this spec file (no `/lib/` segment),
      # so the gem root falls back to the file's directory.
      expect(plugin.signature_paths).to eq([File.expand_path("sig", __dir__)])
    end

    it "returns [] for an anonymous class even when paths are declared" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0", signature_paths: ["sig"])
      end
      expect(klass.new(services: services).signature_paths).to eq([])
    end
  end

  describe "#init" do
    it "is a no-op by default" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end
      plugin = klass.new(services: services)
      expect(plugin.init(services)).to be_nil
    end

    it "can be overridden by subclasses" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")

        attr_reader :captured

        def init(services)
          @captured = services.reflection
        end
      end

      plugin = klass.new(services: services)
      plugin.init(services)
      expect(plugin.captured).to eq(Rigor::Reflection)
    end
  end

  describe "#glob_descriptor" do
    let(:plugin_class) do
      Class.new(described_class) do
        manifest(id: "glob-demo", version: "0.1.0")
      end
    end

    let(:plugin) { plugin_class.new(services: services) }

    it "returns FileEntry rows with :digest comparator for every matching file" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "a.rb"), "puts :a\n")
        File.write(File.join(dir, "lib", "b.rb"), "puts :b\n")
        File.write(File.join(dir, "lib", "ignored.txt"), "not ruby\n")

        descriptor = plugin.glob_descriptor([File.join(dir, "lib")], "**/*.rb")

        paths = descriptor.files.map(&:path).map { |p| File.basename(p) }
        expect(paths).to contain_exactly("a.rb", "b.rb")
        expect(descriptor.files.map(&:comparator).uniq).to eq([:digest])
      end
    end

    it "returns content-keyed entries so the cache key differs across content changes" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        path = File.join(dir, "lib", "x.rb")

        File.write(path, "puts :first\n")
        before = plugin.glob_descriptor([File.join(dir, "lib")], "**/*.rb")

        File.write(path, "puts :second\n")
        after = plugin.glob_descriptor([File.join(dir, "lib")], "**/*.rb")

        expect(before).not_to eq(after)
      end
    end

    it "differs when files are added or removed from the matched glob" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "a.rb"), "puts :a\n")

        before = plugin.glob_descriptor([File.join(dir, "lib")], "**/*.rb")

        File.write(File.join(dir, "lib", "b.rb"), "puts :b\n")
        after = plugin.glob_descriptor([File.join(dir, "lib")], "**/*.rb")

        expect(before).not_to eq(after)
      end
    end

    it "returns an empty descriptor when no roots exist on disk" do
      descriptor = plugin.glob_descriptor(["/definitely/does/not/exist"], "**/*.rb")
      expect(descriptor.files).to be_empty
    end

    it "unions multiple glob patterns under each root" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        File.write(File.join(dir, "a.rb"), "")
        File.write(File.join(dir, "b.erb"), "")
        File.write(File.join(dir, "c.txt"), "")

        descriptor = plugin.glob_descriptor([dir], "**/*.rb", "**/*.erb")
        names = descriptor.files.map(&:path).map { |p| File.basename(p) }
        expect(names).to contain_exactly("a.rb", "b.erb")
      end
    end

    it "skips directories (FileEntry needs file content)" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "sub"))
        File.write(File.join(dir, "a.rb"), "")
        # `**/*` matches both `sub` and `a.rb`; only `a.rb` should
        # appear in the descriptor.
        descriptor = plugin.glob_descriptor([dir], "**/*")
        names = descriptor.files.map(&:path).map { |p| File.basename(p) }
        expect(names).to contain_exactly("a.rb")
      end
    end
  end

  describe ".node_rule / #node_rule_diagnostics (ADR-37)" do
    let(:rule_plugin) do
      Class.new(described_class) do
        manifest(id: "noderule-demo", version: "0.1.0")
        node_rule Prism::CallNode do |node, _scope, path|
          next [] unless node.name == :flagme

          [diagnostic(node, path: path, message: "flagged #{node.name}", rule: "flagged")]
        end
      end
    end

    it "records declared node rules in declaration order" do
      expect(rule_plugin.node_rules.map { |r| r[:node_type] }).to eq([Prism::CallNode])
    end

    it "rejects a node_type that is not a Prism::Node subclass" do
      expect do
        Class.new(described_class) do
          manifest(id: "bad-noderule", version: "0.1.0")
          node_rule(String) { [] }
        end
      end.to raise_error(ArgumentError, /Prism::Node subclass/)
    end

    it "requires a block" do
      expect do
        Class.new(described_class) do
          manifest(id: "blockless-noderule", version: "0.1.0")
          node_rule(Prism::CallNode)
        end
      end.to raise_error(ArgumentError, /requires a block/)
    end

    it "owns the walk and fires matching rules for every reachable node" do
      plugin = rule_plugin.new(services: services)
      root = Prism.parse("flagme\nother\nflagme").value
      diags = plugin.node_rule_diagnostics(path: "demo.rb", scope: Rigor::Scope.empty, root: root)
      expect(diags.map(&:message)).to eq(["flagged flagme", "flagged flagme"])
      expect(diags.map(&:rule)).to all(eq("flagged"))
      expect(diags.first.column).to be > 0
    end

    it "is a zero-cost no-op for a plugin that declares no node rules" do
      plugin = Class.new(described_class) { manifest(id: "none", version: "0.1.0") }.new(services: services)
      root = Prism.parse("flagme").value
      expect(plugin.node_rule_diagnostics(path: "d.rb", scope: Rigor::Scope.empty, root: root)).to eq([])
    end

    it "builds node_file_context per file and threads it as the rule's 4th argument" do
      klass = Class.new(described_class) do
        manifest(id: "twopass", version: "0.1.0")
        node_file_context do |root, _scope|
          root.statements.body.size
        end
        node_rule Prism::CallNode do |node, _scope, path, count|
          [diagnostic(node, path: path, message: "count=#{count}", rule: "c")]
        end
      end

      plugin = klass.new(services: services)
      root = Prism.parse("foo\nbar").value
      diags = plugin.node_rule_diagnostics(path: "d.rb", scope: Rigor::Scope.empty, root: root)
      # Both CallNodes (foo, bar) see the same file context (statement
      # count = 2), proving it was built before the walk and threaded.
      expect(diags.map(&:message)).to eq(["count=2", "count=2"])
    end

    it "node_file_context requires a block" do
      expect do
        Class.new(described_class) do
          manifest(id: "ctxless", version: "0.1.0")
          node_file_context
        end
      end.to raise_error(ArgumentError, /requires a block/)
    end

    it "threads a NodeContext (5th arg) with the node's lexical ancestors" do
      klass = Class.new(described_class) do
        manifest(id: "ctx", version: "0.1.0")
        node_rule Prism::CallNode do |node, _scope, path, _fc, context|
          next [] unless node.name == :flagme

          [diagnostic(node, path: path, message: "in=#{context.enclosing_def&.name}", rule: "c")]
        end
      end
      plugin = klass.new(services: services)
      root = Prism.parse("def outer\n  flagme\nend\nflagme").value
      diags = plugin.node_rule_diagnostics(path: "d.rb", scope: Rigor::Scope.empty, root: root)
      # First flagme is inside `outer`; second is top-level (no def).
      expect(diags.map(&:message)).to eq(["in=outer", "in="])
    end
  end

  describe "#diagnostic" do
    let(:plugin) do
      Class.new(described_class) { manifest(id: "demo", version: "0.1.0") }.new(services: services)
    end
    let(:node) { Prism.parse("foo(:bar)").value.statements.body.first }

    it "builds a Diagnostic positioned at the node with the 1-based column convention" do
      diag = plugin.diagnostic(node, path: "demo.rb", message: "boom", rule: "x")
      expect(diag).to be_a(Rigor::Analysis::Diagnostic)
      expect(diag.path).to eq("demo.rb")
      expect(diag.line).to eq(node.location.start_line)
      expect(diag.column).to eq(node.location.start_column + 1)
      expect(diag.message).to eq("boom")
      expect(diag.rule).to eq("x")
    end

    it "defaults severity to :error" do
      expect(plugin.diagnostic(node, path: "demo.rb", message: "m").severity).to eq(:error)
    end

    it "points at an explicit location override when given (message_loc idiom)" do
      diag = plugin.diagnostic(node, path: "demo.rb", message: "m", location: node.message_loc)
      expect(diag.line).to eq(node.message_loc.start_line)
      expect(diag.column).to eq(node.message_loc.start_column + 1)
    end
  end

  describe ".dynamic_return / #dynamic_return_type (ADR-37 slice 2)" do
    let(:plugin) do
      Class.new(described_class) do
        manifest(id: "dr", version: "0.1.0")
        dynamic_return receivers: ["Foo"] do |call_node, _scope|
          next nil unless call_node.name == :bar

          Rigor::Type::Combinator.nominal_of("Baz")
        end
      end.new(services: services)
    end

    def call(source) = Prism.parse(source).value.statements.body.first

    it "returns the contributed type for a matching receiver class + method" do
      type = plugin.dynamic_return_type(
        call_node: call("x.bar"), scope: Rigor::Scope.empty,
        receiver_type: Rigor::Type::Combinator.nominal_of("Foo")
      )
      expect(type).to eq(Rigor::Type::Combinator.nominal_of("Baz"))
    end

    it "declines for a non-matching receiver class" do
      type = plugin.dynamic_return_type(
        call_node: call("x.bar"), scope: Rigor::Scope.empty,
        receiver_type: Rigor::Type::Combinator.nominal_of("Other")
      )
      expect(type).to be_nil
    end

    it "declines when the block returns nil (in-block method gate)" do
      type = plugin.dynamic_return_type(
        call_node: call("x.other"), scope: Rigor::Scope.empty,
        receiver_type: Rigor::Type::Combinator.nominal_of("Foo")
      )
      expect(type).to be_nil
    end

    it "rejects an empty receivers: list" do
      expect do
        Class.new(described_class) do
          manifest(id: "bad-dr", version: "0.1.0")
          dynamic_return(receivers: []) { nil }
        end
      end.to raise_error(ArgumentError, /non-empty Array/)
    end
  end

  describe ".type_specifier / #type_specifier_facts (ADR-37 slice 2)" do
    let(:plugin) do
      Class.new(described_class) do
        manifest(id: "ts", version: "0.1.0")
        type_specifier methods: [:assert_thing] do |_call_node, _scope|
          %i[fact_a fact_b]
        end
      end.new(services: services)
    end

    def call(source) = Prism.parse(source).value.statements.body.first

    it "returns facts for a matching method name" do
      facts = plugin.type_specifier_facts(call_node: call("assert_thing(x)"), scope: Rigor::Scope.empty)
      expect(facts).to eq(%i[fact_a fact_b])
    end

    it "returns [] for a non-matching method name" do
      expect(plugin.type_specifier_facts(call_node: call("other(x)"), scope: Rigor::Scope.empty)).to eq([])
    end

    it "rejects an empty methods: list" do
      expect do
        Class.new(described_class) do
          manifest(id: "bad-ts", version: "0.1.0")
          type_specifier(methods: []) { nil }
        end
      end.to raise_error(ArgumentError, /non-empty Array/)
    end
  end
end
