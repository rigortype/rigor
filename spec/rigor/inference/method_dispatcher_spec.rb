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

    it "promotes Nominal[String] + Constant<non-empty> to non-empty-string (arg-driven uplift)" do
      expect(dispatch(receiver: nominal_string, method_name: :+, args: [constant("hi")])).to eq(
        Rigor::Type::Combinator.non_empty_string
      )
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

      it "lifts a size-capped Constant + Constant concat to non-empty-literal-string (v0.0.9 F, non-empty uplift)" do
        big = "a" * 4000
        more = "b" * 1000

        result = dispatch(receiver: constant(big), method_name: :+, args: [constant(more)])
        expect(result).to eq(Rigor::Type::Combinator.non_empty_literal_string)
      end

      it "lifts a size-capped Constant * Constant repeat to non-empty-literal-string (v0.0.9 F, non-empty uplift)" do
        result = dispatch(receiver: constant("xyz"), method_name: :*, args: [constant(10_000)])
        expect(result).to eq(Rigor::Type::Combinator.non_empty_literal_string)
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

    describe "plugin dynamic_return contribution tier (v0.1.1 / Track 2 slice 7)" do
      let(:call_node) { Prism.parse("foo()").value.statements.body.first }

      def make_plugin(plugin_id, return_type)
        klass = Class.new(Rigor::Plugin::Base) do
          manifest(id: plugin_id, version: "0.1.0")
          dynamic_return methods: [:foo] do |_call_node, _scope|
            return_type
          end
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
        plugin_class = make_plugin("flow-contributor", Rigor::Type::Combinator.constant_of("admin"))
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
        plugin_class = make_plugin("flow-contributor", Rigor::Type::Combinator.constant_of("admin"))
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

      it "drops a dynamic_return rule block that raises and continues with the rest of the chain" do
        services = services_for_test
        plugin_class = Class.new(Rigor::Plugin::Base) do
          manifest(id: "raising-contributor", version: "0.1.0")
          dynamic_return methods: [:foo] do |_call_node, _scope|
            raise "boom"
          end
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

      describe "ADR-10 return-type heuristic (post-floor enhancement)" do
        # The Walker's ReturnTypeHeuristic populates the
        # CatalogEntry's `return_type:` with a static facet for
        # literal-tail method bodies; the dispatcher wraps that
        # facet in `Dynamic[T]` per the gem-boundary contract
        # instead of falling back to the pre-heuristic
        # `Dynamic[top]`.
        let(:catalog_entry_klass) { Rigor::Analysis::DependencySourceInference::Walker::CatalogEntry }

        it "wraps a heuristic-supplied Constant<Integer> return into Dynamic[Constant<value>]" do
          env = env_with_index(
            ["FakeLib::Widget", :version] => catalog_entry_klass.new(
              kind: :instance,
              return_type: Rigor::Type::Combinator.constant_of(42)
            )
          )

          result = described_class.dispatch(
            receiver_type: Rigor::Type::Combinator.nominal_of("FakeLib::Widget"),
            method_name: :version, arg_types: [], environment: env
          )

          expect(result).to eq(
            Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.constant_of(42))
          )
        end

        it "wraps a heuristic-supplied Nominal[String] return into Dynamic[Nominal[String]]" do
          env = env_with_index(
            ["FakeLib::Widget", :name] => catalog_entry_klass.new(
              kind: :instance,
              return_type: Rigor::Type::Combinator.nominal_of("String")
            )
          )

          result = described_class.dispatch(
            receiver_type: Rigor::Type::Combinator.nominal_of("FakeLib::Widget"),
            method_name: :name, arg_types: [], environment: env
          )

          expect(result).to eq(
            Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.nominal_of("String"))
          )
        end

        it "falls back to Dynamic[top] when the catalog entry's return_type is nil" do
          env = env_with_index(
            ["FakeLib::Widget", :unknown] => catalog_entry_klass.new(kind: :instance)
          )

          result = described_class.dispatch(
            receiver_type: Rigor::Type::Combinator.nominal_of("FakeLib::Widget"),
            method_name: :unknown, arg_types: [], environment: env
          )

          expect(result).to eq(Rigor::Type::Combinator.untyped)
        end
      end
    end

    describe "project-side patched-method tier (ADR-17 slice 3a)" do
      def env_with_patched(entries)
        registry = Rigor::Inference::ProjectPatchedMethods.new(entries: entries)
        Rigor::Environment.new(project_patched_methods: registry)
      end

      let(:entry_klass) { Rigor::Inference::ProjectPatchedMethods::Entry }

      it "resolves a patched instance method to Dynamic[top] when no return_type heuristic ran" do
        env = env_with_patched([
                                 entry_klass.new(
                                   class_name: "String", method_name: :to_url, kind: :instance,
                                   source_path: "lib/ext.rb", source_line: 1
                                 )
                               ])
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("String"),
          method_name: :to_url, arg_types: [], environment: env
        )
        expect(result).to eq(Rigor::Type::Combinator.untyped)
      end

      it "wraps the registry's heuristic return_type in Dynamic[T] (slice 3a uplift)" do
        env = env_with_patched([
                                 entry_klass.new(
                                   class_name: "String", method_name: :kind_label, kind: :instance,
                                   source_path: "lib/ext.rb", source_line: 1,
                                   return_type: Rigor::Type::Combinator.nominal_of("String")
                                 )
                               ])
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("String"),
          method_name: :kind_label, arg_types: [], environment: env
        )
        expect(result).to eq(
          Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.nominal_of("String"))
        )
      end

      it "respects kind (:instance vs :singleton)" do
        env = env_with_patched([
                                 entry_klass.new(
                                   class_name: "Foo", method_name: :ping, kind: :singleton,
                                   source_path: "ext.rb", source_line: 1
                                 )
                               ])
        instance_result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("Foo"),
          method_name: :ping, arg_types: [], environment: env
        )
        singleton_result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.singleton_of("Foo"),
          method_name: :ping, arg_types: [], environment: env
        )
        expect(instance_result).to be_nil
        expect(singleton_result).to eq(Rigor::Type::Combinator.untyped)
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

    describe "static return refinements tier (Kernel#__dir__)" do
      let(:env) { Rigor::Environment.default }
      let(:expected_dir_type) do
        Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.non_empty_string,
          Rigor::Type::Combinator.constant_of(nil)
        )
      end

      it "tightens Kernel.__dir__ (singleton receiver) to non-empty-string | nil" do
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.singleton_of("Kernel"),
          method_name: :__dir__, arg_types: [], environment: env
        )
        expect(result).to eq(expected_dir_type)
      end

      it "tightens an implicit-self __dir__ (Nominal receiver) to non-empty-string | nil" do
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("Object"),
          method_name: :__dir__, arg_types: [], environment: env
        )
        expect(result).to eq(expected_dir_type)
      end

      it "fires for any Kernel-mixed-in receiver class (e.g. user-defined class)" do
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("MyApp::Service"),
          method_name: :__dir__, arg_types: [], environment: env
        )
        expect(result).to eq(expected_dir_type)
      end

      it "does NOT fire for a BasicObject receiver (Kernel not mixed in)" do
        # BasicObject is the one class that explicitly excludes
        # Kernel, so the tightened return would be wrong.
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("BasicObject"),
          method_name: :__dir__, arg_types: [], environment: env
        )
        expect(result).not_to eq(expected_dir_type)
      end
    end

    describe "user-class fallback for module-mixin receivers" do
      let(:env) { Rigor::Environment.default }

      it "routes Nominal[<core module>].inspect through Nominal[Object]" do
        # Comparable is a real RBS module that does not declare
        # `inspect` itself. With the module-mixin fallback in
        # `user_class_fallback_receiver`, the dispatcher retries
        # against Nominal[Object] and resolves Kernel#inspect.
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("Comparable"),
          method_name: :inspect, arg_types: [], environment: env
        )
        expect(result).to be_a(Rigor::Type::Nominal)
        expect(result.class_name).to eq("String")
      end

      it "routes Nominal[<core module>].class through Nominal[Object]" do
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("Comparable"),
          method_name: :class, arg_types: [], environment: env
        )
        # `meta_class` for a Nominal returns Singleton[<class_name>]
        # — the receiver-side `class` always wins at the
        # meta-introspection tier (above the fallback). The point
        # of the test is that this doesn't surface as
        # `undefined-method` because the fallback would have
        # caught it even if meta-introspection didn't.
        expect(result).to be_a(Rigor::Type::Singleton)
      end

      it "does NOT route Nominal[<core class>] through the module fallback" do
        # Object is a class, not a module. The fallback path is
        # NOT taken — the dispatcher uses Object's own RBS
        # directly, not a fallback against Object's parent.
        expect(env.rbs_module?("Object")).to be(false)
      end

      it "preserves the original receiver type as `self` when falling back through Object" do
        # `Kernel#dup: () -> self` resolved through the Object
        # fallback (because `MyApp::UriThing` is not in RBS)
        # MUST return `Nominal[MyApp::UriThing]`, not
        # `Nominal[Object]`. Without `self_type_override`,
        # `base = self.dup` inside a `Bundler::URI::Generic`
        # method body types `base` as `Object` and every
        # subsequent `base.fragment=` / `base.set_path(...)`
        # call fires `undefined-method for Object`.
        unknown_receiver = Rigor::Type::Combinator.nominal_of("MyApp::UriThing")
        result = described_class.dispatch(
          receiver_type: unknown_receiver,
          method_name: :dup, arg_types: [], environment: env
        )
        expect(result).to eq(unknown_receiver)
      end

      it "preserves the original receiver type for `clone` (the symmetric Kernel method)" do
        unknown_receiver = Rigor::Type::Combinator.nominal_of("MyApp::Thing")
        result = described_class.dispatch(
          receiver_type: unknown_receiver,
          method_name: :clone, arg_types: [], environment: env
        )
        expect(result).to eq(unknown_receiver)
      end
    end

    describe "private-method suppression on the explicit-receiver fallback" do
      let(:env) { Rigor::Environment.default }

      def call_node_for(source)
        Prism.parse(source).value.statements.body.first
      end

      it "does NOT resolve a private Kernel method on an explicit non-self receiver" do
        # `Favourite.select(:col)` (ActiveRecord) must not adopt the
        # private `Kernel#select` signature (`-> Array[String]`).
        # Ruby raises NoMethodError for a private method called with
        # an explicit receiver, so the fallback returns nil and the
        # call types `Dynamic[top]` rather than a wrong `Array[String]`.
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.singleton_of("Favourite"),
          method_name: :select, arg_types: [Rigor::Type::Combinator.constant_of(:status_id)],
          environment: env,
          call_node: call_node_for("Favourite.select(:status_id)")
        )
        expect(result).to be_nil
      end

      it "still resolves a private Kernel method on an IMPLICIT-self call" do
        # `puts "x"` inside a method body is an implicit-self call:
        # `call_node.receiver` is nil, so the fallback keeps resolving
        # `Kernel#puts` (the fallback's intended target).
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.nominal_of("MyApp::Greeter"),
          method_name: :puts, arg_types: [Rigor::Type::Combinator.nominal_of("String")],
          environment: env,
          call_node: call_node_for("puts \"x\"")
        )
        expect(result).not_to be_nil
      end

      it "still resolves a public Kernel method on an explicit non-self receiver" do
        # `.dup` is public — the explicit-receiver suppression must
        # not touch it.
        unknown_receiver = Rigor::Type::Combinator.nominal_of("MyApp::Thing")
        result = described_class.dispatch(
          receiver_type: unknown_receiver,
          method_name: :dup, arg_types: [],
          environment: env,
          call_node: call_node_for("thing.dup")
        )
        expect(result).to eq(unknown_receiver)
      end
    end

    describe "static return refinements tier (File class-side)" do
      let(:env) { Rigor::Environment.default }
      let(:non_empty_string) { Rigor::Type::Combinator.non_empty_string }

      it "tightens File.expand_path to non-empty-string" do
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.singleton_of("File"),
          method_name: :expand_path,
          arg_types: [Rigor::Type::Combinator.nominal_of("String")],
          environment: env
        )
        expect(result).to eq(non_empty_string)
      end

      it "tightens File.dirname to non-empty-string" do
        result = described_class.dispatch(
          receiver_type: Rigor::Type::Combinator.singleton_of("File"),
          method_name: :dirname,
          arg_types: [Rigor::Type::Combinator.nominal_of("String")],
          environment: env
        )
        expect(result).to eq(non_empty_string)
      end
    end

    describe "Class.new return-type lift (meta_new — anonymous-subclass shape)" do
      def singleton(name) = Rigor::Type::Combinator.singleton_of(name)

      it "lifts `Class.new(Parent)` to Singleton[Parent]" do
        result = dispatch(
          receiver: singleton("Class"),
          method_name: :new,
          args: [singleton("ApplicationRecord")]
        )
        expect(result).to eq(singleton("ApplicationRecord"))
      end

      it "lifts `Class.new` (no parent) to Singleton[Object]" do
        result = dispatch(receiver: singleton("Class"), method_name: :new, args: [])
        expect(result).to eq(singleton("Object"))
      end

      it "declines (falls back to Nominal[Class]) when the parent argument is not a Singleton" do
        result = dispatch(
          receiver: singleton("Class"),
          method_name: :new,
          args: [Rigor::Type::Combinator.nominal_of("Class")]
        )
        expect(result).to eq(Rigor::Type::Combinator.nominal_of("Class"))
      end
    end

    describe "Struct.new return-type folding (StructFolding — anonymous Struct subclass)" do
      def singleton(name) = Rigor::Type::Combinator.singleton_of(name)
      def sym(value) = Rigor::Type::Combinator.constant_of(value)

      it "folds `Struct.new(:a, :b)` (all symbol members) to a StructClass member layout" do
        # ADR-48 Struct follow-up — StructFolding supersedes the old
        # `struct_new_lift` (which produced a bare `Singleton[Struct]`); the
        # chained `.new` now dispatches against the precise member layout.
        result = dispatch(receiver: singleton("Struct"), method_name: :new, args: [sym(:a), sym(:b)])
        expect(result).to eq(Rigor::Type::Combinator.struct_class_of(members: %i[a b]))
      end

      it "lifts the instance-construction `.new(1, 2)` (non-symbol args) to Nominal[Struct]" do
        result = dispatch(
          receiver: singleton("Struct"),
          method_name: :new,
          args: [Rigor::Type::Combinator.constant_of(1), Rigor::Type::Combinator.constant_of(2)]
        )
        expect(result).to eq(Rigor::Type::Combinator.nominal_of("Struct"))
      end

      it "lifts zero-arg `.new` (every member defaults to nil) to Nominal[Struct]" do
        result = dispatch(receiver: singleton("Struct"), method_name: :new, args: [])
        expect(result).to eq(Rigor::Type::Combinator.nominal_of("Struct"))
      end
    end
  end
end
