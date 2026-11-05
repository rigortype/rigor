# frozen_string_literal: true

require "spec_helper"

# ADR-129 WD1 — the four advisory tables on `Scope` are bound Tables: every entry write and read goes through Scope and
# is journaled while a capture is open, keyed on `[store, node]`, so a later `type_of` memo can validate the reads and
# replay the writes of a stored computation.
RSpec.describe "Scope's advisory tables as bound journaled Tables (ADR-129 stage 2)" do
  let(:state) { Rigor::TypingState.current }
  let(:scope) { Rigor::Scope.empty }
  let(:node) { Prism.parse("foo").value.statements.body.first }
  let(:absent) { Rigor::TypingState::ABSENT }

  def slot(name) = Rigor::TypingState.slot(name).index

  def captured
    state.open_capture
    begin
      yield
    ensure
      _, records = state.close_capture
    end
    records.each_slice(4).to_a
  end

  it "declares the four tables as bound Tables" do
    %i[dynamic_origins void_origins plugin_typed_calls optimistic_origins].each do |name|
      declared = Rigor::TypingState.slot(name)
      expect([declared.kind, declared.bound]).to eq([:table, true])
    end
  end

  {
    dynamic_origins: %i[record_dynamic_origin dynamic_origin cause],
    void_origins: %i[record_void_origin void_origin origin],
    optimistic_origins: %i[record_optimistic_origin optimistic_origin cause]
  }.each do |table, (writer, reader, value)|
    it "journals #{table}: a miss as ABSENT, the write, and the read of the written entry" do
      store = scope.public_send(table)
      records = captured do
        expect(scope.public_send(reader, node)).to be_nil
        scope.public_send(writer, node, value)
        expect(scope.public_send(reader, node)).to eq(value)
      end
      expect(records).to eq(
        [
          [:read, slot(table), [store, node], absent],
          [:write, slot(table), [store, node], value],
          [:read, slot(table), [store, node], value]
        ]
      )
    end
  end

  it "journals plugin_typed_calls through record_plugin_typed_call and plugin_typed_call?" do
    store = scope.plugin_typed_calls
    records = captured do
      expect(scope.plugin_typed_call?(node)).to be(false)
      scope.record_plugin_typed_call(node)
      expect(scope.plugin_typed_call?(node)).to be(true)
    end
    table = slot(:plugin_typed_calls)
    expect(records).to eq(
      [[:read, table, [store, node], absent], [:write, table, [store, node], true], [:read, table, [store, node], true]]
    )
  end

  it "names the isolated copy, not the original, after with_isolated_side_tables" do
    isolated = scope.with_isolated_side_tables
    records = captured { isolated.record_dynamic_origin(node, :cause) }
    expect(records.map { |record| record[2][0] }).to all(equal(isolated.dynamic_origins))
    expect(isolated.dynamic_origins).not_to equal(scope.dynamic_origins)
  end

  it "logs nothing while no capture is open" do
    scope.record_dynamic_origin(node, :cause)
    scope.dynamic_origin(node)
    expect(captured { nil }).to eq([])
  end
end
