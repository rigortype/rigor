# frozen_string_literal: true

# Integration spec for `examples/rigor-deprecations/`.
# Reference coverage for config-driven plugin rules.

require "spec_helper"

DEPRECATIONS_PLUGIN_LIB = File.expand_path("../../../examples/rigor-deprecations/lib", __dir__)
$LOAD_PATH.unshift(DEPRECATIONS_PLUGIN_LIB) unless $LOAD_PATH.include?(DEPRECATIONS_PLUGIN_LIB)
require "rigor-deprecations"

RSpec.describe "examples/rigor-deprecations" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Deprecations }
  let(:requirer) do
    lambda do |_name|
      Rigor::Plugin.register(plugin_class)
      true
    end
  end

  def run_plugin(source, methods:)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.rb"), source.end_with?("\n") ? source : "#{source}\n")
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "plugins" => [{ "gem" => "rigor-deprecations", "config" => { "methods" => methods } }]
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
    result.diagnostics.select { |d| d.source_family == "plugin.deprecations" }
  end

  describe "with a receiver-pinned entry" do
    let(:methods) do
      [{
        "method" => "find_by_sql",
        "receiver" => "User",
        "replacement" => "where(...).to_sql or sanitize_sql",
        "since" => "v6.0"
      }]
    end

    it "warns at matching receiver+method calls" do
      diags = plugin_diagnostics(run_plugin('User.find_by_sql("SELECT * FROM users")', methods: methods))
      expect(diags.size).to eq(1)
      expect(diags.first.severity).to eq(:warning)
      expect(diags.first.message).to eq(
        "`User.find_by_sql` is deprecated " \
        "(since v6.0; use: where(...).to_sql or sanitize_sql)"
      )
    end

    it "stays silent for the same method on a different receiver" do
      diags = plugin_diagnostics(run_plugin('Account.find_by_sql("SELECT * FROM accounts")', methods: methods))
      expect(diags).to be_empty
    end

    it "stays silent for an unrelated method on the same receiver" do
      diags = plugin_diagnostics(run_plugin("User.where(id: 1)", methods: methods))
      expect(diags).to be_empty
    end
  end

  describe "with a receiver-omitted entry" do
    let(:methods) do
      [{ "method" => "silence_warnings", "since" => "v7.0", "replacement" => "Warning[:deprecated] = false" }]
    end

    it "matches a no-receiver call" do
      diags = plugin_diagnostics(run_plugin("silence_warnings { puts 1 }", methods: methods))
      expect(diags.first.message).to start_with("`silence_warnings` is deprecated")
    end

    it "matches the same method on any receiver too" do
      diags = plugin_diagnostics(run_plugin("Kernel.silence_warnings { puts 1 }", methods: methods))
      expect(diags.first.message).to start_with("`silence_warnings` is deprecated")
    end
  end

  describe "message formatting" do
    it "elides the `since` clause when not configured" do
      diags = plugin_diagnostics(run_plugin(
                                   "User.legacy_call",
                                   methods: [{ "method" => "legacy_call", "receiver" => "User",
                                               "replacement" => "modern_call" }]
                                 ))
      expect(diags.first.message).to eq("`User.legacy_call` is deprecated (use: modern_call)")
    end

    it "elides the `replacement` clause when not configured" do
      diags = plugin_diagnostics(run_plugin(
                                   "User.legacy_call",
                                   methods: [{ "method" => "legacy_call", "receiver" => "User", "since" => "v8.0" }]
                                 ))
      expect(diags.first.message).to eq("`User.legacy_call` is deprecated (since v8.0)")
    end

    it "drops the parenthesised tail when neither is configured" do
      diags = plugin_diagnostics(run_plugin(
                                   "User.legacy_call",
                                   methods: [{ "method" => "legacy_call", "receiver" => "User" }]
                                 ))
      expect(diags.first.message).to eq("`User.legacy_call` is deprecated")
    end
  end

  describe "deduplication" do
    it "emits at most one diagnostic per call site even if multiple entries match" do
      methods = [
        { "method" => "legacy", "since" => "v6.0" },
        { "method" => "legacy", "since" => "v7.0" }
      ]
      diags = plugin_diagnostics(run_plugin("legacy", methods: methods))
      expect(diags.size).to eq(1)
    end
  end

  describe "empty configuration" do
    it "stays completely silent when no methods are declared" do
      diags = plugin_diagnostics(run_plugin('User.find_by_sql("...")', methods: []))
      expect(diags).to be_empty
    end
  end
end
