# frozen_string_literal: true

require "spec_helper"

# ADR-129 WD1 / G2 — every Memo slot is wired to `MemoAudit.check`: its `audit:` labels name the hit sites that
# recompute and compare under `RIGOR_MEMO_AUDIT=1`, and each label belongs to one slot. Stage 2 wires the rest group by
# group; until then an unwired Memo sits in {#unaudited}, which only shrinks.
RSpec.describe "ADR-129 Memo slots and MemoAudit" do
  def memos = Rigor::TypingState.slots.select { |slot| slot.kind == :memo }

  # The Memo slots stage 2 has not wired yet. A wiring PR removes its slots here; a new Memo never joins.
  def unaudited
    %i[
      ancestor_constant_scopes deferred_definition_names method_alias_names project_method_names
      recorded_ancestor_constant_scopes resolution_chain toplevel_definition_rows
    ]
  end

  def audit_labels_in_lib
    Dir.glob(File.expand_path("../../lib/**/*.rb", __dir__)).flat_map do |path|
      File.read(path).scan(/MemoAudit\.check\(\s*"([^"]+)"/).flatten
    end.to_set
  end

  it "holds every Memo slot to audit labels or the stage-2 ratchet" do
    unwired = memos.reject(&:audit).map(&:name).sort
    expect(unwired).to eq(unaudited.sort), <<~MESSAGE
      ADR-129 WD1/G2: a Memo slot declares `audit:`, the MemoAudit.check labels its hits go through. Wire a new Memo
      before it lands; a wiring PR removes its slots from #unaudited.
    MESSAGE
  end

  it "finds each declared audit label at a MemoAudit.check site in lib" do
    labels = audit_labels_in_lib
    missing = memos.flat_map { |slot| Array(slot.audit).map { |label| [slot.name, label] } }
                   .reject { |_, label| labels.include?(label) }
    expect(missing).to be_empty
  end

  # A label claimed by two slots would let one slot borrow another's check site and stay unwired.
  it "gives each audit label to one slot" do
    claims = memos.flat_map { |slot| Array(slot.audit).map { |label| [label, slot.name] } }
    shared = claims.group_by(&:first).select { |_, owners| owners.size > 1 }.keys
    expect(shared).to be_empty
  end
end
