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
  let(:requirer) do
    lambda do |_name|
      Rigor::Plugin.register(plugin_class)
      true
    end
  end

  let(:plugin_config) do
    {
      "patterns" => {
        "email" => '\A[^\s@]+@[^\s@]+\z',
        "uuid" => '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
      }
    }
  end

  def run_plugin(source, config: plugin_config)
    Dir.mktmpdir do |dir|
      source_with_newline = source.end_with?("\n") ? source : "#{source}\n"
      File.write(File.join(dir, "demo.rb"), source_with_newline)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "plugins" => [{ "gem" => "rigor-pattern", "config" => config }]
        )
      )
      Rigor::Analysis::Runner.new(
        configuration: configuration,
        cache_store: nil,
        plugin_requirer: requirer
      ).run
    end
  end

  def plugin_diagnostics(result)
    result.diagnostics.select { |d| d.source_family == "plugin.pattern" }
  end

  describe "Constant<String> direct literals" do
    it "passes a matching literal" do
      diags = plugin_diagnostics(run_plugin('validate(:email, "user@example.com")'))
      info = diags.find { |d| d.rule == "literal-match" }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to eq('literal "user@example.com" matches :email')
    end

    it "errors on a non-matching literal" do
      diags = plugin_diagnostics(run_plugin('validate(:email, "not-an-email")'))
      err = diags.find { |d| d.rule == "literal-mismatch" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:error)
      expect(err.message).to eq(
        'literal "not-an-email" does not match :email (\A[^\s@]+@[^\s@]+\z)'
      )
    end

    it "validates UUIDs against the configured pattern" do
      diags = plugin_diagnostics(run_plugin('validate(:uuid, "a1b2c3d4-1111-2222-3333-444455556666")'))
      expect(diags.first.rule).to eq("literal-match")
    end
  end

  describe "engine collaboration through LiteralStringFolding" do
    it "sees `\"a\" + \"b\"` as a literal because Rigor folds it" do
      diags = plugin_diagnostics(run_plugin('validate(:email, "user" + "@example.com")'))
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
      diags = plugin_diagnostics(run_plugin('validate(:email, "user@#{"example.com"}")')) # rubocop:disable Lint/InterpolationCheck
      info = diags.find { |d| %w[literal-match literal-unknown].include?(d.rule) }
      expect(info).not_to be_nil
    end
  end

  describe "non-literal arguments stay silent" do
    it "does not emit when the value is a method call" do
      diags = plugin_diagnostics(run_plugin("validate(:email, ARGV.first)"))
      expect(diags).to be_empty
    end

    it "does not emit when the value is a local read" do
      diags = plugin_diagnostics(run_plugin(<<~RUBY))
        external = ARGV.first || "fallback"
        validate(:email, external)
      RUBY
      expect(diags).to be_empty
    end
  end

  describe "unknown-pattern diagnostics" do
    it "errors when the pattern name is not declared in config" do
      diags = plugin_diagnostics(run_plugin('validate(:zip, "12345")'))
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
      diags = plugin_diagnostics(run_plugin('validate("email", "user@example.com")'))
      expect(diags).to be_empty
    end

    it "ignores calls with fewer than 2 arguments" do
      diags = plugin_diagnostics(run_plugin("validate(:email)"))
      expect(diags).to be_empty
    end

    it "ignores calls to a different method name" do
      diags = plugin_diagnostics(run_plugin('check(:email, "user@example.com")'))
      expect(diags).to be_empty
    end
  end

  describe "configurable method name" do
    it "treats `check` as the validator when configured" do
      config = plugin_config.merge("method_name" => "check")
      diags = plugin_diagnostics(run_plugin('check(:email, "not-an-email")', config: config))
      err = diags.find { |d| d.rule == "literal-mismatch" }
      expect(err).not_to be_nil
    end
  end
end
