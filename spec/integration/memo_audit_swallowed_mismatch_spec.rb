# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

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

  it "reports a swallowed mismatch from a pooled worker (--workers 2)" do
    plant_mismatch_in_resolve_call_method
    Dir.mktmpdir do |dir|
      files = { "a.rb" => source, "b.rb" => source, "c.rb" => "z = 1\n" }
      files.each { |name, text| File.write(File.join(dir, name), text) }
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => files.keys.map { |name| File.join(dir, name) }),
        cache_store: Rigor::Cache::Store.new(root: File.join(dir, ".rigor")), workers: 2
      )
      expect { Dir.chdir(dir) { guarded_run(runner) } }
        .to raise_error(InternalAnalyzerErrorGuard::AnalyzerCrashed, /MemoAudit::Mismatch/)
    end
  end

  it "fails at the run's release on a mismatch typed after the run, and empties the list" do
    begin
      Rigor::Inference::MemoAudit.check("after", :stored, :key) { :fresh }
    rescue Rigor::Inference::MemoAudit::Mismatch
      nil
    end
    expect { Rigor::RunScopedSlots.release }.to raise_error(Rigor::Inference::MemoAudit::Mismatch, /after/)
    expect(Rigor::Inference::MemoAudit.drain).to be_empty
  end

  it "fails a run that starts with a mismatch left on the thread, before any file is analysed" do
    begin
      Rigor::Inference::MemoAudit.check("left over", :stored, :key) { :fresh }
    rescue Rigor::Inference::MemoAudit::Mismatch
      nil
    end
    expect { analyze(source) }.to raise_error(Rigor::Inference::MemoAudit::Mismatch, /left over/)
  end

  it "fails the return summaries on a mismatch their effects computation swallowed" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "class A\n  def self.f(x) = x\nend\n")
      File.write(File.join(dir, "b.rb"), "A.f(1)\n")
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [dir]), cache_store: nil
      )
      Dir.chdir(dir) { guarded_run(runner) }
      allow_any_instance_of(Rigor::Inference::StatementEvaluator) # rubocop:disable RSpec/AnyInstance
        .to receive(:content_mutated_parameter_positions)
        .and_wrap_original do |original, *args|
          Rigor::Inference::MemoAudit.check("in summaries", :stored, :key) { :fresh }
          original.call(*args)
        end
      expect { runner.return_summaries }.to raise_error(Rigor::Inference::MemoAudit::Mismatch, /in summaries/)
    end
  end

  it "lets the incremental return-type probe raise the audit's mismatch rather than fall back" do
    session = Rigor::Analysis::IncrementalSession.allocate
    runner = instance_double(Rigor::Analysis::Runner)
    allow(session).to receive(:build_runner).and_return(runner)
    allow(runner).to receive(:evaluate_return_types).and_raise(Rigor::Inference::MemoAudit::Mismatch, "probed")
    expect { session.send(:probe_return_types, []) }.to raise_error(Rigor::Inference::MemoAudit::Mismatch, /probed/)
    allow(runner).to receive(:evaluate_return_types).and_raise(ArgumentError)
    expect(session.send(:probe_return_types, [])).to eq({})
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
