# frozen_string_literal: true

# Integration spec for `examples/rigor-pattern/`. Reference
# coverage for the plugin -> analyzer collaboration pattern:
# the plugin queries `Scope#type_of` and Rigor's
# `Type::Combinator.literal_string_compatible?` predicate
# rather than reimplementing literal-string tracking.

require "spec_helper"

PATTERN_PLUGIN_LIB = File.expand_path("../../../examples/rigor-pattern/lib", __dir__)
$LOAD_PATH.unshift(PATTERN_PLUGIN_LIB) unless $LOAD_PATH.include?(PATTERN_PLUGIN_LIB)
require "rigor-pattern"

RSpec.describe "examples/rigor-pattern" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Pattern }

  let(:plugin_config) do
    {
      "patterns" => {
        "email" => '\A[^\s@]+@[^\s@]+\z',
        "uuid" => '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
      }
    }
  end

  def with_pattern_config(source, config: plugin_config)
    src = source.end_with?("\n") ? source : "#{source}\n"
    run_plugin(
      source: src,
      plugin_entry: { "gem" => "rigor-pattern", "config" => config }
    )
  end

  describe "Constant<String> direct literals" do
    it "passes a matching literal" do
      diags = plugin_diagnostics(with_pattern_config('validate(:email, "user@example.com")'))
      info = diags.find { |d| d.rule == "literal-match" }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to eq('literal "user@example.com" matches :email')
    end

    it "errors on a non-matching literal" do
      diags = plugin_diagnostics(with_pattern_config('validate(:email, "not-an-email")'))
      err = diags.find { |d| d.rule == "literal-mismatch" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:error)
      expect(err.message).to eq(
        'literal "not-an-email" does not match :email (\A[^\s@]+@[^\s@]+\z)'
      )
    end

    it "validates UUIDs against the configured pattern" do
      diags = plugin_diagnostics(with_pattern_config('validate(:uuid, "a1b2c3d4-1111-2222-3333-444455556666")'))
      expect(diags.first.rule).to eq("literal-match")
    end
  end

  describe "engine collaboration through LiteralStringFolding" do
    it "sees `\"a\" + \"b\"` as a literal because Rigor folds it" do
      diags = plugin_diagnostics(with_pattern_config('validate(:email, "user" + "@example.com")'))
      info = diags.find { |d| d.rule == "literal-match" }
      expect(info).not_to be_nil
      expect(info.message).to eq('literal "user@example.com" matches :email')
    end

    it "still recognises interpolated literal strings as literal-string-compatible" do
      # Interpolation may not constant-fold all the way to a
      # `Constant<String>` (depending on Rigor's interpolation
      # tier), but the literal-string carrier still publishes
      # the fact, so the plugin emits either `literal-match`
      # (exact value known) or `literal-unknown` (carrier
      # detected, exact value not Constant). Either rule
      # demonstrates the engine collaboration.
      diags = plugin_diagnostics(with_pattern_config('validate(:email, "user@#{"example.com"}")')) # rubocop:disable Lint/InterpolationCheck
      info = diags.find { |d| %w[literal-match literal-unknown].include?(d.rule) }
      expect(info).not_to be_nil
    end
  end

  describe "non-literal arguments stay silent" do
    it "does not emit when the value is a method call" do
      diags = plugin_diagnostics(with_pattern_config("validate(:email, ARGV.first)"))
      expect(diags).to be_empty
    end

    it "does not emit when the value is a local read" do
      diags = plugin_diagnostics(with_pattern_config(<<~RUBY))
        external = ARGV.first || "fallback"
        validate(:email, external)
      RUBY
      expect(diags).to be_empty
    end
  end

  describe "unknown-pattern diagnostics" do
    it "errors when the pattern name is not declared in config" do
      diags = plugin_diagnostics(with_pattern_config('validate(:zip, "12345")'))
      err = diags.find { |d| d.rule == "unknown-pattern" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:error)
      expect(err.message).to start_with("no pattern named :zip in plugin config")
      expect(err.message).to include(":email")
      expect(err.message).to include(":uuid")
    end
  end

  describe "shape filtering — irrelevant calls" do
    it "ignores non-Symbol first args" do
      diags = plugin_diagnostics(with_pattern_config('validate("email", "user@example.com")'))
      expect(diags).to be_empty
    end

    it "ignores calls with fewer than 2 arguments" do
      diags = plugin_diagnostics(with_pattern_config("validate(:email)"))
      expect(diags).to be_empty
    end

    it "ignores calls to a different method name" do
      diags = plugin_diagnostics(with_pattern_config('check(:email, "user@example.com")'))
      expect(diags).to be_empty
    end
  end

  describe "configurable method name" do
    it "treats `check` as the validator when configured" do
      config = plugin_config.merge("method_name" => "check")
      diags = plugin_diagnostics(with_pattern_config('check(:email, "not-an-email")', config: config))
      err = diags.find { |d| d.rule == "literal-mismatch" }
      expect(err).not_to be_nil
    end
  end

  describe "#flow_contribution_for return-type contribution (v0.1.2)" do
    # On a successful match the runtime `validate` returns its
    # value argument unchanged, so the plugin contributes the
    # argument's type (typically `Constant<String>`) as the
    # call site's return type. Downstream calls then resolve
    # against `String` instead of the RBS-level untyped.
    it "narrows a matching literal so downstream non-String calls surface" do
      result = with_pattern_config(<<~RUBY)
        result = validate(:email, "user@example.com")
        result.bit_length
      RUBY
      undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method"
      end
      expect(undefined).not_to be_nil
      expect(undefined.message).to include("bit_length")
      expect(undefined.message).to include("user@example.com")
    end

    it "stays at untyped when the pattern does not match (mismatch surfaces only the existing diagnostic)" do
      result = with_pattern_config(<<~RUBY)
        result = validate(:email, "not-an-email")
        result.bit_length
      RUBY
      method_undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method"
      end
      expect(method_undefined).to be_empty
    end

    it "does not contribute when the value is not literal-string-compatible" do
      result = with_pattern_config(<<~RUBY)
        external = ARGV.first || "fallback"
        result = validate(:email, external)
        result.bit_length
      RUBY
      method_undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method"
      end
      expect(method_undefined).to be_empty
    end
  end
end
