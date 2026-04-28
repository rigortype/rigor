# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::FallbackTracer do
  let(:tracer) { described_class.new }

  def make_event(node_class: Prism::CallNode, family: :prism)
    Rigor::Inference::Fallback.new(
      node_class: node_class,
      location: nil,
      family: family,
      inner_type: Rigor::Type::Combinator.untyped
    )
  end

  describe "initial state" do
    it "starts empty" do
      expect(tracer).to be_empty
      expect(tracer.size).to eq(0)
      expect(tracer.events).to eq([])
    end
  end

  describe "#record_fallback" do
    it "appends events in insertion order" do
      a = make_event(node_class: Prism::CallNode, family: :prism)
      b = make_event(node_class: Prism::IfNode, family: :prism)
      tracer.record_fallback(a)
      tracer.record_fallback(b)
      expect(tracer.events).to eq([a, b])
    end

    it "rejects non-Fallback arguments" do
      expect { tracer.record_fallback(:not_a_fallback) }.to raise_error(ArgumentError)
    end

    it "returns self for chaining" do
      expect(tracer.record_fallback(make_event)).to equal(tracer)
    end
  end

  describe "#events" do
    it "returns a frozen snapshot" do
      tracer.record_fallback(make_event)
      snapshot = tracer.events
      expect(snapshot).to be_frozen
    end

    it "snapshots independently of subsequent mutations" do
      tracer.record_fallback(make_event(node_class: Prism::CallNode))
      first = tracer.events
      tracer.record_fallback(make_event(node_class: Prism::IfNode))
      expect(first.size).to eq(1)
      expect(tracer.events.size).to eq(2)
    end
  end

  describe "#kinds" do
    it "returns the unique node classes seen" do
      tracer.record_fallback(make_event(node_class: Prism::CallNode))
      tracer.record_fallback(make_event(node_class: Prism::CallNode))
      tracer.record_fallback(make_event(node_class: Prism::IfNode))
      expect(tracer.kinds).to contain_exactly(Prism::CallNode, Prism::IfNode)
    end
  end

  describe "#families" do
    it "returns the unique families seen" do
      tracer.record_fallback(make_event(family: :prism))
      tracer.record_fallback(make_event(family: :virtual))
      tracer.record_fallback(make_event(family: :prism))
      expect(tracer.families).to contain_exactly(:prism, :virtual)
    end
  end

  describe "Enumerable" do
    it "is enumerable in insertion order" do
      a = make_event(node_class: Prism::CallNode)
      b = make_event(node_class: Prism::IfNode)
      tracer.record_fallback(a)
      tracer.record_fallback(b)
      expect(tracer.map(&:node_class)).to eq([Prism::CallNode, Prism::IfNode])
    end

    it "exposes #find / #count via Enumerable" do
      tracer.record_fallback(make_event(node_class: Prism::CallNode))
      tracer.record_fallback(make_event(node_class: Prism::IfNode))
      expect(tracer.count).to eq(2)
      expect(tracer.find { |e| e.node_class == Prism::IfNode }).not_to be_nil
    end
  end

  describe "#clear" do
    it "drops all events" do
      tracer.record_fallback(make_event)
      tracer.record_fallback(make_event)
      tracer.clear
      expect(tracer).to be_empty
    end
  end
end
