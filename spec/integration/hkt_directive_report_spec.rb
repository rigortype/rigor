# frozen_string_literal: true

# Issue #785 — the report path for a DECLINED HKT directive, through a real `Runner`.
#
# `HktDirectives.record_hkt_error` routed every malformed `rigor:v1:hkt_register` / `rigor:v1:hkt_define`
# to a duck-typed `#record` / `#<<`. The production reporter is `RbsExtended::Reporter`, whose surface is
# `record_unresolved` / `record_lossy_projection`, so the call matched neither arm and fell off the end of
# the `if`: every failure was dropped in every real run, while `scan_rbs_loader`'s own doc comment promised
# an `:info` entry. A unit spec against a collecting double could not see that — the double answers
# `#record` — which is exactly why the proof has to run through the Runner the user runs.
#
# The sibling file `hkt_scan_failure_seam_spec.rb` (issue #784) covers the other half of the same surface:
# a scan that RAISES, which is an analyzer defect and reports `:error`. A declined directive is not a
# defect — the signature is malformed — so it reports `:info` and MUST NOT change a green run's exit code.
require "spec_helper"

RSpec.describe "HKT directive report (issue #785)" do
  include RunnerHelpers

  # `App[...]` is never mentioned by the source: the row is a property of the SIGNATURE being malformed,
  # not of any file happening to use the constructor the directive failed to register.
  let(:source) { "class Overlay\n  def call\n    1\n  end\nend\n" }

  def rows(result)
    result.diagnostics.select { |d| d.rule == "dynamic.rbs-extended.hkt-directive-invalid" }
  end

  context "with a malformed hkt_register in sig/" do
    let(:sig) do
      { "overlay.rbs" => <<~RBS }
        %a{rigor:v1:hkt_register: uri=notnamespaced arity=1 variance=out bound=untyped}
        class Overlay
          def call: () -> Integer
        end
      RBS
    end

    it "surfaces exactly one :info row naming what the parser objected to, positioned at the .rbs" do
      result = analyze(source, sig: sig)

      expect(rows(result).size).to eq(1)
      row = rows(result).first
      expect(row.severity).to eq(:info)
      expect(row.source_family).to eq(:builtin)
      expect(row.message).to include("namespaced")
      expect(row.path).to include("overlay.rbs")
      expect(row.line).to eq(1)
    end

    it "leaves the run green and emits no internal-analyzer-error row" do
      result = analyze(source, sig: sig)

      expect(result.success?).to be(true)
      expect(result.diagnostics.map(&:severity)).to all(eq(:info))
      expect(result.diagnostics.map(&:message))
        .to satisfy("no diagnostic starting with the check-rule prefix") do |messages|
          messages.none? { |m| m.start_with?("internal analyzer error") }
        end
    end
  end

  it "reports an hkt_define whose body= the ADR-20 grammar cannot read" do
    sig = { "overlay.rbs" => <<~RBS }
      %a{rigor:v1:hkt_define: uri=demo::box params=K body=Array[K}
      class Overlay
        def call: () -> Integer
      end
    RBS

    result = analyze(source, sig: sig)

    expect(rows(result).map(&:message)).to include(a_string_including("body parse error"))
    expect(result.success?).to be(true)
  end

  # The FP side, and the reason this row can be `:info` at all. An ordinary `type` alias is not a directive:
  # the implicit-sugar scan reads every alias in the loaded RBS env (ADR-20 slice 5), declines the ones it
  # cannot model as type constructors, and that decline is normal — a project whose `sig/` carries plain
  # aliases MUST stay silent, or the row would fire on almost every real project.
  it "stays silent for a well-formed directive and for ordinary type aliases" do
    sig = { "overlay.rbs" => <<~RBS }
      module Demo
        type ident[K] = K
        type plain = Integer | String
      end

      %a{rigor:v1:hkt_register: uri=demo::box arity=1 variance=out bound=untyped}
      class Overlay
        def call: () -> Integer
      end
    RBS

    result = analyze(source, sig: sig)

    # Not a vacuous pass: the file has to have LOADED for the absence to mean anything, and a quarantined
    # `.rbs` would take the aliases and the directive with it.
    expect(result.diagnostics.map(&:rule)).not_to include("rbs.coverage.quarantined-signature")
    expect(rows(result)).to be_empty
    expect(result.success?).to be(true)
  end
end
