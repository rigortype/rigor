# frozen_string_literal: true

require "spec_helper"
require "rigor/plugin/bundled_catalog"

RSpec.describe Rigor::Plugin::BundledCatalog do
  it "reads each bundled plugin's declared target gems off its manifest" do
    entries = described_class.entries

    expect(entries.map(&:gem_name)).to include("rigor-activerecord", "rigor-rspec", "rigor-factorybot")
    expect(entries.find { |e| e.gem_name == "rigor-rspec" }.target_gems).to eq(["rspec-core"])
  end

  it "omits a plugin that models no gem" do
    expect(described_class.entries.map(&:gem_name)).not_to include("rigor-typescript-utility-types")
  end

  it "indexes by gem name, including a plugin whose target is a different gem" do
    expect(described_class.for_gem("railties").map(&:gem_name))
      .to include("rigor-railties", "rigor-rails-routes")
    expect(described_class.for_gem("no-such-gem")).to be_empty
  end
end
