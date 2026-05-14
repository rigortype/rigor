# frozen_string_literal: true

RSpec.describe Rigor::Inference::MethodDispatcher do
  def dispatch(receiver:, method_name:, args: [])
    described_class.dispatch(
      receiver_type: receiver,
      method_name: method_name,
      arg_types: args
    )
  end

  def constant(value)
    Rigor::Type::Combinator.constant_of(value)
  end

  let(:dynamic_top) { Rigor::Type::Combinator.untyped }
  let(:nominal_string) { Rigor::Type::Combinator.nominal_of(String) }

  describe "#dispatch" do
    it "returns nil when the receiver is nil (implicit self not supported in Slice 2)" do
      expect(dispatch(receiver: nil, method_name: :foo)).to be_nil
    end

    it "returns nil when the receiver is not a Constant" do
      expect(dispatch(receiver: nominal_string, method_name: :+, args: [constant("hi")])).to be_nil
    end

    it "returns nil when any argument is not a Constant" do
      expect(dispatch(receiver: constant(1), method_name: :+, args: [dynamic_top])).to be_nil
    end

    it "returns nil when the argument count is not 1" do
      expect(dispatch(receiver: constant(1), method_name: :+, args: [])).to be_nil
      expect(dispatch(receiver: constant(1), method_name: :+, args: [constant(2), constant(3)])).to be_nil
    end

    it "returns nil for methods outside the curated whitelist" do
      expect(dispatch(receiver: constant(1), method_name: :tap, args: [constant(2)])).to be_nil
    end

    describe "numeric folding" do
      it "folds Integer + Integer into a Constant Integer" do
        result = dispatch(receiver: constant(1), method_name: :+, args: [constant(2)])

        expect(result).to be_a(Rigor::Type::Constant)
        expect(result.value).to eq(3)
      end

      it "folds Integer * Integer" do
        result = dispatch(receiver: constant(7), method_name: :*, args: [constant(6)])

        expect(result.value).to eq(42)
      end

      it "folds Integer + Float to a Constant Float" do
        result = dispatch(receiver: constant(1), method_name: :+, args: [constant(2.5)])

        expect(result.value).to eq(3.5)
        expect(result.value).to be_a(Float)
      end

      it "folds Float + Integer with mixed numeric promotion" do
        result = dispatch(receiver: constant(1.5), method_name: :+, args: [constant(2)])

        expect(result.value).to eq(3.5)
      end

      it "folds comparison operators into boolean Constants" do
        true_result = dispatch(receiver: constant(1), method_name: :<, args: [constant(2)])
        false_result = dispatch(receiver: constant(2), method_name: :<, args: [constant(2)])

        expect(true_result.value).to be(true)
        expect(false_result.value).to be(false)
      end

      it "folds <=> into a Constant Integer" do
        result = dispatch(receiver: constant(1), method_name: :<=>, args: [constant(2)])

        expect(result.value).to eq(-1)
      end

      it "skips Integer / 0 because it would raise" do
        expect(dispatch(receiver: constant(10), method_name: :/, args: [constant(0)])).to be_nil
      end

      it "permits Integer / 0.0 (Float Infinity is a valid Constant)" do
        result = dispatch(receiver: constant(1), method_name: :/, args: [constant(0.0)])

        expect(result.value).to eq(Float::INFINITY)
      end

      it "skips Integer % 0" do
        expect(dispatch(receiver: constant(10), method_name: :%, args: [constant(0)])).to be_nil
      end
    end

    describe "string folding" do
      it "folds String + String into a Constant String" do
        result = dispatch(receiver: constant("a"), method_name: :+, args: [constant("b")])

        expect(result.value).to eq("ab")
      end

      it "folds String * Integer into a Constant String" do
        result = dispatch(receiver: constant("ab"), method_name: :*, args: [constant(3)])

        expect(result.value).to eq("ababab")
      end

      it "skips String * negative Integer" do
        expect(dispatch(receiver: constant("a"), method_name: :*, args: [constant(-1)])).to be_nil
      end

      it "lifts a size-capped Constant + Constant concat to literal-string (v0.0.9 F)" do
        big = "a" * 4000
        more = "b" * 1000

        result = dispatch(receiver: constant(big), method_name: :+, args: [constant(more)])
        expect(result).to eq(Rigor::Type::Combinator.literal_string)
      end

      it "lifts a size-capped Constant * Constant repeat to literal-string (v0.0.9 F)" do
        result = dispatch(receiver: constant("xyz"), method_name: :*, args: [constant(10_000)])
        expect(result).to eq(Rigor::Type::Combinator.literal_string)
      end

      it "folds String == String comparisons" do
        eq_result = dispatch(receiver: constant("a"), method_name: :==, args: [constant("a")])
        ne_result = dispatch(receiver: constant("a"), method_name: :==, args: [constant("b")])

        expect(eq_result.value).to be(true)
        expect(ne_result.value).to be(false)
      end

      it "returns nil for String + non-String (raises TypeError)" do
        expect(dispatch(receiver: constant("a"), method_name: :+, args: [constant(1)])).to be_nil
      end
    end

    describe "symbol folding" do
      it "folds :a == :a into Constant true" do
        result = dispatch(receiver: constant(:a), method_name: :==, args: [constant(:a)])

        expect(result.value).to be(true)
      end

      it "folds :a == :b into Constant false" do
        result = dispatch(receiver: constant(:a), method_name: :==, args: [constant(:b)])

        expect(result.value).to be(false)
      end

      it "folds Symbol comparisons" do
        result = dispatch(receiver: constant(:apple), method_name: :<, args: [constant(:banana)])

        expect(result.value).to be(true)
      end

      it "returns nil for Symbol < non-Symbol (raises ArgumentError)" do
        expect(dispatch(receiver: constant(:a), method_name: :<, args: [constant(1)])).to be_nil
      end
    end

    describe "boolean folding" do
      it "folds true & true into Constant true" do
        result = dispatch(receiver: constant(true), method_name: :&, args: [constant(true)])

        expect(result.value).to be(true)
      end

      it "folds true | false into Constant true" do
        result = dispatch(receiver: constant(true), method_name: :|, args: [constant(false)])

        expect(result.value).to be(true)
      end

      it "folds true ^ true into Constant false" do
        result = dispatch(receiver: constant(true), method_name: :^, args: [constant(true)])

        expect(result.value).to be(false)
      end
    end

    describe "nil folding" do
      it "folds nil == nil into Constant true" do
        result = dispatch(receiver: constant(nil), method_name: :==, args: [constant(nil)])

        expect(result.value).to be(true)
      end

      it "folds nil == 1 into Constant false" do
        result = dispatch(receiver: constant(nil), method_name: :==, args: [constant(1)])

        expect(result.value).to be(false)
      end

      it "returns nil for nil + 1 (operator not in nil whitelist)" do
        expect(dispatch(receiver: constant(nil), method_name: :+, args: [constant(1)])).to be_nil
      end
    end

    describe "plugin return-type contribution tier (v0.1.1 / Track 2 slice 7)" do
      let(:call_node) { Prism.parse("foo()").value.statements.body.first }
      let(:contribution) do
        Rigor::FlowContribution.new(
          return_type: Rigor::Type::Combinator.constant_of("admin"),
          provenance: Rigor::FlowContribution::Provenance.new(
            source_family: "plugin.flow-contributor", plugin_id: "flow-contributor",
            node: nil, descriptor: nil
          )
        )
      end

      def make_plugin(plugin_id, contribution)
        klass = Class.new(Rigor::Plugin::Base) do
          manifest(id: plugin_id, version: "0.1.0")
          define_method(:flow_contribution_for) { |**| contribution }
        end
        stub_const("FakePluginFor#{plugin_id.tr('-', '_').capitalize}", klass)
        klass
      end

      def env_with(plugins)
        registry = Rigor::Plugin::Registry.new(plugins: plugins)
        Rigor::Environment.new(plugin_registry: registry)
      end

      def services_for_test
        Rigor::Plugin::Services.new(
          reflection: Rigor::Reflection,
          type: Rigor::Type::Combinator,
          configuration: Rigor::Configuration.new
        )
      end

      def scope_with(env)
        Rigor::Scope.empty(environment: env)
      end

      before { Rigor::Plugin.unregister! }
      after { Rigor::Plugin.unregister! }

      it "uses the merged plugin return_type when no precise tier resolves the call" do
        services = services_for_test
        plugin_class = make_plugin("flow-contributor", contribution)
        Rigor::Plugin.register(plugin_class)
        plugin = plugin_class.new(services: services, config: {})
        env = env_with([plugin])

        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("Object"),
          method_name: :foo,
          arg_types: [],
          environment: env,
          call_node: call_node,
          scope: scope_with(env)
        )
        expect(result).to eq(Rigor::Type::Combinator.constant_of("admin"))
      end

      it "skips the plugin tier when call_node or scope is nil (internal callers)" do
        services = services_for_test
        plugin_class = make_plugin("flow-contributor", contribution)
        Rigor::Plugin.register(plugin_class)
        plugin = plugin_class.new(services: services, config: {})
        env = env_with([plugin])

        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("Object"),
          method_name: :foo,
          arg_types: [],
          environment: env
        )
        # No plugin tier consulted; falls through to RBS / fallback,
        # which doesn't know `Object#foo`. Expect nil rather than
        # the plugin's "admin" string.
        expect(result).to be_nil
      end

      it "drops a plugin contribution that raises and continues with the rest of the chain" do # rubocop:disable RSpec/ExampleLength
        services = services_for_test
        plugin_class = Class.new(Rigor::Plugin::Base) do
          manifest(id: "raising-contributor", version: "0.1.0")
          def flow_contribution_for(**) = raise("boom")
        end
        stub_const("FakeRaisingContributorPluginUnit", plugin_class)
        Rigor::Plugin.register(plugin_class)
        plugin = plugin_class.new(services: services, config: {})
        env = env_with([plugin])

        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("Object"),
          method_name: :foo,
          arg_types: [],
          environment: env,
          call_node: call_node,
          scope: scope_with(env)
        )
        expect(result).to be_nil
      end
    end

    describe "dependency-source inference tier (ADR-10 slice 2b-ii)" do
      def env_with_index(method_catalog)
        index = Rigor::Analysis::DependencySourceInference::Index.new(
          resolved_gems: [
            Rigor::Analysis::DependencySourceInference::GemResolver::Resolved.new(
              gem_name: "fake", version: "1.0.0", gem_dir: "/fake",
              mode: :when_missing, roots: %w[lib]
            )
          ],
          method_catalog: method_catalog
        )
        Rigor::Environment.new(dependency_source_index: index)
      end

      it "returns Dynamic[top] for a Nominal receiver whose (class, method) is in the catalog" do
        env = env_with_index({ ["FakeLib::Widget", :render] => :instance })

        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("FakeLib::Widget"),
          method_name: :render, arg_types: [], environment: env
        )

        expect(result).to eq(Rigor::Type::Combinator.untyped)
      end

      it "returns Dynamic[top] for a Singleton receiver whose (class, method) is in the catalog" do
        env = env_with_index({ ["FakeLib::Widget", :build] => :singleton })

        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.singleton_of("FakeLib::Widget"),
          method_name: :build, arg_types: [], environment: env
        )

        expect(result).to eq(Rigor::Type::Combinator.untyped)
      end

      it "falls through when the receiver class is not in the catalog" do
        env = env_with_index({ ["Other", :render] => :instance })

        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("FakeLib::Widget"),
          method_name: :render, arg_types: [], environment: env
        )

        expect(result).to be_nil
      end

      it "falls through when the environment carries no dependency_source_index" do
        env = Rigor::Environment.new

        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("FakeLib::Widget"),
          method_name: :render, arg_types: [], environment: env
        )

        expect(result).to be_nil
      end
    end

    describe "boundary-cross recording on RBS dispatch (ADR-10 slice 5c)" do
      let(:reporter) { Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new }

      def env_with_full_mode_index(class_to_gem:, gem_modes:, method_catalog:, reporter:)
        resolver = Rigor::Analysis::DependencySourceInference::GemResolver
        resolved = gem_modes.map do |gem_name, mode|
          resolver::Resolved.new(
            gem_name: gem_name, version: "1.0.0",
            gem_dir: "/fake/#{gem_name}", mode: mode, roots: %w[lib]
          )
        end
        index = Rigor::Analysis::DependencySourceInference::Index.new(
          resolved_gems: resolved, method_catalog: method_catalog,
          class_to_gem: class_to_gem, gem_modes: gem_modes
        )
        Rigor::Environment.for_project(
          dependency_source_index: index,
          boundary_cross_reporter: reporter
        )
      end

      it "records a boundary-cross entry when RBS resolves an Integer call on a `mode: :full` gem class" do
        # Integer is in core RBS so `RbsDispatch.try_dispatch`
        # resolves `1.bit_length` to `Integer`. The pretend-
        # to-own-Integer gem-source catalog turns the call site
        # into a `mode: :full` boundary crossing.
        env = env_with_full_mode_index(
          class_to_gem: { "Integer" => "core_shim" },
          gem_modes: { "core_shim" => :full },
          method_catalog: { ["Integer", :bit_length] => :instance },
          reporter: reporter
        )

        described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("Integer"),
          method_name: :bit_length, arg_types: [], environment: env
        )

        expect(reporter.entries.size).to eq(1)
        expect(reporter.entries.first).to have_attributes(
          class_name: "Integer", method_name: :bit_length, gem_name: "core_shim"
        )
      end

      it "does NOT record when the owning gem's mode is :when_missing" do
        env = env_with_full_mode_index(
          class_to_gem: { "Integer" => "core_shim" },
          gem_modes: { "core_shim" => :when_missing },
          method_catalog: { ["Integer", :bit_length] => :instance },
          reporter: reporter
        )

        described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("Integer"),
          method_name: :bit_length, arg_types: [], environment: env
        )

        expect(reporter).to be_empty
      end

      it "does NOT record when the catalog has no entry for the method" do
        env = env_with_full_mode_index(
          class_to_gem: { "Integer" => "core_shim" },
          gem_modes: { "core_shim" => :full },
          method_catalog: {},
          reporter: reporter
        )

        described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("Integer"),
          method_name: :bit_length, arg_types: [], environment: env
        )

        expect(reporter).to be_empty
      end
    end
  end
end
