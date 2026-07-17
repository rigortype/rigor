# frozen_string_literal: true

require "json"
require "yaml"

require "rigor/configuration"
require "rigor/configuration/severity_profile"
require "rigor/analysis/check_rules"
require "rigor/plugin/trust_policy"

RSpec.describe "Rigor configuration JSON Schema" do
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

    # `includes` is a load-time directive, not part of DEFAULTS, but it MUST be in the schema so editors stop flagging
    # it.
    expect(schema_keys).to include("includes")
  end

  # The axis above covers TOP-LEVEL keys only, and the nested surface drifted underneath it: `cache.max_bytes` and
  # `cache.validation` were in DEFAULTS and documented in the manual while the schema declared only `cache.path` and
  # closed the object with `additionalProperties: false` — so the schema REJECTED two documented keys, and nothing
  # failed. Every nested object in the schema is closed, which turns a missing entry from a gap into a rejection
  # (ADR-99 WD3).
  it "covers every nested key in Rigor::Configuration::DEFAULTS" do
    missing = []
    walk = lambda do |defaults, schema_node, path|
      defaults.each do |key, value|
        node = schema_node.dig("properties", key)
        if node.nil?
          missing << "#{path}#{key}"
          next
        end
        walk.call(value, node, "#{path}#{key}.") if value.is_a?(Hash) && !value.empty?
      end
    end
    walk.call(Rigor::Configuration::DEFAULTS, schema, "")

    expect(missing).to(
      be_empty,
      "Configuration::DEFAULTS keys with no schema entry: #{missing.inspect}. " \
      "Their parent object is `additionalProperties: false`, so a user setting them is told their valid config is " \
      "invalid. The schema is a source of truth, not documentation of the loader — see docs/internal-spec/config.md."
    )
  end

  # A RESERVED namespace is by definition NOT a DEFAULTS key, so the two axes above can never reach it. That blind
  # spot is why `rigor_rs:` — which the sibling implementation has shipped since its ADR-0036, and which our schema is
  # the authoritative declaration of — was rejected by our own schema, including the copy the sibling vendors from us.
  # This is a separate axis, not a widening of the DEFAULTS one (ADR-99 WD3).
  it "declares every reserved namespace, and reserves every schema-declared reservation" do
    reserved = Rigor::Configuration::RESERVED_NAMESPACES.to_set
    declared = schema.fetch("properties").select { |_, v| v["description"].to_s.start_with?("RESERVED") }.keys.to_set

    expect(reserved - declared).to(
      be_empty,
      "reserved namespaces with no schema entry: #{(reserved - declared).to_a.inspect}. The top level is " \
      "`additionalProperties: false`, so an unreserved namespace is REJECTED for every user sharing one .rigor.yml " \
      "across implementations."
    )
    orphaned = (declared - reserved).to_a
    expect(orphaned).to(
      be_empty,
      "schema declares reservations absent from Configuration::RESERVED_NAMESPACES: #{orphaned.inspect}"
    )
  end

  it "constrains a reserved namespace's contents but never its runtime meaning" do
    rigor_rs = schema.dig("properties", "rigor_rs")
    expect(rigor_rs["type"]).to eq("object")
    # Authoritative, not a mirror: an undeclared key here means the sibling shipped something the reserve never
    # granted, which is what the reserve pipeline exists to prevent (ADR-99 WD2).
    expect(rigor_rs["additionalProperties"]).to be(false)
    # ...but NOT an enum: the sibling's grammar is `require`/`auto`/`off` OR any ruby binary path, so an enum would
    # reject every path form. A reserve that lies about the shape is worse than no reserve.
    ruby = rigor_rs.dig("properties", "ruby")
    expect(ruby["type"]).to eq("string")
    expect(ruby).not_to have_key("enum")
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

  # The example above checks the SHAPE of the init-written URL, which is why it stayed green while the URL pointed at
  # a nonexistent org for months: the file it names 404s, and an unreachable schema is indistinguishable from a schema
  # with no complaints, so every project created by `rigor init` silently had no validation at all.
  #
  # This pins the two spellings to one value instead. What it cannot check offline is that the URL RESOLVES — that is
  # the half a reviewer still owns when either spelling changes.
  it "writes the same schema location `$id` claims" do
    require "rigor/cli"
    cli = Rigor::CLI.new([], out: StringIO.new, err: StringIO.new)

    expect(Rigor::CLI::CONFIG_SCHEMA_URL).to eq(schema["$id"])
    expect(cli.send(:init_template)).to include("$schema=#{Rigor::CLI::CONFIG_SCHEMA_URL}")
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
