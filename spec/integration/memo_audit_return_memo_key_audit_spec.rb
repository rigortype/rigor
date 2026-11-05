# frozen_string_literal: true

require "spec_helper"

# ADR-129 WD1 — the key audit over the ADR-84 return memo on a real run. The memo reads the block-body threading
# suppression without keying on it (#2782); the audit names that read as the known gap instead of passing it silently,
# and without the declaration it fails the run. A callee whose body types a block reads the flag on its miss.
RSpec.describe "the key audit of the return memo (ADR-129 WD1, #2782)", type: :runner do
  around do |example|
    Rigor::Inference::MemoAudit.enable!
    example.run
  ensure
    Rigor::Inference::MemoAudit.drain
    Rigor::Inference::MemoAudit.disable!
  end

  let(:source) do
    <<~RUBY
      class Probe
        def helper = [1, 2].map { |x| x + 1 }
        def target(value) = value
        def forward(...) = target(...)
        def yielder = yield(1)
        def run = [helper.first, forward(1), yielder { |x| x }]
      end
      Probe.new.run
    RUBY
  end

  def exceptions_met
    met = []
    allow(Rigor::Inference::MemoAudit).to receive(:note_key_exception).and_wrap_original do |original, *args|
      met << args[1..2]
      original.call(*args)
    end
    met
  end

  it "names the threading suppression as #2782's gap and reports no mismatch" do
    met = exceptions_met
    expect { analyze(source) }.not_to raise_error
    expect(met).to include(["return memo", :threaded_block_body])
  end

  it "fails the run once the return memo stops naming the gap" do
    declared = Rigor::Inference::ExpressionTyper.const_get(:RETURN_MEMO_KEY_AUDIT)
    stub_const("Rigor::Inference::ExpressionTyper::RETURN_MEMO_KEY_AUDIT",
               declared.with(gaps: declared.gaps.except(:threaded_block_body)))
    expect { analyze(source) }.to raise_error(InternalAnalyzerErrorGuard::AnalyzerCrashed, /threaded_block_body/)
  end

  it "fails the run once the return memo stops declaring the forwarded-argument list it forces" do
    declared = Rigor::Inference::ExpressionTyper.const_get(:RETURN_MEMO_KEY_AUDIT)
    stub_const("Rigor::Inference::ExpressionTyper::RETURN_MEMO_KEY_AUDIT",
               declared.with(forced: declared.forced - [:forwarded_call_arg_types]))
    expect { analyze(source) }.to raise_error(InternalAnalyzerErrorGuard::AnalyzerCrashed, /forwarded_call_arg_types/)
  end
end
