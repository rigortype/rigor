# frozen_string_literal: true

require "rbs"

require "rigor/rbs_extended/reporter"

RSpec.describe Rigor::RbsExtended::Reporter do
  subject(:reporter) { described_class.new }

  def location(name: "sig/widget.rbs", content: "class Widget\nend\n", start_pos: 0, end_pos: start_pos + 1)
    RBS::Location.new(RBS::Buffer.new(name: name, content: content), start_pos, end_pos)
  end

  def record_unresolved_at(source_location, payload: "rigor:v1:return: nope")
    path, line, column = described_class.position_of(source_location)
    reporter.record_unresolved(payload: payload, path: path, line: line, column: column)
  end

  describe "#record_unresolved / #unresolved_payloads" do
    it "accumulates payload + position tuples in insertion order" do
      reporter.record_unresolved(payload: "rigor:v1:return: bogus")
      reporter.record_unresolved(payload: "rigor:v1:return: also")

      payloads = reporter.unresolved_payloads.map(&:payload)
      expect(payloads).to eq(["rigor:v1:return: bogus", "rigor:v1:return: also"])
    end

    it "deduplicates entries by (payload, path, line, column)" do
      reporter.record_unresolved(payload: "rigor:v1:return: bogus")
      reporter.record_unresolved(payload: "rigor:v1:return: bogus")

      expect(reporter.unresolved_payloads.size).to eq(1)
    end

    it "freezes the snapshot returned by the reader" do
      reporter.record_unresolved(payload: "x")

      expect(reporter.unresolved_payloads).to be_frozen
    end
  end

  describe "#record_lossy_projection / #lossy_projections" do
    it "accumulates (head, position) tuples in insertion order" do
      reporter.record_lossy_projection(head: "pick_of")
      reporter.record_lossy_projection(head: "omit_of")

      heads = reporter.lossy_projections.map(&:head)
      expect(heads).to eq(%w[pick_of omit_of])
    end

    it "deduplicates entries by (head, path, line, column)" do
      reporter.record_lossy_projection(head: "pick_of")
      reporter.record_lossy_projection(head: "pick_of")

      expect(reporter.lossy_projections.size).to eq(1)
    end
  end

  # Issue #805 — the two older streams carried the `RBS::Location` itself, which cost the pooled run both
  # halves of this describe: the drain's `Marshal.dump` raised `TypeError` on the location (killing the
  # worker), and the coordinator's merge could not collapse two workers' copies of one row, because an
  # `RBS::Location` compares equal only against a location over the SAME `RBS::Buffer` object.
  # ADR-109 WD3 — the deprecation window for the angle-bracket integer range is a stream of its own, so
  # a run can name the replacement spelling once per annotation.
  describe "#record_deprecated_form / #deprecated_forms" do
    it "accumulates (payload, replacement, position) tuples in insertion order" do
      reporter.record_deprecated_form(payload: "int<5, 10>", replacement: "Integer[5..10]")
      reporter.record_deprecated_form(payload: "int<0, 1>", replacement: "Integer[0..1]")

      expect(reporter.deprecated_forms.map(&:payload)).to eq(["int<5, 10>", "int<0, 1>"])
      expect(reporter.deprecated_forms.map(&:replacement)).to eq(["Integer[5..10]", "Integer[0..1]"])
    end

    it "deduplicates entries by (payload, replacement, path, line, column)" do
      2.times do
        reporter.record_deprecated_form(payload: "int<5, 10>", replacement: "Integer[5..10]", path: "sig/a.rbs",
                                        line: 2, column: 3)
      end

      expect(reporter.deprecated_forms.size).to eq(1)
    end

    it "keeps the entry Marshal-clean and deeply frozen, as the pool drain requires" do
      path, line, column = described_class.position_of(location)
      reporter.record_deprecated_form(payload: +"int<5, 10>", replacement: +"Integer[5..10]",
                                      path: path, line: line, column: column)
      entry = reporter.deprecated_forms.first

      expect(Marshal.load(Marshal.dump(entry))).to eq(entry)
      expect(Ractor.shareable?(entry)).to be(true)
    end

    it "counts towards #empty?" do
      expect(reporter).to be_empty
      reporter.record_deprecated_form(payload: "int<5, 10>", replacement: "Integer[5..10]")
      expect(reporter).not_to be_empty
    end
  end

  describe "position primitives (issue #805)" do
    it "flattens an RBS::Location to (path, 1-based line, 1-based column)" do
      expect(described_class.position_of(location(start_pos: 6))).to eq(["sig/widget.rbs", 1, 7])
      expect(described_class.position_of(nil)).to eq([nil, nil, nil])
    end

    it "keeps an unresolved entry Marshal-clean and deeply frozen, as the pool drain requires" do
      record_unresolved_at(location)
      entry = reporter.unresolved_payloads.first

      expect(Marshal.load(Marshal.dump(entry))).to eq(entry)
      expect(Ractor.shareable?(entry)).to be(true)
    end

    it "keeps a lossy-projection entry Marshal-clean and deeply frozen too" do
      path, line, column = described_class.position_of(location)
      reporter.record_lossy_projection(head: "pick_of", path: path, line: line, column: column)
      entry = reporter.lossy_projections.first

      expect(Marshal.load(Marshal.dump(entry))).to eq(entry)
      expect(Ractor.shareable?(entry)).to be(true)
    end

    it "dedups the same unresolved payload recorded by two workers over separate RBS::Buffers" do
      record_unresolved_at(location(content: "worker a\n"))
      record_unresolved_at(location(content: "worker b\n"))

      expect(reporter.unresolved_payloads.size).to eq(1)
      expect(reporter.unresolved_payloads.first.path).to eq("sig/widget.rbs")
    end

    it "dedups the same lossy projection recorded by two workers over separate RBS::Buffers" do
      ["worker a\n", "worker b\n"].each do |content|
        path, line, column = described_class.position_of(location(content: content))
        reporter.record_lossy_projection(head: "pick_of", path: path, line: line, column: column)
      end

      expect(reporter.lossy_projections.size).to eq(1)
    end

    it "keeps two events at different positions apart" do
      record_unresolved_at(location(start_pos: 0))
      record_unresolved_at(location(start_pos: 6))

      expect(reporter.unresolved_payloads.map(&:column)).to eq([1, 7])
    end
  end

  describe "#empty?" do
    it "is true on construction" do
      expect(reporter).to be_empty
    end

    it "is false after any event lands" do
      reporter.record_unresolved(payload: "x")
      expect(reporter).not_to be_empty
    end
  end
end
