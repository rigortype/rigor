# frozen_string_literal: true

# The diff and adjudication logic of `tool/engine_diag_diff.rb` (ADR-119 WD2). Unit test only, over rows: the
# sharded test job is a shallow clone, so nothing here archives a revision. Requiring the script defines
# {EngineDiagDiff} without running an engine.
require "spec_helper"
require "tmpdir"

require_relative "../../tool/engine_diag_diff"

RSpec.describe "tool/engine_diag_diff.rb" do
  def row(line, rule: "call.wrong-arity", path: "a.rb", message: "m")
    [path, line, 1, rule, message]
  end

  def adjudication(*entries)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "adj.yml")
      File.write(file, YAML.dump(entries))
      EngineDiagDiff.load_adjudication(file)
    end
  end

  describe ".diff" do
    it "reports the rows only one side has, counting duplicates" do
      result = EngineDiagDiff.diff([row(1), row(2), row(2)], [row(2), row(3)])
      expect(result).to eq(added: [row(3)], removed: [row(1), row(2)])
    end

    it "is empty for equal sides" do
      expect(EngineDiagDiff.diff([row(1)], [row(1)])).to eq(added: [], removed: [])
    end
  end

  describe ".filter" do
    it "keeps one rule, or all when none is named" do
      rows = [row(1), row(2, rule: "call.undefined-method")]
      expect(EngineDiagDiff.filter(rows, "call.wrong-arity")).to eq([row(1)])
      expect(EngineDiagDiff.filter(rows, nil)).to eq(rows)
    end
  end

  describe ".load_adjudication" do
    it "reads an empty list and no file as nothing adjudicated" do
      expect(adjudication).to eq([])
      expect(EngineDiagDiff.load_adjudication(nil)).to eq([])
    end

    it "rejects an unknown verdict, a missing reason and a missing key" do
      good = { "base" => "abc1234", "path" => "a.rb", "line" => 1, "column" => 1, "message" => "m", "verdict" => "tp-lost",
               "reason" => "r" }
      expect { adjudication(good.merge("verdict" => "fine")) }.to raise_error(ArgumentError, /verdict/)
      expect { adjudication(good.merge("reason" => " ")) }.to raise_error(ArgumentError, /reason/)
      expect { adjudication(good.except("line")) }.to raise_error(ArgumentError, /missing line/)
      expect { adjudication(good.except("base")) }.to raise_error(ArgumentError, /missing base/)
    end
  end

  describe ".parse_floor" do
    it "splits PATH:N at the last colon" do
      expect(EngineDiagDiff.parse_floor("spec/survivors/:5")).to eq(["spec/survivors/", 5])
      expect { EngineDiagDiff.parse_floor("spec/survivors") }.to raise_error(ArgumentError, /PATH:N/)
    end
  end

  describe ".report" do
    let(:entry) do
      { "base" => "abc1234def", "path" => "a.rb", "line" => 1, "column" => 1, "message" => "m",
        "verdict" => "fp-silenced", "reason" => "r" }
    end

    def report(base, head, entries: [], **)
      EngineDiagDiff.report(base_rows: base, head_rows: head, rule: "call.wrong-arity", entries: entries, base_sha: "abc1234def5678", **)
    end

    it "passes an unchanged corpus" do
      expect(report([row(1)], [row(1)])).to include(ok: true)
    end

    it "fails a removed row nobody adjudicated, and passes it once adjudicated" do
      failing = report([row(1)], [])
      expect(failing[:ok]).to be(false)
      expect(failing[:text]).to include("Removed, NOT adjudicated", "a.rb:1:1")

      passing = report([row(1)], [], entries: [entry])
      expect(passing[:ok]).to be(true)
      expect(passing[:text]).to include("1 fp-silenced, 0 tp-lost")
    end

    it "fails an added row nobody named, and passes it once a named-mechanism entry lists it" do
      failing = report([row(1)], [row(1), row(2)])
      expect(failing[:ok]).to be(false)
      expect(failing[:text]).to include("Added, NOT adjudicated", "a.rb:2:1")

      named = entry.merge("line" => 2, "verdict" => "named-mechanism")
      passing = report([row(1)], [row(1), row(2)], entries: [named])
      expect(passing[:ok]).to be(true)
      expect(passing[:text]).to include("Added, adjudicated", "1 named-mechanism")
    end

    it "does not take a removal verdict for an added row, nor the reverse" do
      expect(report([row(1)], [row(1), row(2)], entries: [entry.merge("line" => 2)])[:ok]).to be(false)
      expect(report([row(1)], [], entries: [entry.merge("verdict" => "named-mechanism")])[:ok]).to be(false)
    end

    it "fails an adjudication entry that matches no removed or added row" do
      stale = report([row(1)], [row(1)], entries: [entry])
      expect(stale[:ok]).to be(false)
      expect(stale[:text]).to include("Stale adjudication entries", "match no removed or added row")
    end

    it "ignores rows of other rules" do
      other = row(1, rule: "call.undefined-method")
      expect(report([other], [])).to include(ok: true)
    end

    it "counts a per-path floor over only the rows under that path" do
      rows = [row(1, path: "fx/survivors/a.rb"), row(2, path: "fx/silenced.rb"), row(3, path: "fx/silenced.rb")]
      expect(report(rows, rows, floors: [["fx/survivors/", 1]])[:ok]).to be(true)
      failing = report(rows, rows, floors: [["fx/survivors/", 2]])
      expect(failing[:ok]).to be(false)
      expect(failing[:text]).to include("1 call.wrong-arity row(s) under fx/survivors/")
    end

    it "holds a per-path floor in the head too, so a survivor cannot be silenced" do
      rows = [row(1, path: "fx/survivors/a.rb"), row(2, path: "fx/survivors/b.rb")]
      failing = report(rows, [rows.first], floors: [["fx/survivors/", 2]])
      expect(failing[:ok]).to be(false)
      expect(failing[:text]).to include("the head has 1 call.wrong-arity row(s) under fx/survivors/")
    end

    it "fails an adjudication entry under a floored path, whatever its verdict or base" do
      rows = [row(1, path: "fx/survivors/a.rb")]
      lost = entry.merge("path" => "fx/survivors/a.rb", "verdict" => "tp-lost")
      result = report(rows, [], entries: [lost], floors: [["fx/survivors/", 1]])
      expect(result[:ok]).to be(false)
      expect(result[:text]).to include("under a floored path")
      other_base = lost.merge("base" => "9999999")
      expect(report(rows, rows, entries: [other_base], floors: [["fx/survivors/", 1]])[:ok]).to be(false)
    end

    it "ignores, without failing, an entry written against another base" do
      other = entry.merge("base" => "9999999")
      result = report([row(1)], [row(1)], entries: [other])
      expect(result[:ok]).to be(true)
      expect(result[:text]).to include("Adjudication entries ignored (other base)")
    end

    it "does not let an entry for another base adjudicate a difference" do
      expect(report([row(1)], [], entries: [entry.merge("base" => "9999999")])[:ok]).to be(false)
    end

    it "takes an abbreviated base only from seven characters" do
      expect(report([row(1)], [], entries: [entry.merge("base" => "abc1234")])[:ok]).to be(true)
      expect(report([row(1)], [], entries: [entry.merge("base" => "abc12")])[:ok]).to be(false)
    end

    it "prints the merge base to use" do
      expect(report([row(1)], [row(1)])[:text]).to include("`abc1234def5678`")
    end

    it "fails when the base has fewer rows than required, so an empty corpus cannot pass" do
      expect(report([], [], require_base_rows: 3)[:ok]).to be(false)
      expect(report([row(1), row(2), row(3)], [row(1), row(2), row(3)], require_base_rows: 3)[:ok]).to be(true)
    end
  end
end
