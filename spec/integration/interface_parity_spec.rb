# frozen_string_literal: true

require "spec_helper"
require "json"

require "rigor/analysis/runner"
require "rigor/configuration"

# ADR-130 WD2's behavioural gate. Every parity fixture runs in the erasure baseline and in each parity mode, and each
# mode's `rigor check --format json` diagnostics must equal the baseline's after one normalisation: a rendered facet
# name, `Dynamic[<plugin interface>]`, reads `Dynamic[top]`. Everything else is compared byte for byte, so a structural
# divergence (an extra union arm, a lost hash shape) fails even where its text differs only in a facet name.
#
# Slice 1a has no interface carrier, so its one parity mode is the baseline itself. Slice 1b adds its carrier with
# dispatch off to `PARITY_MODES` and `#run_in`, and a fixture per parity site under `fixtures/interface_parity/`.
#
# The controls run a simulated carrier (`Dynamic[Nominal[<interface name>]]`, read as erased through the
# `Combinator.erased_facet?` hook): with the union merge the fixture passes, and with the merge planted out the gate
# fails on the round-3 join divergence, so the gate tells a facet rename from a structural change.
module InterfaceParity
  FIXTURE_ROOT = File.expand_path("fixtures/interface_parity", __dir__)
  FIXTURES = Dir.children(FIXTURE_ROOT).sort.freeze

  # The modes compared with the erasure baseline. Slice 1b: `%i[erasure dispatch_off]`.
  PARITY_MODES = %i[erasure].freeze

  FACET_NAME = /Dynamic\[(?:::)?Rigor::Plugin::_\w+(?<args>\[(?:[^\[\]]|\g<args>)*\])?\]/

  def self.normalise(text) = text.gsub(FACET_NAME, "Dynamic[top]")

  def self.plugin_interface?(rbs_type)
    rbs_type.is_a?(RBS::Types::Interface) && rbs_type.name.namespace.path == %i[Rigor Plugin]
  end

  def self.simulated_facet?(facet)
    facet.is_a?(Rigor::Type::Nominal) && facet.class_name.start_with?("Rigor::Plugin::_")
  end
end

RSpec.describe "ADR-130 interface parity (behavioural gate)" do
  def fixture_dir(name) = File.join(InterfaceParity::FIXTURE_ROOT, name)
  def normalise(text) = InterfaceParity.normalise(text)

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
  end

  # The fixture's `rigor check --format json` diagnostics, as text.
  def render(dir)
    result = Dir.chdir(dir) { guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)) }
    JSON.pretty_generate(result.to_h.fetch("diagnostics"))
  end

  def run_in(mode, dir)
    case mode
    when :erasure then render(dir)
    when :simulated_carrier then with_simulated_carrier { render(dir) }
    when :simulated_carrier_without_merge
      allow(Rigor::Type::Combinator).to receive(:merge_erased_members) { |members| members }
      with_simulated_carrier { render(dir) }
    else raise ArgumentError, "unknown parity mode #{mode}"
    end
  end

  # A `Rigor::Plugin` interface translates to `Dynamic[Nominal[<its name>]]`, a facet the erasure hook accepts. It
  # stands in for slice 1b's carrier in the controls only; no parity mode uses it.
  def with_simulated_carrier
    allow(Rigor::Type::Combinator).to receive(:erased_facet?).and_wrap_original do |original, facet|
      InterfaceParity.simulated_facet?(facet) || original.call(facet)
    end
    allow(Rigor::Inference::RbsTypeTranslator).to receive(:translate_untyped).and_wrap_original do |original, type, ctx|
      next original.call(type, ctx) unless InterfaceParity.plugin_interface?(type)

      Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.nominal_of(type.name.relative!.to_s))
    end
    yield
  end

  # The examples below are generated per fixture, and zero fixtures would be zero failures.
  it "has parity fixtures to run" do
    expect(InterfaceParity::FIXTURES).to include("joins")
  end

  InterfaceParity::FIXTURES.each do |fixture|
    InterfaceParity::PARITY_MODES.each do |mode|
      it "#{fixture}: #{mode} matches the erasure baseline modulo facet names" do
        baseline = render(fixture_dir(fixture))

        # A fixture that types nothing would compare two empty documents.
        expect(baseline).to include("dump_type")
        expect(normalise(run_in(mode, fixture_dir(fixture)))).to eq(normalise(baseline))
      end
    end
  end

  describe "the controls" do
    let(:dir) { fixture_dir("joins") }

    it "normalises a facet name and nothing else" do
      expect(normalise("Dynamic[Rigor::Plugin::_Scope] | Dynamic[::Rigor::Plugin::_Each[Integer, Array[Integer]]]"))
        .to eq("Dynamic[top] | Dynamic[top]")
      expect(normalise("Dynamic[Rigor::Scope] | Rigor::Plugin::_Scope"))
        .to eq("Dynamic[Rigor::Scope] | Rigor::Plugin::_Scope")
    end

    it "passes a carrier whose joins keep master's shape, though its rendered text differs" do
      baseline = render(dir)
      carried = run_in(:simulated_carrier, dir)

      expect(carried).not_to eq(baseline)
      expect(carried).to include("Dynamic[Rigor::Plugin::_ProbeS]")
      expect(normalise(carried)).to eq(normalise(baseline))
    end

    it "fails a carrier whose nested joins keep an extra arm (the planted structural divergence)" do
      baseline = normalise(render(dir))
      planted = normalise(run_in(:simulated_carrier_without_merge, dir))

      expect(planted).not_to eq(baseline)
      expect(planted).to include("[Dynamic[top]] | [Dynamic[top]]")
    end
  end
end
