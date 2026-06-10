# frozen_string_literal: true

require "prism"

RSpec.describe Rigor::Inference::FlowTracer do
  def evaluate_recorded(source)
    root = Prism.parse(source).value
    scope = Rigor::Scope.empty
    result = nil
    events = described_class.record { result = scope.evaluate(root) }
    [events, result]
  end

  it "is inactive outside a record block" do
    expect(described_class.active?).to be(false)
  end

  it "records bind events when locals enter the scope" do
    events, = evaluate_recorded("a = 1\nb = a\n")
    binds = events.select { |e| e.kind == :bind }

    expect(binds.map { |e| e.data[:name] }).to eq(%w[a b])
    expect(binds.first.data[:type]).to eq("1")
  end

  it "records dispatch and union events for a branch-fed operator call" do
    events, = evaluate_recorded("a = 1\nb = a + (rand == 0 ? 1 : 2)\n")

    dispatches = events.select { |e| e.kind == :dispatch }
    plus = dispatches.find { |e| e.data[:method] == "+" }
    expect(plus).not_to be_nil
    expect(plus.data[:resolved]).to be(true)
    expect(plus.data[:receiver]).to eq("1")

    unions = events.select { |e| e.kind == :union }
    expect(unions.map { |e| e.data[:type] }).to include("1 | 2")
  end

  it "brackets every expression with enter/result pairs carrying locations" do
    events, = evaluate_recorded("a = 1\n")
    enters = events.select { |e| e.kind == :enter }
    results = events.select { |e| e.kind == :result }

    expect(enters.size).to eq(results.size)
    expect(enters.map { |e| e.data[:node] }).to include("IntegerNode")
    expect(results.find { |e| e.data[:node] == "IntegerNode" }.data[:type]).to eq("1")
    expect(enters.first.location).to include(:start_line, :start_column, :end_offset)
  end

  it "does not change the inferred result (observational only)" do
    source = "a = 1\nb = a + (rand == 0 ? 1 : 2)\n"
    root = Prism.parse(source).value
    plain_type, = Rigor::Scope.empty.evaluate(root)
    _events, traced = evaluate_recorded(source)

    expect(traced.first).to eq(plain_type)
  end

  it "restores the previous recorder and deactivates after the block" do
    described_class.record { expect(described_class.active?).to be(true) }
    expect(described_class.active?).to be(false)
    expect(Thread.current[:__rigor_flow_tracer__]).to be_nil
  end
end
