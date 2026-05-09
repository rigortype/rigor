# frozen_string_literal: true

require "json"
require "yaml"

require "rigor/configuration"
require "rigor/configuration/severity_profile"
require "rigor/analysis/check_rules"
require "rigor/plugin/trust_policy"

RSpec.describe "Rigor configuration JSON Schema" do # rubocop:disable RSpec/DescribeClass
  let(:schema_path) { File.expand_path("../../schemas/rigor-config.schema.json", __dir__) }
  let(:schema) { JSON.parse(File.read(schema_path, encoding: "UTF-8")) }

  it "is a valid JSON Schema 2020-12 envelope" do
    expect(schema).to include(
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "additionalProperties" => false
    )
    expect(schema["$id"]).to be_a(String)
    expect(schema["title"]).to be_a(String)
    expect(schema["description"]).to be_a(String)
  end

  it "covers every key in Rigor::Configuration::DEFAULTS plus the includes:/`#schema` extras" do
    schema_keys = schema.fetch("properties").keys.to_set
    default_keys = Rigor::Configuration::DEFAULTS.keys.to_set

    missing = default_keys - schema_keys
    expect(missing).to(be_empty, "schema is missing keys present in Configuration::DEFAULTS: #{missing.inspect}")

    # `includes` is a load-time directive, not part of DEFAULTS, but
    # it MUST be in the schema so editors stop flagging it.
    expect(schema_keys).to include("includes")
  end

  it "constrains severity_profile to the runtime VALID_PROFILES set" do
    enum = schema.dig("properties", "severity_profile", "enum")
    expect(enum.to_set(&:to_sym)).to(
      eq(Rigor::Configuration::SeverityProfile::VALID_PROFILES.to_set)
    )
  end

  it "constrains severity_overrides values to the runtime VALID_SEVERITIES set" do
    enum = schema.dig("properties", "severity_overrides", "additionalProperties", "enum")
    expect(enum.to_set(&:to_sym)).to(
      eq(Rigor::Configuration::SeverityProfile::VALID_SEVERITIES.to_set)
    )
  end

  it "constrains plugins_io.network to the runtime VALID_NETWORK_POLICIES set" do
    enum = schema.dig("properties", "plugins_io", "properties", "network", "enum")
    expect(enum.to_set(&:to_sym)).to(
      eq(Rigor::Plugin::TrustPolicy::VALID_NETWORK_POLICIES.to_set)
    )
  end

  it "documents allowed_url_hosts under plugins_io" do
    schema_obj = schema.dig("properties", "plugins_io", "properties", "allowed_url_hosts")
    expect(schema_obj).not_to be_nil
    expect(schema_obj["type"]).to eq("array")
    expect(schema_obj.dig("items", "type")).to eq("string")
  end

  it "ships the schema reference comment on the committed `.rigor.dist.yml`" do
    dist = File.read(File.expand_path("../../.rigor.dist.yml", __dir__))
    expect(dist).to include("yaml-language-server: $schema=schemas/rigor-config.schema.json")
  end

  it "has the `rigor init` template carry the same schema reference" do
    require "rigor/cli"
    cli = Rigor::CLI.new([], out: StringIO.new, err: StringIO.new)
    template = cli.send(:init_template)
    expect(template).to include("yaml-language-server: $schema=")
    expect(template).to include("rigor-config.schema.json")
  end

  it "shapes plugin entries as either gem-name string or hash with a required `gem` key" do
    plugin_entry = schema.dig("$defs", "pluginEntry", "oneOf")
    expect(plugin_entry).to be_an(Array)
    expect(plugin_entry.map { |alt| alt["type"] }).to contain_exactly("string", "object")

    object_alt = plugin_entry.find { |alt| alt["type"] == "object" }
    expect(object_alt["required"]).to eq(["gem"])
    expect(object_alt["properties"].keys).to contain_exactly("gem", "id", "config")
  end

  it "constrains dependencies.budget_per_gem to the runtime MIN/MAX bounds and default" do
    schema_obj = schema.dig("properties", "dependencies", "properties", "budget_per_gem")
    expect(schema_obj).not_to be_nil
    expect(schema_obj["type"]).to eq("integer")
    expect(schema_obj["minimum"]).to eq(Rigor::Configuration::Dependencies::MIN_BUDGET_PER_GEM)
    expect(schema_obj["maximum"]).to eq(Rigor::Configuration::Dependencies::MAX_BUDGET_PER_GEM)
    expect(schema_obj["default"]).to eq(Rigor::Configuration::Dependencies::DEFAULT_BUDGET_PER_GEM)
  end
end
