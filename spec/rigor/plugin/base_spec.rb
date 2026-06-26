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

  # Private since ADR-60 WD3 — `producer watch:` is the declared way to
  # cover a producer's glob; this remains its building block, exercised
  # here via `send`.
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

        descriptor = plugin.send(:glob_descriptor, [File.join(dir, "lib")], "**/*.rb")

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
        before = plugin.send(:glob_descriptor, [File.join(dir, "lib")], "**/*.rb")

        File.write(path, "puts :second\n")
        after = plugin.send(:glob_descriptor, [File.join(dir, "lib")], "**/*.rb")

        expect(before).not_to eq(after)
      end
    end

    it "differs when files are added or removed from the matched glob" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "a.rb"), "puts :a\n")

        before = plugin.send(:glob_descriptor, [File.join(dir, "lib")], "**/*.rb")

        File.write(File.join(dir, "lib", "b.rb"), "puts :b\n")
        after = plugin.send(:glob_descriptor, [File.join(dir, "lib")], "**/*.rb")

        expect(before).not_to eq(after)
      end
    end

    it "returns an empty descriptor when no roots exist on disk" do
      descriptor = plugin.send(:glob_descriptor, ["/definitely/does/not/exist"], "**/*.rb")
      expect(descriptor.files).to be_empty
    end

    it "unions multiple glob patterns under each root" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        File.write(File.join(dir, "a.rb"), "")
        File.write(File.join(dir, "b.erb"), "")
        File.write(File.join(dir, "c.txt"), "")

        descriptor = plugin.send(:glob_descriptor, [dir], "**/*.rb", "**/*.erb")
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
        descriptor = plugin.send(:glob_descriptor, [dir], "**/*")
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

  describe "#diagnostics_for (ADR-60 WD4)" do
    let(:plugin) do
      Class.new(described_class) { manifest(id: "demo", version: "0.1.0") }.new(services: services)
    end
    let(:node) { Prism.parse("foo(:bar)").value.statements.body.first }
    let(:violation) { Struct.new(:node, :message, :severity, :rule, :location, keyword_init: true) }

    it "maps duck-typed violations through #diagnostic" do
      violations = [
        violation.new(node: node, message: "boom", severity: :warning, rule: "demo.x"),
        violation.new(node: node, message: "bang", rule: "demo.y")
      ]
      diags = plugin.diagnostics_for(violations, path: "demo.rb")
      expect(diags.map(&:message)).to eq(%w[boom bang])
      expect(diags.map(&:severity)).to eq(%i[warning error])
      expect(diags.map(&:rule)).to eq(%w[demo.x demo.y])
      expect(diags).to all(be_a(Rigor::Analysis::Diagnostic))
    end

    it "falls back to the shared node: argument when a violation carries no node" do
      bare = Struct.new(:message, keyword_init: true)
      diags = plugin.diagnostics_for([bare.new(message: "m")], path: "demo.rb", node: node)
      expect(diags.first.line).to eq(node.location.start_line)
    end

    it "honours a per-violation location override" do
      diags = plugin.diagnostics_for(
        [violation.new(node: node, message: "m", location: node.message_loc)], path: "demo.rb"
      )
      expect(diags.first.column).to eq(node.message_loc.start_column + 1)
    end

    it "returns [] for nil / empty input" do
      expect(plugin.diagnostics_for(nil, path: "demo.rb")).to eq([])
      expect(plugin.diagnostics_for([], path: "demo.rb")).to eq([])
    end
  end

  describe "#read_fact (ADR-60 WD4)" do
    let(:fact_store) { Rigor::Plugin::FactStore.new }
    let(:services) do
      Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: Rigor::Configuration.new,
        fact_store: fact_store
      )
    end
    let(:plugin) do
      Class.new(described_class) { manifest(id: "demo", version: "0.1.0") }.new(services: services)
    end

    it "reads a published fact" do
      fact_store.publish(plugin_id: "other", name: :index, value: { a: 1 })
      expect(plugin.read_fact(plugin_id: "other", name: :index)).to eq({ a: 1 })
    end

    it "returns nil for an unpublished fact and memoises the nil (no re-read)" do
      reads = 0
      allow(fact_store).to receive(:read).and_wrap_original do |orig, **kw|
        reads += 1
        orig.call(**kw)
      end
      expect(plugin.read_fact(plugin_id: "other", name: :missing)).to be_nil
      expect(plugin.read_fact(plugin_id: "other", name: :missing)).to be_nil
      expect(reads).to eq(1)
    end

    it "coerces String/Symbol plugin_id and name to the canonical channel" do
      fact_store.publish(plugin_id: "other", name: :index, value: 42)
      expect(plugin.read_fact(plugin_id: :other, name: "index")).to eq(42)
    end
  end

  describe "#producer_value / #producer_error (ADR-60 WD4)" do
    let(:plugin) do
      Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
        producer(:ok) { |_params| 7 }
        producer(:boom) { |_params| raise "broken project file" }
      end.new(services: services)
    end

    it "returns the producer value and memoises it (--no-cache path runs once)" do
      calls = 0
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end
      counter = -> { calls += 1 }
      klass.producer(:count) { |_params| counter.call }
      inst = klass.new(services: services)
      inst.producer_value(:count)
      inst.producer_value(:count)
      expect(calls).to eq(1)
    end

    it "rescues a raising producer to nil and records the error" do
      expect(plugin.producer_value(:boom)).to be_nil
      expect(plugin.producer_error(:boom)).to be_a(StandardError)
      expect(plugin.producer_error(:boom).message).to eq("broken project file")
    end

    it "reports no error for a producer that has not been run or succeeded" do
      expect(plugin.producer_error(:ok)).to be_nil
      expect(plugin.producer_value(:ok)).to eq(7)
      expect(plugin.producer_error(:ok)).to be_nil
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

    describe "optional methods: gate" do
      let(:plugin_with_methods) do
        Class.new(described_class) do
          manifest(id: "dr-methods", version: "0.1.0")
          dynamic_return receivers: ["Foo"], methods: %i[unwrap unwrap!] do |_call_node, _scope|
            Rigor::Type::Combinator.nominal_of("Bar")
          end
        end.new(services: services)
      end

      it "fires for a declared method name" do
        type = plugin_with_methods.dynamic_return_type(
          call_node: call("x.unwrap"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.nominal_of("Foo")
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Bar"))
      end

      it "fires for each declared method name" do
        type = plugin_with_methods.dynamic_return_type(
          call_node: call("x.unwrap!"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.nominal_of("Foo")
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Bar"))
      end

      it "declines for an undeclared method name (even on a matching receiver)" do
        type = plugin_with_methods.dynamic_return_type(
          call_node: call("x.other"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.nominal_of("Foo")
        )
        expect(type).to be_nil
      end

      it "still declines for a non-matching receiver even if method matches" do
        type = plugin_with_methods.dynamic_return_type(
          call_node: call("x.unwrap"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.nominal_of("Other")
        )
        expect(type).to be_nil
      end

      it "accepts String method names and normalises them to symbols" do
        plugin = Class.new(described_class) do
          manifest(id: "dr-str", version: "0.1.0")
          dynamic_return receivers: ["Foo"], methods: %w[fetch] do |_call_node, _scope|
            Rigor::Type::Combinator.nominal_of("Val")
          end
        end.new(services: services)
        type = plugin.dynamic_return_type(
          call_node: call("x.fetch"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.nominal_of("Foo")
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Val"))
      end

      it "rejects an empty methods: list" do
        expect do
          Class.new(described_class) do
            manifest(id: "bad-dm", version: "0.1.0")
            dynamic_return(receivers: ["Foo"], methods: []) { nil }
          end
        end.to raise_error(ArgumentError, /methods/)
      end

      it "rejects non-symbol/string entries in methods:" do
        expect do
          Class.new(described_class) do
            manifest(id: "bad-dm2", version: "0.1.0")
            dynamic_return(receivers: ["Foo"], methods: [123]) { nil }
          end
        end.to raise_error(ArgumentError, /methods/)
      end
    end

    describe "receiver-less (methods-only) rule (ADR-52 WD2)" do
      let(:plugin_methods_only) do
        Class.new(described_class) do
          manifest(id: "dr-mo", version: "0.1.0")
          dynamic_return methods: %i[kilometers per_hour] do |call_node, _scope|
            next nil unless call_node.name == :kilometers

            Rigor::Type::Combinator.nominal_of("Distance")
          end
        end.new(services: services)
      end

      it "fires on the method name regardless of the receiver carrier shape" do
        # A receiver carrier with no nominal class (untyped/Dynamic) —
        # a receiver-gated rule could not match it, but a methods-only
        # rule reads the shape inside its own block.
        type = plugin_methods_only.dynamic_return_type(
          call_node: call("100.kilometers"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.untyped
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Distance"))
      end

      it "declines for an undeclared method name" do
        type = plugin_methods_only.dynamic_return_type(
          call_node: call("100.megaparsecs"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.untyped
        )
        expect(type).to be_nil
      end

      it "rejects a rule gated on neither receivers: nor methods:" do
        expect do
          Class.new(described_class) do
            manifest(id: "bad-ungated", version: "0.1.0")
            dynamic_return { nil }
          end
        end.to raise_error(ArgumentError, /receivers:, methods:, or file_methods:/)
      end

      it "treats an empty methods: list with no receivers: as ungated and rejects it" do
        expect do
          Class.new(described_class) do
            manifest(id: "bad-empty", version: "0.1.0")
            dynamic_return(methods: []) { nil }
          end
        end.to raise_error(ArgumentError, /receivers:, methods:, or file_methods:/)
      end
    end

    describe "run-time receivers: callable (ADR-52 slice 3)" do
      let(:plugin_runtime) do
        Class.new(described_class) do
          manifest(id: "dr-rt", version: "0.1.0")
          # The set the callable returns is built at run time — here a
          # mutable accumulator the test fills after the class is defined,
          # standing in for a `#prepare`-built index.
          def model_names = @model_names ||= []

          dynamic_return receivers: -> { model_names } do |_call_node, _scope|
            Rigor::Type::Combinator.nominal_of("Resolved")
          end
        end.new(services: services)
      end

      def call(source) = Prism.parse(source).value.statements.body.first

      it "resolves the callable against the instance and fires for a member of the run-time set" do
        plugin_runtime.model_names << "Post"
        type = plugin_runtime.dynamic_return_type(
          call_node: call("x.recent"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.nominal_of("Post")
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Resolved"))
      end

      it "declines for a receiver outside the run-time set" do
        plugin_runtime.model_names << "Post"
        type = plugin_runtime.dynamic_return_type(
          call_node: call("x.recent"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.nominal_of("Comment")
        )
        expect(type).to be_nil
      end

      it "memoises the resolved set — the callable is evaluated once per rule" do
        calls = 0
        klass = Class.new(described_class) do
          manifest(id: "dr-rt-memo", version: "0.1.0")
          define_method(:bump) { calls += 1 }
          dynamic_return receivers: -> { bump; ["Post"] } do |_call_node, _scope| # rubocop:disable Style/Semicolon
            Rigor::Type::Combinator.nominal_of("Resolved")
          end
        end
        plugin = klass.new(services: services)
        2.times do
          plugin.dynamic_return_type(
            call_node: call("x.recent"), scope: Rigor::Scope.empty,
            receiver_type: Rigor::Type::Combinator.nominal_of("Post")
          )
        end
        expect(calls).to eq(1)
      end

      it "accepts a callable at declaration without a static receivers: array" do
        expect do
          Class.new(described_class) do
            manifest(id: "dr-rt-ok", version: "0.1.0")
            dynamic_return(receivers: -> { [] }) { nil }
          end
        end.not_to raise_error
      end
    end

    describe "run-time methods: callable (ADR-52 slice 4)" do
      let(:plugin_runtime_methods) do
        Class.new(described_class) do
          manifest(id: "dr-rtm", version: "0.1.0")
          # The method-name set is built at run time (config / a catalog).
          def recognised = @recognised ||= []

          dynamic_return methods: -> { recognised } do |call_node, _scope|
            next nil unless call_node.name == :evaluate

            Rigor::Type::Combinator.nominal_of("Resolved")
          end
        end.new(services: services)
      end

      def call(source) = Prism.parse(source).value.statements.body.first

      it "fires for a method name in the run-time set (receiver-independent)" do
        plugin_runtime_methods.recognised << :evaluate
        type = plugin_runtime_methods.dynamic_return_type(
          call_node: call("x.evaluate"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.untyped
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Resolved"))
      end

      it "declines for a method name outside the run-time set" do
        plugin_runtime_methods.recognised << :evaluate
        type = plugin_runtime_methods.dynamic_return_type(
          call_node: call("x.something_else"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.untyped
        )
        expect(type).to be_nil
      end

      it "memoises the resolved name set — the callable runs once per rule" do
        calls = 0
        klass = Class.new(described_class) do
          manifest(id: "dr-rtm-memo", version: "0.1.0")
          define_method(:bump) { calls += 1 }
          dynamic_return methods: -> { bump; [:evaluate] } do |_call_node, _scope| # rubocop:disable Style/Semicolon
            Rigor::Type::Combinator.nominal_of("Resolved")
          end
        end
        plugin = klass.new(services: services)
        2.times do
          plugin.dynamic_return_type(
            call_node: call("x.evaluate"), scope: Rigor::Scope.empty,
            receiver_type: Rigor::Type::Combinator.untyped
          )
        end
        expect(calls).to eq(1)
      end

      it "accepts a callable methods: at declaration without receivers:" do
        expect do
          Class.new(described_class) do
            manifest(id: "dr-rtm-ok", version: "0.1.0")
            dynamic_return(methods: -> { [] }) { nil }
          end
        end.not_to raise_error
      end
    end

    describe "per-file file_methods: callable (ADR-52 slice 5a)" do
      let(:plugin_file_methods) do
        Class.new(described_class) do
          manifest(id: "dr-pfm", version: "0.1.0")
          # The per-file name set — here a hand-seeded path → names map;
          # in a real plugin a per-file index (rspec's LetScopeIndex).
          def names_by_path = @names_by_path ||= {}

          dynamic_return file_methods: ->(path) { names_by_path[path] } do |_call_node, _scope|
            Rigor::Type::Combinator.nominal_of("LetBound")
          end
        end.new(services: services)
      end

      def call(source) = Prism.parse(source).value.statements.body.first

      def scope_for(path) = Rigor::Scope.empty(source_path: path)

      it "fires for a name in the call site's own file set" do
        plugin_file_methods.names_by_path["/a_spec.rb"] = [:user]
        type = plugin_file_methods.dynamic_return_type(
          call_node: call("user"), scope: scope_for("/a_spec.rb"),
          receiver_type: Rigor::Type::Combinator.untyped
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("LetBound"))
      end

      it "declines for a name only listed in a different file's set" do
        plugin_file_methods.names_by_path["/a_spec.rb"] = [:user]
        type = plugin_file_methods.dynamic_return_type(
          call_node: call("user"), scope: scope_for("/b_spec.rb"),
          receiver_type: Rigor::Type::Combinator.untyped
        )
        expect(type).to be_nil
      end

      it "declines when the scope has no source path (fail-closed)" do
        plugin_file_methods.names_by_path["/a_spec.rb"] = [:user]
        type = plugin_file_methods.dynamic_return_type(
          call_node: call("user"), scope: Rigor::Scope.empty,
          receiver_type: Rigor::Type::Combinator.untyped
        )
        expect(type).to be_nil
      end

      it "memoises the resolved set per (rule, path)" do
        calls = 0
        klass = Class.new(described_class) do
          manifest(id: "dr-pfm-memo", version: "0.1.0")
          define_method(:bump) { calls += 1 }
          dynamic_return file_methods: ->(_path) { bump; [:user] } do |_call_node, _scope| # rubocop:disable Style/Semicolon
            Rigor::Type::Combinator.nominal_of("LetBound")
          end
        end
        plugin = klass.new(services: services)
        2.times do
          plugin.dynamic_return_type(
            call_node: call("user"), scope: scope_for("/a_spec.rb"),
            receiver_type: Rigor::Type::Combinator.untyped
          )
        end
        plugin.dynamic_return_type(
          call_node: call("user"), scope: scope_for("/b_spec.rb"),
          receiver_type: Rigor::Type::Combinator.untyped
        )
        expect(calls).to eq(2)
      end

      it "rejects a non-callable file_methods:" do
        expect do
          Class.new(described_class) do
            manifest(id: "bad-pfm", version: "0.1.0")
            dynamic_return(file_methods: [:user]) { nil }
          end
        end.to raise_error(ArgumentError, /must be a callable/)
      end

      it "rejects combining file_methods: with methods:" do
        expect do
          Class.new(described_class) do
            manifest(id: "bad-pfm-combo", version: "0.1.0")
            dynamic_return(file_methods: ->(_p) { [] }, methods: [:user]) { nil }
          end
        end.to raise_error(ArgumentError, /one name gate/)
      end
    end
  end

  describe ".narrowing_facts / #type_specifier_facts (ADR-37 slice 2, ADR-80)" do
    let(:plugin) do
      Class.new(described_class) do
        manifest(id: "ts", version: "0.1.0")
        narrowing_facts methods: [:assert_thing] do |_call_node, _scope|
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
          narrowing_facts(methods: []) { nil }
        end
      end.to raise_error(ArgumentError, /non-empty Array/)
    end

    # ADR-80 — `type_specifier` is the deprecating alias, removed in 0.3.0.
    describe ".type_specifier (deprecating alias)" do
      it "registers the rule identically to narrowing_facts" do
        aliased = nil
        expect do
          aliased = Class.new(described_class) do
            manifest(id: "ts-alias", version: "0.1.0")
            type_specifier methods: [:assert_thing] do |_call_node, _scope|
              %i[fact_a fact_b]
            end
          end.new(services: services)
        end.to output(/type_specifier is deprecated.*narrowing_facts/m).to_stderr
        facts = aliased.type_specifier_facts(call_node: call("assert_thing(x)"), scope: Rigor::Scope.empty)
        expect(facts).to eq(%i[fact_a fact_b])
      end
    end
  end
end
