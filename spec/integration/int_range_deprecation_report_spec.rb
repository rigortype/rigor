# frozen_string_literal: true

# ADR-109 WD3 — the deprecation window for the PHPStan-style `int<a, b>` payload, through a real `Runner`.
#
# The angle-bracket form still resolves (a signature written against v0.1–v0.3 keeps its refinement), so
# nothing else in the run would tell the author that the spelling is on its way out or what to write
# instead. The row is the only thing that does, and it MUST NOT change a green run's exit code.
require "spec_helper"

RSpec.describe "int<a, b> deprecation report (ADR-109 WD3)" do
  include RunnerHelpers

  # The payload is read when the annotated method is dispatched, so the source has to call it.
  let(:source) { "class Overlay\n  def call\n    7\n  end\nend\nOverlay.new.call\n" }

  def rows(result)
    result.diagnostics.select { |d| d.rule == "dynamic.rbs-extended.deprecated-form" }
  end

  context "with the angle-bracket spelling in sig/" do
    let(:sig) do
      { "overlay.rbs" => <<~RBS }
        class Overlay
          %a{rigor:v1:return: int<5, 10>}
          def call: () -> Integer
        end
      RBS
    end

    it "surfaces exactly one :info row naming the Integer[a..b] spelling, positioned at the .rbs" do
      result = analyze(source, sig: sig)

      expect(rows(result).size).to eq(1)
      row = rows(result).first
      expect(row.severity).to eq(:info)
      expect(row.message).to include("`int<5, 10>`").and include("`Integer[5..10]`")
      expect(row.path).to include("overlay.rbs")
      expect(row.line).to eq(2)
    end

    it "leaves the run green and keeps the refinement the payload named" do
      result = analyze(source, sig: sig)

      expect(result.success?).to be(true)
      expect(result.diagnostics.map(&:severity)).to all(eq(:info))
    end
  end

  it "reports nothing for the Ruby range spelling" do
    sig = { "overlay.rbs" => <<~RBS }
      class Overlay
        %a{rigor:v1:return: Integer[5..10]}
        def call: () -> Integer
      end
    RBS

    result = analyze(source, sig: sig)

    expect(rows(result)).to be_empty
  end
end
