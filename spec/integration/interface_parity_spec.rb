# frozen_string_literal: true

require "spec_helper"
require "json"

require "rigor/analysis/runner"
require "rigor/configuration"

# ADR-130 WD2's behavioural gate. Every parity fixture runs once in the erasure baseline, under
# `RbsTypeTranslator.with_interface_erasure`, so the baseline never comes from the default engine: when slice 1b makes
# the carrier default-on, the baseline still erases. Each mode is then compared with that baseline on its
# `rigor check --format json` diagnostics:
#
# - a mode in `PARITY_MODES` must match after one normalisation, a rendered facet name `Dynamic[<plugin interface>]`
#   read as `Dynamic[top]`. Everything else is compared byte for byte, so a structural divergence (an extra union arm,
#   a lost hash shape) fails even where its text differs only in a facet name;
# - a mode in `DISPATCH_MODES` may also differ on the rows of a declared-member call, a fixture line marked
#   `# parity: declared-member`, and nowhere else.
#
# Slice 1a has no carrier, so its default engine is in both lists. Slice 1b moves `:default` (dispatch on) to
# `DISPATCH_MODES` only, adds `:dispatch_off` (its carrier with dispatch off) to `PARITY_MODES` and `#run_in`, and
# adds a fixture per parity site under `fixtures/interface_parity/`.
#
# The controls install a simulated carrier for the whole example, default-on as 1b's will be: `Rigor::Plugin`
# interfaces translate to `Dynamic[Nominal[<name>]]`, a facet the `Combinator.erased_facet?` hook accepts, except
# under the erasure switch. With the union merge the gate passes; with the merge planted out it fails on review round
# 3's join divergence, so it tells a facet rename from a structural change.
module InterfaceParity
  FIXTURE_ROOT = File.expand_path("fixtures/interface_parity", __dir__)
  FIXTURES = Dir.children(FIXTURE_ROOT).sort.freeze

  # Must equal the erasure baseline modulo facet names. Slice 1b: `%i[dispatch_off]`.
  PARITY_MODES = %i[default].freeze
  # May also differ on a declared-member call's rows. Slice 1b: `%i[default]`.
  DISPATCH_MODES = %i[default].freeze

  DECLARED_MARK = "# parity: declared-member"
  FACET_NAME = /Dynamic\[(?:::)?Rigor::Plugin::_\w+(?<args>\[(?:[^\[\]]|\g<args>)*\])?\]/

  module_function

  def normalise(text) = text.gsub(FACET_NAME, "Dynamic[top]")

  # The `[path, line]` of every line a fixture marks as a declared-member call.
  def declared_lines(dir)
    Dir.glob("lib/**/*.rb", base: dir).flat_map do |path|
      File.readlines(File.join(dir, path)).each_with_index.filter_map do |line, index|
        [path, index + 1] if line.include?(DECLARED_MARK)
      end
    end
  end

  # The diagnostics document without the rows on `lines`.
  def without_rows(document, lines)
    JSON.pretty_generate(JSON.parse(document).reject { |row| lines.include?([row["path"], row["line"]]) })
  end

  def plugin_interface?(rbs_type)
    rbs_type.is_a?(RBS::Types::Interface) && rbs_type.name.namespace.path == %i[Rigor Plugin]
  end

  def simulated_facet?(facet)
    facet.is_a?(Rigor::Type::Nominal) && facet.class_name.start_with?("Rigor::Plugin::_")
  end
end

RSpec.describe "ADR-130 interface parity (behavioural gate)" do
  def fixture_dir(name) = File.join(InterfaceParity::FIXTURE_ROOT, name)
  def normalise(text) = InterfaceParity.normalise(text)

  # Sequential: the erasure switch is per thread, and a pooled run under it raises.
  def configuration(workers: 0)
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig],
                                           "parallel" => { "workers" => workers })
    )
  end

  # The fixture's `rigor check --format json` diagnostics, as text.
  def render(dir, workers: 0)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(workers: workers), cache_store: nil,
                                         workers: workers)
    result = Dir.chdir(dir) { guarded_run(runner) }
    JSON.pretty_generate(result.to_h.fetch("diagnostics"))
  end

  def run_in(mode, dir)
    case mode
    when :erasure then Rigor::Inference::RbsTypeTranslator.with_interface_erasure { render(dir) }
    when :default then render(dir)
    else raise ArgumentError, "unknown parity mode #{mode}"
    end
  end

  # `[baseline, mode]`, each normalised, as the parity criterion compares them.
  def parity_pair(mode, dir)
    [normalise(run_in(:erasure, dir)), normalise(run_in(mode, dir))]
  end

  # The same, without the rows of declared-member calls.
  def dispatch_pair(mode, dir)
    lines = InterfaceParity.declared_lines(dir)
    parity_pair(mode, dir).map { |document| InterfaceParity.without_rows(document, lines) }
  end

  # The examples below are generated per fixture, and zero fixtures would be zero failures.
  it "has parity fixtures to run" do
    expect(InterfaceParity::FIXTURES).to include("joins")
  end

  InterfaceParity::FIXTURES.each do |fixture|
    InterfaceParity::PARITY_MODES.each do |mode|
      it "#{fixture}: #{mode} matches the erasure baseline modulo facet names" do
        baseline, candidate = parity_pair(mode, fixture_dir(fixture))

        # A fixture that types nothing would compare two empty documents, and a baseline that kept a facet would
        # compare the carrier with itself.
        expect(baseline).to include("dump_type")
        expect(run_in(:erasure, fixture_dir(fixture))).not_to include("Rigor::Plugin::_")
        expect(candidate).to eq(baseline)
      end
    end

    InterfaceParity::DISPATCH_MODES.each do |mode|
      it "#{fixture}: #{mode} differs from the erasure baseline only at declared-member calls" do
        baseline, candidate = dispatch_pair(mode, fixture_dir(fixture))

        expect(baseline).to include("dump_type")
        expect(run_in(:erasure, fixture_dir(fixture))).not_to include("Rigor::Plugin::_")
        expect(candidate).to eq(baseline)
      end
    end
  end

  describe "the controls" do
    let(:dir) { fixture_dir("joins") }

    # Default-on, as slice 1b's carrier: every mode but the erasure baseline sees it.
    def install_simulated_carrier
      allow(Rigor::Type::Combinator).to receive(:erased_facet?).and_wrap_original do |original, facet|
        InterfaceParity.simulated_facet?(facet) || original.call(facet)
      end
      translator = Rigor::Inference::RbsTypeTranslator
      allow(translator).to receive(:translate_untyped).and_wrap_original do |original, type, ctx|
        next original.call(type, ctx) if translator.interface_erasure? || !InterfaceParity.plugin_interface?(type)

        Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.nominal_of(type.name.relative!.to_s))
      end
    end

    it "refuses a pooled run under the erasure switch" do
      expect { Rigor::Inference::RbsTypeTranslator.with_interface_erasure { render(dir, workers: 2) } }
        .to raise_error(ArgumentError, /sequential run/)
    end

    it "normalises a facet name and nothing else" do
      expect(normalise("Dynamic[Rigor::Plugin::_Scope] | Dynamic[::Rigor::Plugin::_Each[Integer, Array[Integer]]]"))
        .to eq("Dynamic[top] | Dynamic[top]")
      expect(normalise("Dynamic[Rigor::Scope] | Rigor::Plugin::_Scope"))
        .to eq("Dynamic[Rigor::Scope] | Rigor::Plugin::_Scope")
    end

    it "passes a default-on carrier whose joins keep master's shape, though its rendered text differs" do
      install_simulated_carrier
      baseline, candidate = parity_pair(:default, dir)

      expect(run_in(:default, dir)).to include("Dynamic[Rigor::Plugin::_ProbeS]")
      expect(run_in(:erasure, dir)).not_to include("Rigor::Plugin")
      expect(candidate).to eq(baseline)
    end

    it "fails a default-on carrier whose joins keep an extra arm (the planted structural divergence)" do
      install_simulated_carrier
      allow(Rigor::Type::Combinator).to receive(:merge_erased_members) { |members| members }
      baseline, candidate = parity_pair(:default, dir)

      expect(candidate).not_to eq(baseline)
      expect(candidate).to include("[Dynamic[top]] | [Dynamic[top]]")
    end

    it "lets a dispatch mode differ on a declared-member call's row and nowhere else" do
      baseline = run_in(:erasure, dir)
      lines = InterfaceParity.declared_lines(dir)
      rows = JSON.parse(baseline)
      declared = rows.index { |row| lines.include?([row["path"], row["line"]]) }
      other = rows.index { |row| !lines.include?([row["path"], row["line"]]) }
      plant = lambda do |index|
        planted = rows.map(&:dup)
        planted[index]["message"] = "dump_type: String"
        JSON.pretty_generate(planted)
      end
      drop = ->(document) { InterfaceParity.without_rows(document, lines) }

      expect(declared).not_to be_nil
      expect(drop.call(plant.call(declared))).to eq(drop.call(baseline))
      expect(plant.call(declared)).not_to eq(baseline)
      expect(drop.call(plant.call(other))).not_to eq(drop.call(baseline))
    end
  end
end
