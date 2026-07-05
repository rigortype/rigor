# frozen_string_literal: true

# Integration spec for `plugins/rigor-rspec/`. Tier 3A of the Rails plugins roadmap. Deliberately scoped — only
# flags duplicate `let` / `subject` declarations and self-referencing let blocks. The heavier mock-target /
# let-typo detection is out of scope for v0.1.0.

require "spec_helper"

RSPEC_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-rspec/lib", __dir__)
$LOAD_PATH.unshift(RSPEC_PLUGIN_LIB) unless $LOAD_PATH.include?(RSPEC_PLUGIN_LIB)
require "rigor-rspec"

RSpec.describe "plugins/rigor-rspec" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Rspec }

  describe "duplicate-let detection" do
    it "flags two `let(:name)` declarations in the same scope" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "User" do
            let(:user) { :first }
            let(:user) { :second }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "duplicate-let" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:warning)
      expect(err.message).to include("duplicate `let(:user)`")
      expect(err.message).to include("first declared at line 2")
    end

    it "flags `subject(:name)` duplicates" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "Greeting" do
            subject(:greeting) { "hi" }
            subject(:greeting) { "hello" }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "duplicate-let" }
      expect(err).not_to be_nil
      expect(err.message).to include("subject(:greeting)")
    end

    it "does NOT flag `let` declarations in different scopes (nested context)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "User" do
            let(:user) { :outer }
            context "when inner" do
              let(:user) { :inner }
            end
          end
        RUBY
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "duplicate-let" }
      expect(diags).to be_empty
    end

    it "flags THREE duplicates with two diagnostics (the second and third occurrences)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:foo) { 1 }
            let(:foo) { 2 }
            let(:foo) { 3 }
          end
        RUBY
      )
      dupes = plugin_diagnostics(result).select { |d| d.rule == "duplicate-let" }
      expect(dupes.size).to eq(2)
    end
  end

  describe "self-reference detection" do
    it "flags `let(:user) { user }` (literal self-reference)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "User" do
            let(:user) { user }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "self-reference" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:error)
      expect(err.message).to include("`user`")
    end

    it "flags `let(:value) { value.something }` (deeper expression)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:value) { value.upcase }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "self-reference" }
      expect(err).not_to be_nil
    end

    it "does NOT flag a let referencing a different let" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:user) { :alice }
            let(:greeting) { "Hello, \#{user}" }
          end
        RUBY
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "self-reference" }
      expect(diags).to be_empty
    end

    it "does NOT flag a let whose body uses an unrelated method" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:user) { build_user }
          end
        RUBY
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "self-reference" }
      expect(diags).to be_empty
    end
  end

  # Pillar 2 Slice 1 — `expect(x).to MATCHER` narrows `x` downstream in the same `it` body. The plugin's
  # `narrowing_facts` (method-gated on `to` / `not_to` / `to_not`, ADR-37 slice 2) recognises the call shape
  # and emits a `post_return_fact` targeting local `x`; the engine's `apply_plugin_assertions` → `:local`
  # target_kind branch narrows the local in the surrounding scope.
  describe "matcher narrowing (Pillar 2 Slice 1)" do
    def parse_call_node(source)
      Prism.parse(source, scopes: [[:x]]).value.statements.body.first
    end

    let(:plugin) { plugin_class.allocate }

    context "when matcher is be_a(Class)" do
      it "emits a :local post_return_fact narrowing to Nominal[Class]" do
        call_node = parse_call_node("expect(x).to be_a(String)")
        facts = plugin.type_specifier_facts(call_node: call_node, scope: nil)
        fact = facts.first

        expect(facts).not_to be_empty
        expect(fact.target_kind).to eq(:local)
        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end
    end

    context "when matcher is be_kind_of(Class)" do
      it "emits the same shape as be_a" do
        call_node = parse_call_node("expect(x).to be_kind_of(Integer)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      end
    end

    context "when matcher is be_instance_of(Class)" do
      it "emits a :local fact for the named class" do
        call_node = parse_call_node("expect(x).to be_instance_of(Float)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("Float"))
      end
    end

    context "when matcher is be_nil" do
      it "emits a :local fact narrowing to Constant<nil>" do
        call_node = parse_call_node("expect(x).to be_nil")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
      end
    end

    context "when matcher is eq(literal)" do
      it "narrows to Constant<integer> for an integer literal" do
        call_node = parse_call_node("expect(x).to eq(42)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(42))
      end

      it "narrows to Constant<string> for a string literal" do
        call_node = parse_call_node('expect(x).to eq("hi")')
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of("hi"))
      end

      it "narrows to Constant<symbol> for a symbol literal" do
        call_node = parse_call_node("expect(x).to eq(:foo)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(:foo))
      end

      it "narrows to Constant<true> for a true literal" do
        call_node = parse_call_node("expect(x).to eq(true)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(true))
      end

      it "is silent for a non-literal argument" do
        call_node = parse_call_node("expect(x).to eq(some_method)")

        expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
      end
    end

    context "when matcher is eql(literal)" do
      it "shares the eq path" do
        call_node = parse_call_node("expect(x).to eql(0)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(0))
      end
    end

    context "when matcher is match(/regex/)" do
      it "narrows x to String for a regex literal arg" do
        call_node = parse_call_node("expect(x).to match(/\\Afoo\\z/)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end

      it "is silent for a non-regex argument" do
        call_node = parse_call_node('expect(x).to match("foo")')
        expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
      end
    end

    context "when assertion verb is not_to" do
      it "emits a negative fact for not_to be_nil" do
        call_node = parse_call_node("expect(x).not_to be_nil")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(true)
      end

      it "emits a negative fact for not_to be_a(T)" do
        call_node = parse_call_node("expect(x).not_to be_a(String)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
        expect(fact.negative).to be(true)
      end
    end

    context "when assertion verb is to_not (older spelling)" do
      it "behaves like not_to" do
        call_node = parse_call_node("expect(x).to_not be_nil")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.negative).to be(true)
      end
    end

    context "with non-matching call shapes" do
      it "is silent for expect(non_local).to MATCHER" do
        # expect(foo.bar) — the arg isn't a LocalVariableReadNode, so the analyzer cannot name a narrowing target.
        call_node = parse_call_node("expect(foo.bar).to be_a(String)")
        expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
      end

      it "is silent for expect { block }.to raise_error(...)" do
        # Block form doesn't match the call shape; future slices might add support, but for now the analyzer
        # drops out.
        call_node = parse_call_node("expect { foo }.to raise_error(StandardError)")
        expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
      end

      it "is silent for an unrecognised matcher (be_truthy queued for follow-up)" do
        call_node = parse_call_node("expect(x).to be_truthy")
        expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
      end

      it "is silent for a bare method call that isn't `.to`" do
        call_node = parse_call_node("foo(x)")
        expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
      end
    end

    # End-to-end: the plugin's contribution flows through the engine's `apply_plugin_assertions` → `:local`
    # branch and narrows the local so a downstream `.upcase` / `.+` / etc. resolves cleanly.
    context "when running end-to-end through the engine" do
      it "removes the possible-nil-receiver after expect(x).to be_a(String)" do
        result = run_plugin(
          source: <<~RUBY
            # @rbs (String | nil) -> void
            def case_after(x)
              expect(x).to be_a(String)
              x.upcase
            end
          RUBY
        )
        nil_recv = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
        expect(nil_recv).to be_empty
      end

      it "narrows x to Constant<42> after expect(x).to eq(42) — downstream `x + 1` resolves" do
        result = run_plugin(
          source: <<~RUBY
            # @rbs (Integer | nil) -> void
            def case_eq(x)
              expect(x).to eq(42)
              x + 1
            end
          RUBY
        )
        nil_recv = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
        expect(nil_recv).to be_empty
      end
    end
  end

  # Pillar 2 Slice 2 — let / subject locals in `it` bodies are bound to their inferred return type. Tests
  # exercise the LetScopeIndex + LetTypeResolver directly with a stub factory_index where applicable; the
  # end-to-end run goes through `dynamic_return` to prove the engine actually narrows the local.
  describe "let / subject binding (Pillar 2 Slice 2)" do
    describe "LetScopeIndex" do
      def build_index(source)
        Rigor::Plugin::Rspec::LetScopeIndex.build(Prism.parse(source).value)
      end

      it "records the describe-const anchor for `RSpec.describe SomeModel do`" do
        index = build_index(<<~RUBY)
          RSpec.describe User do
            let(:user) { 1 }
          end
        RUBY
        expect(index.records.size).to eq(1)
        expect(index.records.first.describe_const).to eq("User")
        expect(index.records.first.lets.keys).to contain_exactly(:user)
      end

      it "records nested describe scopes with inherited const" do
        index = build_index(<<~RUBY)
          RSpec.describe User do
            let(:user) { 1 }
            describe ".active" do
              let(:filter) { 2 }
            end
          end
        RUBY
        # Two records: outer (User, lets [:user]) and inner (anchor inherits User, lets [:filter]).
        expect(index.records.size).to eq(2)
        const_anchors = index.records.map(&:describe_const)
        expect(const_anchors).to eq(%w[User User])
      end

      it "resolves let_block_at by walking innermost to outermost" do
        source = <<~RUBY
          RSpec.describe User do
            let(:name) { "outer" }
            describe "inner" do
              let(:name) { "inner" }
              it "x" do
                name
              end
            end
          end
        RUBY
        index = build_index(source)
        # The `name` read inside the inner `it` block is line 6; the inner-record's `:name` let wins.
        block = index.let_block_at(6, :name)
        expect(block).not_to be_nil
        expect(block.body.body.first.unescaped).to eq("inner")
      end

      it "captures the implicit `subject { ... }` under :subject" do
        index = build_index(<<~RUBY)
          RSpec.describe User do
            subject { User.new }
          end
        RUBY
        expect(index.records.first.lets.keys).to contain_exactly(:subject)
      end

      it "captures the named `subject(:user) { ... }` under :user" do
        index = build_index(<<~RUBY)
          RSpec.describe User do
            subject(:user) { User.new }
          end
        RUBY
        expect(index.records.first.lets.keys).to contain_exactly(:user)
      end
    end

    describe "LetTypeResolver" do
      def block_node(source)
        ast = Prism.parse(source).value
        ast.statements.body.first.block
      end

      it "resolves `let(:user) { User.new }` to Nominal[User]" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { User.new }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("User"))
      end

      it "resolves `let(:doc) { Foo::Bar.new }` to Nominal[Foo::Bar]" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:doc) { Foo::Bar.new }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Foo::Bar"))
      end

      it "resolves `subject { described_class.new }` via the enclosing describe_const" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("subject { described_class.new }"),
          describe_const: "User", factory_index: nil, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("User"))
      end

      it "returns nil for `described_class.new` without an anchor" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("subject { described_class.new }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to be_nil
      end

      it "resolves `let(:user) { create(:user) }` via factory_index.model_class" do
        factory_index = Class.new do
          def find(name)
            return nil unless name == "user"

            Struct.new(:model_class).new("User")
          end
        end.new
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { create(:user) }"),
          describe_const: nil, factory_index: factory_index, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("User"))
      end

      it "resolves `let(:user) { FactoryBot.build_stubbed(:user) }`" do
        factory_index = Class.new do
          def find(name) = name == "user" ? Struct.new(:model_class).new("Admin::User") : nil
        end.new
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { FactoryBot.build_stubbed(:user) }"),
          describe_const: nil, factory_index: factory_index, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Admin::User"))
      end

      it "returns nil for unrecognised body shapes" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { some_helper_method }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to be_nil
      end

      it "returns nil for factorybot calls when factory_index is missing" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { create(:user) }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to be_nil
      end

      it "uses the LAST statement of a multi-stmt block body" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { x = 1\nUser.new }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("User"))
      end
    end

    describe "end-to-end through the engine" do
      it "binds `user` inside an `it` body to Nominal[User] via let(:user) { User.new }" do
        result = run_plugin(
          source: <<~RUBY
            RSpec.describe User do
              let(:user) { User.new }
              it "test" do
                expect(user).to be_a(User)
              end
            end
          RUBY
        )
        # No undefined-method diagnostics — `user` resolved through the let binding rather than as an unknown
        # method call. The engine's matcher narrowing (Slice 1) plus the let binding (Slice 2) compose cleanly.
        undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
        expect(undefined).to be_empty
      end
    end
  end

  describe "edge cases" do
    it "ignores files with no `RSpec.describe` block" do
      result = run_plugin(source: "x = 1\nputs x\n")
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "ignores `let` calls outside an RSpec describe block" do
      result = run_plugin(
        source: <<~RUBY
          # Not an RSpec file — just calls `let` at top level.
          let(:user) { :first }
          let(:user) { :second }
        RUBY
      )
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "handles `subject` with no name (the implicit subject)" do
      # Two `subject { ... }` calls at the same scope are still duplicates of the implicit `:subject`.
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            subject { :first }
            subject { :second }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "duplicate-let" }
      expect(err).not_to be_nil
      expect(err.message).to include("subject(:subject)")
    end
  end
end
