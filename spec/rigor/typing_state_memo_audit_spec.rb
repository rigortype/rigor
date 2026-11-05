# frozen_string_literal: true

require "spec_helper"

# ADR-129 WD1 / G2 — every Memo slot is wired to `MemoAudit.check`: its `audit:` labels name the hit sites that
# recompute and compare under `RIGOR_MEMO_AUDIT=1`, and each label belongs to one slot. Stage 2 wired them group by
# group; the last, `ancestor_constant_scopes`, was wired with its key fix (#2848), so the ratchet is gone.
#
# Every Memo, and every Table a computation fills (`computed:`, the ADR-84 return memo), is wired to the key audit too:
# each label names a `MemoAudit.key_audit` site, the miss whose Frame reads the audit compares with the key.
RSpec.describe "ADR-129 Memo slots and MemoAudit" do
  def memos = Rigor::TypingState.slots.select { |slot| slot.kind == :memo }

  def audit_labels_in_lib = labels_in_lib(/MemoAudit\.check\(\s*"([^"]+)"/)

  def key_audit_labels_in_lib = labels_in_lib(/MemoAudit\.key_audit\(\s*"([^"]+)"/)

  def labels_in_lib(pattern)
    Dir.glob(File.expand_path("../../lib/**/*.rb", __dir__)).flat_map do |path|
      File.read(path).scan(pattern).flatten
    end.to_set
  end

  # The check labels with no key-audit site of their own, each with why: a hit site whose miss is another label's.
  def shared_misses
    {
      "definers index layers" => "no miss computes it: `record_layers` stores the pair the indexer merged",
      "definers index seed alt" => "the seed's miss fills both ways",
      "method definers index alt" => "the current way's miss fills both ways",
      "void tail origin" => "its miss is the walk's"
    }
  end

  def computed_tables = Rigor::TypingState.slots.select(&:computed)

  it "holds every Memo slot to audit labels" do
    unwired = memos.reject(&:audit).map(&:name).sort
    expect(unwired).to be_empty, <<~MESSAGE
      ADR-129 WD1/G2: a Memo slot declares `audit:`, the MemoAudit.check labels its hits go through. Wire a new Memo
      before it lands.
    MESSAGE
  end

  it "finds each declared audit label at a MemoAudit.check site in lib" do
    labels = audit_labels_in_lib
    missing = memos.flat_map { |slot| Array(slot.audit).map { |label| [slot.name, label] } }
                   .reject { |_, label| labels.include?(label) }
    expect(missing).to be_empty
  end

  it "wires each audited Memo label, and each computed Table, to a MemoAudit.key_audit site" do
    labels = key_audit_labels_in_lib
    unwired = memos.flat_map { |slot| Array(slot.audit) }.reject { |label| shared_misses.key?(label) }
    unwired += computed_tables.map(&:computed)
    expect(unwired.reject { |label| labels.include?(label) }).to be_empty, <<~MESSAGE
      ADR-129 WD1/G2: a Memo's miss, and a computed Table's, runs under MemoAudit.key_audit with its slot's label, so
      the key audit compares the Frames the miss reads with the key.
    MESSAGE
  end

  # A site that declares forced Frames, gaps or carried Frames must open that declaration on a hit as well: a hit's
  # MemoAudit.check recomputes suspended, and only key_audit opens the declaration then, so an enclosing miss's verdict
  # would otherwise depend on whether this memo hit.
  it "routes the hit check of every declared key-audit site through key_audit" do
    sources = Dir.glob(File.expand_path("../../lib/**/*.rb", __dir__)).map { |path| File.read(path) }
    declared = sources.flat_map { |text| text.scan(/MemoAudit\.key_audit\(\s*"([^"]+)",\s*[A-Z][A-Z_]+/).flatten }.uniq
    unrouted = declared.select do |label|
      checks = sources.flat_map { |text| text.scan(/MemoAudit\.check\(\s*"#{Regexp.escape(label)}".*?\n(?:.*\n){0,2}/) }
      checks.any? { |check| !check.include?("MemoAudit.key_audit(\"#{label}\"") }
    end
    expect(declared).to include("return memo", "resolved census")
    expect(unrouted).to be_empty
  end

  it "names the return memo a computed Table" do
    expect(computed_tables.map(&:name)).to eq([:user_method_return_memo])
  end

  it "gives each key-audit label to a slot, and keeps the shared-miss list to labels that exist" do
    declared = memos.flat_map { |slot| Array(slot.audit) } + computed_tables.map(&:computed)
    expect(key_audit_labels_in_lib.to_a - declared).to be_empty
    expect(shared_misses.keys - declared).to be_empty
    expect(shared_misses.keys & key_audit_labels_in_lib.to_a).to be_empty
  end

  # A label claimed by two slots would let one slot borrow another's check site and stay unwired.
  it "gives each audit label to one slot" do
    claims = memos.flat_map { |slot| Array(slot.audit).map { |label| [label, slot.name] } }
    shared = claims.group_by(&:first).select { |_, owners| owners.size > 1 }.keys
    expect(shared).to be_empty
  end
end
