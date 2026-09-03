# frozen_string_literal: true

# Executable contract for the note `docs/notes/20260603-phpstan-type-algebra-comparison.md` (§3 G1) and ADR-42:
# a Ruby binary operator (`a + b`) is a `Prism::CallNode` named `:+`, so it flows through the ordinary dispatch
# path where the plugin `dynamic_return` tier (receiver-gated, method-name-agnostic) sits between
# `ConstantFolding` and RBS. A plugin can therefore specify the result type of a binary operation on a
# plugin-owned receiver WITHOUT any operator-specific extension point — which is why ADR-42 records the
# self/left-operand case as "already works" and scopes itself to the coerce direction only.
#
# Observation method: the plugin contributes a CORE return type (`String`) for the operator, because Rigor (by
# false-positive discipline) does not raise `undefined-method` on bare user classes — only on classes it fully
# models (core/RBS). So a downstream `.nope_zzz` on the contributed type surfaces `undefined method 'nope_zzz'
# for String` exactly when the contribution took effect.
#
# The same spec pins the coerce-direction LIMITATION (ADR-42's subject): `1 + money` dispatches on `Integer`,
# so a `receivers: ["Money"]` rule does not fire; the result types as the left operand `Integer` (NOT the
# contributed type and NOT `Dynamic`). That left-biased result is the narrow false-positive surface ADR-42
# scopes itself to.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "plugin dynamic_return captures binary-operator sugar (ADR-42)" do
  # A minimal plugin that contributes a return type for arithmetic operators on a plugin-owned `Money`
  # receiver. It returns `String` (a core type) purely as an observable sentinel — `Money <op> Money` is not
  # semantically a String; the point is that a core return type makes the contribution visible via downstream
  # method resolution.
  let(:operator_plugin) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "optest", version: "0.1.0")

      dynamic_return receivers: ["Money"] do |call_node, _scope|
        next nil unless %i[+ - * /].include?(call_node.name)

        Rigor::Type::Combinator.nominal_of("String")
      end
    end
    stub_const("FakeOperatorPlugin", klass)
    klass
  end

  def run_analysis(source)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.rb"), source)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "plugins" => ["rigor-optest"]
        )
      )
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(operator_plugin)
            true
          end
        )
        guarded_run(runner)
      end
    end
  end

  # Messages of the form "undefined method `nope_zzz' for <Type>".
  def nope_zzz_undefined_for(result)
    result.diagnostics
          .select { |d| d.rule.to_s.include?("undefined-method") && d.message.include?("nope_zzz") }
          .map(&:message)
  end

  describe "self / left-operand operators (already supported via dynamic_return)" do
    it "routes `Money + Money` through dynamic_return so the result types as the contribution" do
      result = run_analysis(<<~RUBY)
        class Money; end
        a = Money.new
        b = Money.new
        (a + b).nope_zzz
      RUBY

      messages = nope_zzz_undefined_for(result)
      expect(messages).to(
        be_any { |m| m.include?("String") },
        "expected `(a + b)` to type as the contributed String; got #{messages.inspect}"
      )
    end

    it "fires for every declared arithmetic operator, not just `+`" do
      %i[+ - * /].each do |op|
        result = run_analysis(<<~RUBY)
          class Money; end
          a = Money.new
          b = Money.new
          (a #{op} b).nope_zzz
        RUBY

        messages = nope_zzz_undefined_for(result)
        expect(messages).to(
          be_any { |m| m.include?("String") },
          "operator `#{op}` did not reach dynamic_return; got #{messages.inspect}"
        )
      end
    end

    it "declines (returns nil) for an operator outside its set, falling through to normal dispatch" do
      # `==` is not in the rule's operator set, so the block returns nil and the engine resolves
      # `Money == Money` itself (-> bool). The String contribution must NOT appear.
      result = run_analysis(<<~RUBY)
        class Money; end
        a = Money.new
        b = Money.new
        (a == b).nope_zzz
      RUBY

      expect(nope_zzz_undefined_for(result)).not_to(be_any { |m| m.include?("String") })
    end
  end

  describe "coerce direction (ADR-42's scoped gap — NOT supported)" do
    it "does not fire for `Integer + Money`; the result types left-biased as Integer" do
      # `1 + b` dispatches on Integer, so a `receivers: ["Money"]` rule cannot intervene. Rigor types the
      # result as the left operand (Integer), NOT the contributed String and NOT Dynamic. Calling `.nope_zzz`
      # therefore resolves against Integer. This left-biased result is the narrow false-positive surface
      # ADR-42 addresses: had `b` defined a real method, calling it on `(1 + b)` would be flagged
      # undefined-for-Integer despite working at runtime via `b.coerce`.
      result = run_analysis(<<~RUBY)
        class Money; end
        b = Money.new
        (1 + b).nope_zzz
      RUBY

      messages = nope_zzz_undefined_for(result)
      expect(messages).to(
        be_any { |m| m.include?("Integer") },
        "expected coerce-direction result to type as Integer; got #{messages.inspect}"
      )
      expect(messages).not_to(be_any { |m| m.include?("String") })
    end
  end
end
