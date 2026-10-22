# frozen_string_literal: true

require "spec_helper"

# Issue #476 — the lazy, read-only environment view the synthetic-method scan's Tier B half reads.
RSpec.describe Rigor::Analysis::Runner::ScanEnvironment do
  let(:environment) { instance_double(Rigor::Environment, rbs_loader: :loader, class_ordering: :subclass) }

  it "builds nothing until it is asked a question" do
    builds = 0
    described_class.new do
      builds += 1
      environment
    end

    expect(builds).to eq(0)
  end

  it "builds once and forwards both questions the scanner asks" do
    builds = 0
    view = described_class.new do
      builds += 1
      environment
    end

    expect([view.rbs_loader, view.class_ordering("A", "B"), view.rbs_loader]).to eq(%i[loader subclass loader])
    expect(builds).to eq(1)
  end

  it "answers 'no loader' and 'unknown' when the build raises, and does not retry" do
    attempts = 0
    view = described_class.new do
      attempts += 1
      raise "no RBS here"
    end

    expect([view.rbs_loader, view.class_ordering("A", "B"), view.rbs_loader]).to eq([nil, :unknown, nil])
    expect(attempts).to eq(1)
  end
end
