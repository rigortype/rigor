# frozen_string_literal: true

require "spec_helper"

# `Configuration::Defaults` holds the defaults table and the constants that describe the keys; `Configuration`
# binds each public one under its own name. Plain data throughout: nothing here loads a file or builds a
# `Configuration`.
RSpec.describe Rigor::Configuration::Defaults do
  def frozen_throughout?(value)
    return false unless value.frozen?

    case value
    when Hash then value.all? { |key, nested| key.frozen? && frozen_throughout?(nested) }
    when Array then value.all? { |element| frozen_throughout?(element) }
    else true
    end
  end

  # Names `Configuration` readers resolve (`Configuration::DEFAULTS`, `::KNOWN_KEYS`, ...).
  let(:public_names) do
    %i[DISCOVERY_ORDER DEFAULT_PATH DEFAULT_EFFECTS_SNAPSHOT_PATH BUILTIN_EXCLUDES
       CONVENTIONAL_TEST_PATHS DEFAULTS CONFIGURABLE_PLUGIN_ISOLATIONS RESERVED_NAMESPACES
       KNOWN_KEYS]
  end

  it "is the object `Configuration` answers under each name, not a copy" do
    public_names.each do |name|
      expect(Rigor::Configuration.const_get(name)).to equal(described_class.const_get(name)), name.to_s
    end
  end

  it "keeps DEFAULTS frozen at every depth and Ractor-shareable" do
    expect(frozen_throughout?(described_class::DEFAULTS)).to be(true)
    expect(Ractor.shareable?(described_class::DEFAULTS)).to be(true)
  end

  it "freezes every other constant" do
    public_names.each do |name|
      expect(Ractor.shareable?(described_class.const_get(name))).to be(true), name.to_s
    end
  end

  it "discovers the developer's local override before the committed default" do
    expect(described_class::DISCOVERY_ORDER).to eq(%w[.rigor.yml .rigor.dist.yml])
    expect(described_class::DEFAULT_PATH).to eq(".rigor.yml")
  end

  it "lists the DEFAULTS keys, `includes`, then the reserved namespaces as the known keys" do
    expect(described_class::KNOWN_KEYS)
      .to eq(described_class::DEFAULTS.keys + %w[includes] + described_class::RESERVED_NAMESPACES)
  end

  it "names the isolation strategies a file may select, without `ruby_box`" do
    expect(described_class::CONFIGURABLE_PLUGIN_ISOLATIONS).to eq(%w[none process])
  end

  it "ships the built-in exclusions and the conventional test roots in their documented order" do
    expect(described_class::BUILTIN_EXCLUDES).to eq(%w[**/vendor/bundle/** **/.bundle/** **/node_modules/**])
    expect(described_class::CONVENTIONAL_TEST_PATHS).to eq(%w[spec test])
  end
end
