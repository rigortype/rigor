# frozen_string_literal: true

require "spec_helper"

# ADR-129 stage 2 — the effects collector's call-site decisions and the self-call recorder's misses are bound Tables:
# a record is journaled while a capture is open (a read of the key, then the first write), and refuses nothing.
RSpec.describe "the effects and self-call records as journaled bound Tables (ADR-129 stage 2)" do
  let(:state) { Rigor::TypingState.current }
  let(:absent) { Rigor::TypingState::ABSENT }
  let(:node) { Prism.parse("a.b").value.statements.body.first }

  def slot(name) = Rigor::TypingState.slot(name).index

  def captured
    state.open_capture
    begin
      yield
    ensure
      refused, records = state.close_capture
    end
    [refused, records.each_slice(4).to_a]
  end

  it "journals an effects call-site decision once, and a re-query as a read of the pinned record" do
    scope = Rigor::Scope.empty(source_path: "probe.rb")
    receiver = Rigor::Type::Combinator.nominal_of("String")
    result = nil
    Rigor::Effects::Collector.collect_for("probe.rb") do
      result = captured do
        Rigor::Effects::Collector.record_call(node, receiver, scope)
        Rigor::Effects::Collector.record_call(node, receiver, scope)
      end
    end
    refused, records = result
    table = slot(:effects_calls)
    store = records.first[2][0]
    pinned = records[1][3]
    expect(refused).to be(false)
    expect(records).to eq(
      [[:read, table, [store, node], absent], [:write, table, [store, node], pinned],
       [:read, table, [store, node], pinned]]
    )
    expect(pinned.receiver_class).to eq("String")
  end

  it "journals an unresolved verdict as a read and a write of the site's record" do
    scope = Rigor::Scope.empty(source_path: "probe.rb")
    result = nil
    Rigor::Effects::Collector.collect_for("probe.rb") do
      Rigor::Effects::Collector.record_call(node, Rigor::Type::Combinator.nominal_of("String"), scope)
      result = captured { Rigor::Effects::Collector.record_unresolved(node, "probe.rb") }
    end
    refused, records = result
    expect(refused).to be(false)
    expect(records.map(&:first)).to eq(%i[read write])
    expect(records.last[3].resolved).to be(false)
  end

  it "journals an unresolved verdict on a site never recorded as a read of ABSENT and no write" do
    result = nil
    Rigor::Effects::Collector.collect_for("probe.rb") do
      result = captured { Rigor::Effects::Collector.record_unresolved(node, "probe.rb") }
    end
    refused, records = result
    expect(refused).to be(false)
    expect(records).to eq([[:read, slot(:effects_calls), [records.first[2][0], node], absent]])
  end

  it "declares the self-call recorder's Frame as holding a bound Table's store" do
    expect(Rigor::TypingState.slot(:self_call_resolution_recorder).contents).to eq(:table)
  end

  it "replays a self-call write through the accumulator, in record order" do
    accumulator = Rigor::Analysis::SelfCallResolutionRecorder::Accumulator.new("probe.rb")
    calls = %i[a b].map do |name|
      Rigor::Analysis::SelfCallResolutionRecorder::UnresolvedSelfCall.new(
        class_name: "Foo", method_name: name, node: node, path: "probe.rb", line: 1, column: 1
      )
    end
    calls.each { |call| accumulator[call] = true }
    accumulator[calls.first] = true
    expect(accumulator.calls).to eq(calls)
    expect(accumulator.fetch(calls.last, absent)).to be(true)
  end

  it "journals a self-call miss's first record as a write, and a repeat of the tuple as a read only" do
    miss = { class_name: "Foo", method_name: :bar, node: node, path: "probe.rb", line: 1, column: 1 }
    result = nil
    Rigor::Analysis::SelfCallResolutionRecorder.record_for("probe.rb") do
      result = captured do
        Rigor::Analysis::SelfCallResolutionRecorder.record(**miss)
        Rigor::Analysis::SelfCallResolutionRecorder.record(**miss)
      end
    end
    refused, records = result
    table = slot(:self_call_misses)
    expect(refused).to be(false)
    expect(records.map { |kind, slot_index, _, value| [kind, slot_index, value] }).to eq(
      [[:read, table, absent], [:write, table, true], [:read, table, true]]
    )
  end
end
