# frozen_string_literal: true

# Integration spec for `examples/rigor-rspec/`.
# Tier 3A of the Rails plugins roadmap. Deliberately
# scoped — only flags duplicate `let` / `subject`
# declarations and self-referencing let blocks. The
# heavier mock-target / let-typo detection is out of scope
# for v0.1.0.

require "spec_helper"

RSPEC_PLUGIN_LIB = File.expand_path("../../../examples/rigor-rspec/lib", __dir__)
$LOAD_PATH.unshift(RSPEC_PLUGIN_LIB) unless $LOAD_PATH.include?(RSPEC_PLUGIN_LIB)
require "rigor-rspec"

RSpec.describe "examples/rigor-rspec" do
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

  # Pillar 2 Slice 1 — `expect(x).to MATCHER` narrows `x`
  # downstream in the same `it` body. The plugin's
  # `flow_contribution_for` recognises the call shape and
  # emits a `post_return_fact` targeting local `x`; the
  # engine's `apply_plugin_assertions` → `:local`
  # target_kind branch narrows the local in the
  # surrounding scope.
  describe "matcher narrowing (Pillar 2 Slice 1)" do
    def parse_call_node(source)
      Prism.parse(source, scopes: [[:x]]).value.statements.body.first
    end

    let(:plugin) { plugin_class.allocate }

    context "when matcher is be_a(Class)" do
      it "emits a :local post_return_fact narrowing to Nominal[Class]" do
        call_node = parse_call_node("expect(x).to be_a(String)")
        contribution = plugin.flow_contribution_for(call_node: call_node, scope: nil)
        fact = contribution.post_return_facts.first

        expect(contribution).to be_a(Rigor::FlowContribution)
        expect(fact.target_kind).to eq(:local)
        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end
    end

    context "when matcher is be_kind_of(Class)" do
      it "emits the same shape as be_a" do
        call_node = parse_call_node("expect(x).to be_kind_of(Integer)")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      end
    end

    context "when matcher is be_instance_of(Class)" do
      it "emits a :local fact for the named class" do
        call_node = parse_call_node("expect(x).to be_instance_of(Float)")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("Float"))
      end
    end

    context "when matcher is be_nil" do
      it "emits a :local fact narrowing to Constant<nil>" do
        call_node = parse_call_node("expect(x).to be_nil")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
      end
    end

    context "when matcher is eq(literal)" do
      it "narrows to Constant<integer> for an integer literal" do
        call_node = parse_call_node("expect(x).to eq(42)")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(42))
      end

      it "narrows to Constant<string> for a string literal" do
        call_node = parse_call_node('expect(x).to eq("hi")')
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of("hi"))
      end

      it "narrows to Constant<symbol> for a symbol literal" do
        call_node = parse_call_node("expect(x).to eq(:foo)")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(:foo))
      end

      it "narrows to Constant<true> for a true literal" do
        call_node = parse_call_node("expect(x).to eq(true)")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(true))
      end

      it "is silent for a non-literal argument" do
        call_node = parse_call_node("expect(x).to eq(some_method)")
        contribution = plugin.flow_contribution_for(call_node: call_node, scope: nil)

        expect(contribution).to be_nil
      end
    end

    context "when matcher is eql(literal)" do
      it "shares the eq path" do
        call_node = parse_call_node("expect(x).to eql(0)")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(0))
      end
    end

    context "when matcher is match(/regex/)" do
      it "narrows x to String for a regex literal arg" do
        call_node = parse_call_node("expect(x).to match(/\\Afoo\\z/)")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end

      it "is silent for a non-regex argument" do
        call_node = parse_call_node('expect(x).to match("foo")')
        expect(plugin.flow_contribution_for(call_node: call_node, scope: nil)).to be_nil
      end
    end

    context "when assertion verb is not_to" do
      it "emits a negative fact for not_to be_nil" do
        call_node = parse_call_node("expect(x).not_to be_nil")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(true)
      end

      it "emits a negative fact for not_to be_a(T)" do
        call_node = parse_call_node("expect(x).not_to be_a(String)")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
        expect(fact.negative).to be(true)
      end
    end

    context "when assertion verb is to_not (older spelling)" do
      it "behaves like not_to" do
        call_node = parse_call_node("expect(x).to_not be_nil")
        fact = plugin.flow_contribution_for(call_node: call_node, scope: nil).post_return_facts.first

        expect(fact.negative).to be(true)
      end
    end

    context "with non-matching call shapes" do
      it "is silent for expect(non_local).to MATCHER" do
        # expect(foo.bar) — the arg isn't a LocalVariableReadNode,
        # so the analyzer cannot name a narrowing target.
        call_node = parse_call_node("expect(foo.bar).to be_a(String)")
        expect(plugin.flow_contribution_for(call_node: call_node, scope: nil)).to be_nil
      end

      it "is silent for expect { block }.to raise_error(...)" do
        # Block form doesn't match the call shape; future slices
        # might add support, but for now the analyzer drops out.
        call_node = parse_call_node("expect { foo }.to raise_error(StandardError)")
        expect(plugin.flow_contribution_for(call_node: call_node, scope: nil)).to be_nil
      end

      it "is silent for an unrecognised matcher (be_truthy queued for follow-up)" do
        call_node = parse_call_node("expect(x).to be_truthy")
        expect(plugin.flow_contribution_for(call_node: call_node, scope: nil)).to be_nil
      end

      it "is silent for a bare method call that isn't `.to`" do
        call_node = parse_call_node("foo(x)")
        expect(plugin.flow_contribution_for(call_node: call_node, scope: nil)).to be_nil
      end
    end

    # End-to-end: the plugin's contribution flows through the
    # engine's `apply_plugin_assertions` → `:local` branch and
    # narrows the local so a downstream `.upcase` / `.+` /
    # etc. resolves cleanly.
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
      # Two `subject { ... }` calls at the same scope are
      # still duplicates of the implicit `:subject`.
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
