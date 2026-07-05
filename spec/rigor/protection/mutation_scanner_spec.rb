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
