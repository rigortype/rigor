# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::IvarWriteCollector.diagnostics}, the collector's message builder and the divergence
# test it applies to each ivar's writes, on hand-built write lists: no runner. `collector_diagnostic_builders_spec.rb`
# pins the builder through the whole run; which writes the collector records is `rule_walk_equivalence_spec`'s and the
# runner specs' business.
#
# Each write is `{node:, type:, declared:, action:, method_name:}`, the fields the builder reads; `node` is a real
# `InstanceVariableWriteNode` so the row's location is the write's.
#
# Mutation-proved: each guard line (a `return` / `next` modifier) of `ivar_mismatch_diagnostics_for`,
# `separate_invocations?`, `declaration_admits?` and `ivar_class_for` was blanked in turn, and each `||` / `&&` operand
# of the two compound conditions was dropped in turn, and an example here failed, except this one, which no input
# distinguishes:
#
# - `return [] if writes.size < 2`: with one write the `writes[(canonical_index + 1)..]` slice is empty anyway, so the
#   result is the same `[]`; the guard only saves the scan.
RSpec.describe Rigor::Analysis::CheckRules::IvarWriteCollector do
  def type_for(spec)
    combinator = Rigor::Type::Combinator
    case spec
    when :nil then combinator.constant_of(nil)
    when :bool_false then combinator.constant_of(false)
    when :bool_true then combinator.constant_of(true)
    when :union then combinator.union(combinator.nominal_of("Integer"), combinator.nominal_of("String"))
    else combinator.nominal_of(spec)
    end
  end

  # One write per `specs` entry, each on its own line of one source, so a row's line says which write it is.
  def writes_for(*specs)
    source = specs.each_index.map { |i| "@x = #{i}\n" }.join
    nodes = Prism.parse(source).value.statements.body
    specs.each_with_index.map do |spec, i|
      extra = spec.is_a?(Array) ? spec.last : {}
      type = type_for(spec.is_a?(Array) ? spec.first : spec)
      { node: nodes[i], type: type, declared: nil, action: nil, method_name: :"m#{i}" }.merge(extra)
    end
  end

  def rows(*specs, class_name: "A")
    described_class.diagnostics("mem.rb", { class_name => { :@x => writes_for(*specs) } })
  end

  it "builds an error at the divergent write, naming the class, the ivar and both classes" do
    row = rows("Integer", "String").first

    expect([row.rule, row.severity, row.path, row.line, row.column, row.message]).to eq(
      [Rigor::Analysis::CheckRules::RULE_IVAR_WRITE_MISMATCH, :error, "mem.rb", 2, 1,
       "instance variable `@x' on A was previously assigned Integer; this write assigns String"]
    )
  end

  it "reports every later write that disagrees with the first, not the first itself" do
    expect(rows("Integer", "String", "Integer", "Symbol").map(&:line)).to eq([2, 4])
  end

  it "builds nothing for one write, or for writes that agree" do
    expect([rows("Integer"), rows("Integer", "Integer")]).to eq([[], []])
  end

  describe "the canonical write" do
    it "skips leading nil writes: the first concrete write is what later ones are compared with" do
      expect(rows(:nil, :nil, "Integer", "String").map(&:message)).to eq(
        ["instance variable `@x' on A was previously assigned Integer; this write assigns String"]
      )
    end

    it "builds nothing when every write is nil" do
      expect(rows(:nil, :nil)).to eq([])
    end

    it "builds nothing when the canonical write has no single concrete class" do
      expect(rows(:union, "Symbol")).to eq([])
    end

    it "tolerates a later nil write (the clearing idiom)" do
      expect(rows("Integer", :nil)).to eq([])
    end

    it "builds nothing for a later write that has no single concrete class" do
      expect(rows("Integer", :union)).to eq([])
    end

    it "treats `true` and `false` as one class" do
      expect([rows(:bool_false, :bool_true), rows(:bool_true, :bool_false)]).to eq([[], []])
    end

    it "names the merged boolean class `bool` when a boolean is the first write" do
      expect(rows(:bool_false, "String").map(&:message)).to eq(
        ["instance variable `@x' on A was previously assigned bool; this write assigns String"]
      )
    end

    it "names the merged boolean class `bool` when a boolean is the divergent write" do
      expect(rows("String", :bool_true).map(&:message)).to eq(
        ["instance variable `@x' on A was previously assigned String; this write assigns bool"]
      )
    end
  end

  describe "a declaration" do
    def declared_rows(declared)
      writes = writes_for("Integer", "String")
      writes.each { |w| w[:declared] = declared }
      described_class.diagnostics("mem.rb", { "A" => { :@x => writes } })
    end

    it "withholds a divergence the declaration admits on both writes" do
      expect(declared_rows(type_for(:union))).to eq([])
    end

    it "reports a divergence the declaration rejects on one write" do
      expect(declared_rows(type_for("Integer")).size).to eq(1)
    end

    it "reports a divergence no declaration admits" do
      expect(declared_rows(nil).size).to eq(1)
    end

    it "reads the declaration off the divergent write, not the canonical one" do
      writes = writes_for("Integer", "String")
      writes.first[:declared] = type_for(:union)

      expect(described_class.diagnostics("mem.rb", { "A" => { :@x => writes } }).size).to eq(1)
    end
  end

  describe "separate invocations (ADR-125)" do
    def action_rows(*specs)
      described_class.diagnostics("mem.rb", { "A" => { :@x => writes_for(*specs) } })
    end

    it "withholds a write whose every conflicting write is in another action" do
      expect(action_rows(["Integer", { action: true }], ["String", { action: true }])).to eq([])
    end

    it "reports when the divergent write is not in an action" do
      expect(action_rows(["Integer", { action: true }], ["String", { action: nil }]).size).to eq(1)
    end

    it "reports when a conflicting write is not in an action" do
      expect(action_rows(["Integer", { action: nil }], ["String", { action: true }]).size).to eq(1)
    end

    it "reports when the conflicting write is in the same method" do
      expect(action_rows(["Integer", { action: true, method_name: :a }],
                         ["String", { action: true, method_name: :a }]).size).to eq(1)
    end

    it "does not count a nil write, or one of no single class, as conflicting" do
      conflicting = [["Integer", { action: true }], [:nil, { action: nil }], [:union, { action: nil }],
                     ["String", { action: true }]]

      expect(action_rows(*conflicting)).to eq([])
    end

    it "does not count a write of the divergent write's own class as conflicting" do
      expect(action_rows(["Integer", { action: true }], ["String", { action: nil }],
                         ["Symbol", { action: true }]).size).to eq(2)
    end
  end

  it "walks classes then ivars in the order given" do
    writes = writes_for("Integer", "String")
    rows = described_class.diagnostics(
      "mem.rb", { "A" => { :@x => writes, :@y => writes }, "B" => { :@z => writes } }
    )

    expect(rows.map { |r| r.message[/`@\w+' on \w+/] }).to eq(["`@x' on A", "`@y' on A", "`@z' on B"])
  end

  it "builds nothing from no writes" do
    expect(described_class.diagnostics("mem.rb", {})).to eq([])
  end

  it "keeps its helpers private" do
    names = %i[ivar_mismatch_diagnostics_for separate_invocations? declaration_admits? ivar_class_for
               build_ivar_write_mismatch_diagnostic]

    expect(names.map { |m| described_class.respond_to?(m) }).to eq([false] * 5)
  end
end
