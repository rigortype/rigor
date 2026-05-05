# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Services do
  it "exposes the four core analyzer services" do
    services = described_class.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new,
      cache_store: nil
    )

    expect(services.reflection).to eq(Rigor::Reflection)
    expect(services.type).to eq(Rigor::Type::Combinator)
    expect(services.configuration).to be_a(Rigor::Configuration)
    expect(services.cache_store).to be_nil
  end

  it "is frozen after construction" do
    services = described_class.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
    expect(services).to be_frozen
  end
end
