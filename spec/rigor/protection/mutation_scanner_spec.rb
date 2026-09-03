# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "rigor/configuration"
require "rigor/language_server/project_context"
require "rigor/protection/mutation_scanner"

# ADR-63 Tier 2 — the warm-loop per-file effectiveness measurement. Drives the real analyzer (one shared environment +
# project scan) over each mutant and reads a NEW diagnostic as a "caught breakage" (kill). This exercises the kill
# criterion end-to-end, so it builds a real (if minimal) project context.
RSpec.describe Rigor::Protection::MutationScanner do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def scanner(site_selector: :biteable, limit: nil)
    config = Rigor::Configuration.load(nil)
    context = Rigor::LanguageServer::ProjectContext.new(configuration: config)
    described_class.new(
      configuration: config, environment: context.environment, project_scan: context.project_scan,
      site_selector: site_selector, limit: limit
    )
  end

  it "kills a renamed call on a concrete receiver (the breakage is caught)" do
    File.write("clean.rb", %(def greet\n  "hello".upcase\nend\n))

    result = scanner.scan_file("clean.rb")

    expect(result.killed).to be >= 1
    expect(result.survived).to eq(0)
    expect(result.ratio).to eq(1.0)
  end

  it "records a surviving site when a type-visible mutation is not caught" do
    # `File.join` accepts any arguments in RBS, so dropping an arg to nil does not fire — a genuine missed-breakage
    # candidate at a concrete receiver.
    File.write("joins.rb", %(def j\n  File.join("a", "b")\nend\n))

    result = scanner.scan_file("joins.rb")

    expect(result.survived).to be >= 1
    site = result.sites.first
    expect(site.method_name).to eq("join")
    expect(site.receiver).to be_a(String)
  end

  it "caps the measured mutations at `limit` (cost control via deterministic sampling)" do
    File.write("joins.rb", %(def j\n  File.join("a", "b", "c")\nend\n))

    expect(scanner.scan_file("joins.rb").total).to be > 2
    expect(scanner(limit: 2).scan_file("joins.rb").total).to be <= 2
  end

  it "is vacuously fully effective for a file with no type-relevant mutations" do
    File.write("untyped.rb", %(def f(x)\n  x.save\nend\n))

    result = scanner.scan_file("untyped.rb")

    expect(result.total).to eq(0)
    expect(result.ratio).to eq(1.0)
  end

  # ADR-70 — the fused static∪dynamic measurement. A fake oracle stands in for the real test suite so the classification
  # logic is exercised deterministically.
  def fake_test_oracle(verdict)
    oracle = Object.new
    oracle.define_singleton_method(:killed?) { |**| verdict }
    oracle
  end

  it "credits a type-survivor to the test axis when a test catches it (ADR-70)" do
    # `File.join` survives the type pass (any args ok) — a type-survivor the test oracle then catches → test_killed,
    # zero unprotected, fully protected.
    File.write("joins.rb", %(def j\n  File.join("a", "b")\nend\n))

    result = scanner.scan_file_fused("joins.rb", test_oracle: fake_test_oracle(true))

    expect(result.test_killed).to be >= 1
    expect(result.unprotected).to eq(0)
    expect(result.ratio).to eq(1.0)
  end

  it "marks a site unprotected when neither a type nor a test catches it (ADR-70)" do
    File.write("joins.rb", %(def j\n  File.join("a", "b")\nend\n))

    result = scanner.scan_file_fused("joins.rb", test_oracle: fake_test_oracle(false))

    expect(result.unprotected).to be >= 1
    expect(result.test_killed).to eq(0)
    expect(result.sites.first.protection).to eq(:none)
  end

  it "probes Dynamic-receiver dispatch sites under the :all selector and credits the test axis (Seam 2)" do
    # `x` is an untyped param, so `x.save` is a Dynamic-receiver site the biteable filter drops entirely (nothing to
    # measure). Under :all it is mutated and, being un-bite-able, falls straight to the test axis.
    File.write("dyn.rb", %(def f(x)\n  x.save\nend\n))

    biteable = scanner.scan_file_fused("dyn.rb", test_oracle: fake_test_oracle(true))
    expect(biteable.total).to eq(0)

    all = scanner(site_selector: :all).scan_file_fused("dyn.rb", test_oracle: fake_test_oracle(true))
    expect(all.type_killed).to eq(0)   # the type checker can never bite a Dynamic receiver
    expect(all.test_killed).to be >= 1 # but the test axis reached it
  end

  it "marks a Dynamic-receiver site unprotected when no test catches it (:all selector)" do
    File.write("dyn.rb", %(def f(x)\n  x.save\nend\n))

    all = scanner(site_selector: :all).scan_file_fused("dyn.rb", test_oracle: fake_test_oracle(false))

    expect(all.unprotected).to be >= 1
    expect(all.sites.first.method_name).to eq("save")
  end

  # #264 — `classify` rescues ALL of `StandardError` so one harness-level failure cannot abort the file, but
  # the rescued mutant must be counted separately from a genuinely parse-invalid one, and it must stay OUT of
  # `killed + survived` exactly as `:invalid` does today (containment is unchanged; only visibility is new).
  #
  # An oracle that raises on its first `killed?` call and behaves normally after — real enough to prove
  # `classify` routes an in-flight harness exception to `:harness_error` while every OTHER mutant in the same
  # file is still measured normally (the "must not abort the file" half of the original comment, unchanged).
  def raising_once_oracle(then_verdict:)
    calls = 0
    oracle = Object.new
    oracle.define_singleton_method(:baseline) { |**| [] }
    oracle.define_singleton_method(:killed?) do |**|
      calls += 1
      raise "boom (harness-level failure, #264 fixture)" if calls == 1

      then_verdict
    end
    oracle
  end

  def scanner_with_oracle(oracle)
    config = Rigor::Configuration.load(nil)
    context = Rigor::LanguageServer::ProjectContext.new(configuration: config)
    described_class.new(configuration: config, environment: context.environment, project_scan: context.project_scan,
                        oracle: oracle)
  end

  it "counts a rescued harness failure as harness_errors, not as invalid or survived (#264)" do
    # Three args → multiple kept mutations (the `limit` spec above already relies on this), so at least one
    # `killed?` call survives the first (raising) call.
    File.write("joins.rb", %(def j\n  File.join("a", "b", "c")\nend\n))
    kept_count = scanner.scan_file("joins.rb").total # the real oracle: no rescues, so total == mutations kept

    result = scanner_with_oracle(raising_once_oracle(then_verdict: false)).scan_file("joins.rb")

    expect(result.harness_errors).to eq(1)
    expect(result.total).to eq(kept_count - 1) # one mutant moved from the denominator into harness_errors
    expect(result.total).to eq(result.killed + result.survived) # #total still excludes harness_errors
  end

  it "counts a rescued harness failure separately in the fused scan too (#264)" do
    File.write("joins.rb", %(def j\n  File.join("a", "b", "c")\nend\n))
    kept_count = scanner.scan_file("joins.rb").total

    result = scanner_with_oracle(raising_once_oracle(then_verdict: false))
             .scan_file_fused("joins.rb", test_oracle: fake_test_oracle(false))

    expect(result.harness_errors).to eq(1)
    expect(result.total).to eq(kept_count - 1)
    expect(result.total).to eq(result.type_killed + result.test_killed + result.unprotected)
  end

  it "reproduces identical killed + survived + harness_errors totals across two scans of the same fixture (#264)" do
    File.write("joins.rb", %(def j\n  File.join("a", "b", "c")\nend\n))

    first = scanner.scan_file("joins.rb")
    second = scanner.scan_file("joins.rb")

    expect([second.killed, second.survived, second.harness_errors])
      .to eq([first.killed, first.survived, first.harness_errors])
  end

  it "keeps harness_errors out of FileResult#total / #ratio, exactly like a parse-invalid mutant (#264)" do
    result = described_class::FileResult.new(path: "f.rb", killed: 3, survived: 1, sites: [], harness_errors: 5)

    expect(result.total).to eq(4) # killed + survived only
    expect(result.ratio).to eq(0.75)
  end

  it "keeps harness_errors out of FusedFileResult#total / #ratio (#264)" do
    result = described_class::FusedFileResult.new(path: "f.rb", type_killed: 2, test_killed: 1, sites: [],
                                                  harness_errors: 5)

    expect(result.total).to eq(3) # type_killed + test_killed + unprotected(0), harness_errors excluded
    expect(result.ratio).to eq(1.0)
  end

  it "defaults harness_errors to 0 so an existing FileResult.new call site keeps working (#264)" do
    result = described_class::FileResult.new(path: "f.rb", killed: 1, survived: 0, sites: [])

    expect(result.harness_errors).to eq(0)
  end

  # Issue #686 — the sweep-level gate. `File.join` is the fixture the "records a surviving site" example above
  # uses precisely because its mutants genuinely survive, so it is the file a crashed rule would inflate: with
  # every check rule raising, the baseline and each mutant come back carrying the same `internal analyzer
  # error` row, the kill comparison finds no difference, and every one of those mutants is reported as a
  # survivor Rigor "failed to catch". The oracle now refuses the crashed run, and the scanner routes the
  # refusal into the `harness_errors` bucket the CLI already warns about (#264).
  #
  # The healthy scan is asserted first and is the non-vacuity half: the same file really does yield survivors,
  # so `survived == 0` below is the crash being contained rather than the fixture having nothing to measure.
  it "reports a crashed run as harness_errors instead of inflating the survivor count (#686)" do
    File.write("joins.rb", %(def j\n  File.join("a", "b", "c")\nend\n))
    healthy = scanner.scan_file("joins.rb")
    expect(healthy.survived).to be >= 1

    allow(Rigor::Analysis::CheckRules).to receive(:diagnose)
      .and_raise(RuntimeError, "injected check-rule crash (issue #686 gate)")
    crashed = scanner.scan_file("joins.rb")

    expect(crashed.survived).to eq(0)
    expect(crashed.killed).to eq(0)
    expect(crashed.harness_errors).to eq(healthy.total)
    expect(crashed.total).to eq(0)
  end

  # The same containment on the fused path, whose baseline is computed at its own call site.
  it "reports a crashed run as harness_errors in the fused scan too (#686)" do
    File.write("joins.rb", %(def j\n  File.join("a", "b", "c")\nend\n))
    healthy = scanner.scan_file("joins.rb")
    expect(healthy.total).to be >= 1

    allow(Rigor::Analysis::CheckRules).to receive(:diagnose)
      .and_raise(RuntimeError, "injected check-rule crash (issue #686 gate)")
    crashed = scanner.scan_file_fused("joins.rb", test_oracle: fake_test_oracle(false))

    expect(crashed.unprotected).to eq(0)
    expect(crashed.harness_errors).to eq(healthy.total)
    expect(crashed.total).to eq(0)
  end

  it "never reaches the suite when the type checker already kills the mutant (gradual short-circuit)" do
    # `"hello".upcase` mutants are all type-killed → the test oracle is never consulted; an oracle that would raise if
    # called proves the short-circuit.
    File.write("greet.rb", %(def greet\n  "hello".upcase\nend\n))
    never = Class.new { def killed?(**) = raise("suite should not run on a type-killed mutant") }.new

    result = scanner.scan_file_fused("greet.rb", test_oracle: never)

    expect(result.type_killed).to be >= 1
    expect(result.test_killed).to eq(0)
    expect(result.unprotected).to eq(0)
    expect(result.ratio).to eq(1.0)
  end
end
