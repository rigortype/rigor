# frozen_string_literal: true

require "spec_helper"

# ADR-129 WD5 / issue #2785 — a `MemoAudit` mismatch raised under one of the typing path's `rescue StandardError`
# sites is still reported. `StatementEvaluator#resolve_call_method` types a receiver under `rescue StandardError → nil`;
# a mismatch raised there used to become an ordinary fallback answer and leave the audited run green.
RSpec.describe "a MemoAudit mismatch swallowed by a rescue on the typing path (#2785)", type: :runner do
  around do |example|
    Rigor::Inference::MemoAudit.enable!
    example.run
  ensure
    Rigor::Inference::MemoAudit.disable!
  end

  let(:source) { "x = Object.new\nx.frozen?\n" }

  # A memo hit whose stored value differs from its fresh one, raised only inside `resolve_call_method`'s rescued
  # region (the rescue that #2785 names), so nothing outside it sees the raise.
  def plant_mismatch_in_resolve_call_method
    planted = 0
    allow(Rigor::Reflection).to receive(:rbs_class_known?).and_wrap_original do |original, *args, **kwargs|
      if caller_locations.any? { |location| location.label.to_s.end_with?("resolve_call_method") }
        planted += 1
        Rigor::Inference::MemoAudit.check("planted", :stored, :key) { :fresh }
      end
      original.call(*args, **kwargs)
    end
    -> { planted }
  end

  it "reports the mismatch as a crash row although the rescue swallowed the raise" do
    planted = plant_mismatch_in_resolve_call_method
    expect { analyze(source) }.to raise_error(InternalAnalyzerErrorGuard::AnalyzerCrashed, /MemoAudit::Mismatch/)
    expect(planted.call).to be_positive
  end

  it "drains the list, so the next file starts with none" do
    plant_mismatch_in_resolve_call_method
    expect { analyze(source) }.to raise_error(InternalAnalyzerErrorGuard::AnalyzerCrashed)
    expect(Rigor::Inference::MemoAudit.drain).to be_empty
  end

  describe "the crash rows a file's swallowed errors add" do
    def raised(message)
      raise Rigor::Inference::MemoAudit::Mismatch, message
    rescue Rigor::Inference::MemoAudit::Mismatch => e
      e
    end

    let(:error) { raised("planted") }
    let(:row) { Rigor::Analysis::CrashSignature.check_rule_message(error) }

    it "adds one crash row per distinct message" do
      rows = Rigor::Analysis::CrashSignature.with_swallowed("a.rb", [], [error, error, raised("other")])
      expect(rows.map(&:message)).to eq([row, Rigor::Analysis::CrashSignature.check_rule_message(raised("other"))])
      expect(rows.map(&:path)).to all(eq("a.rb"))
    end

    it "does not repeat an error that already reached the file's crash row" do
      crash = Rigor::Analysis::Diagnostic.new(path: "a.rb", line: 1, column: 1, message: row)
      expect(Rigor::Analysis::CrashSignature.with_swallowed("a.rb", [crash], [error])).to eq([crash])
    end
  end

  it "would pass silently without the drain: the rescue is what hides the raise (control)" do
    plant_mismatch_in_resolve_call_method
    allow(Rigor::Inference::MemoAudit).to receive(:drain).and_return([])
    expect { analyze(source) }.not_to raise_error
  end

  it "fails the run on a mismatch raised outside every file's analysis" do
    allow(Rigor::Inference::DefNodeResolver).to receive(:with_run).and_wrap_original do |original, &block|
      original.call do
        result = block.call
        Rigor::Inference::MemoAudit.check("planted", :stored, :key) { :fresh }
      rescue Rigor::Inference::MemoAudit::Mismatch
        result
      end
    end
    expect { analyze(source) }.to raise_error(Rigor::Inference::MemoAudit::Mismatch, /planted/)
  end
end
