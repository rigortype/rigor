# frozen_string_literal: true

require "tmpdir"

# Issue #2969 — the four BigDecimal readers that rbs 4.2 and the bigdecimal gem's own `sig/` omit, declared
# by `data/core_overlay/bigdecimal.rbs`. The overlay is unconditional (bigdecimal is a default library), so no
# Gemfile.lock is written here: the rows hold on a project that locks nothing.
#
# Every example pins the resolved TYPE next to the absent diagnostic. A duplicate declaration collapses the
# class to `Dynamic[top]`, which reports nothing, so an absence-only assertion would pass on the wreck (#672).
require "spec_helper"

RSpec.describe "core overlay — BigDecimal precision readers (#2969)" do
  def run_source(source)
    Dir.mktmpdir("rigor-bigdecimal-overlay-") do |dir|
      File.write(File.join(dir, "code.rb"), source)
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new("paths" => [File.join(dir, "code.rb")])
        guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
      end
    end
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map { |d| d.message.sub("dump_type: ", "") }
  end

  def call_rules(result)
    result.diagnostics.map(&:qualified_rule).grep(/\Acall\./)
  end

  {
    "precision" => "Integer",
    "scale" => "Integer",
    "precision_scale" => "[Integer, Integer]",
    "n_significant_digits" => "Integer"
  }.each do |method, type|
    it "reads BigDecimal##{method} as #{type} with no call.undefined-method" do
      result = run_source(<<~RUBY)
        require "bigdecimal"
        Rigor.dump_type(BigDecimal("12.50").#{method})
      RUBY

      expect(call_rules(result)).to be_empty
      expect(dumps(result)).to eq([type])
    end
  end

  # Review of #2973 (minor): the overlay is gated on the bigdecimal library (`LIBRARY_SUPPLEMENT_CORE_OVERLAYS`), so
  # a loader that does not load it gets no `BigDecimal` from the file. Ungated, it opened a phantom class.
  it "declares no BigDecimal when the bigdecimal library is not loaded" do
    loader = Rigor::Environment::RbsLoader.new(libraries: [])

    expect(loader.instance_definition("BigDecimal")).to be_nil
  end

  # The guard that the overlay is not a blanket "BigDecimal answers anything": a method no source declares
  # still reports, so a typo on a BigDecimal receiver is not silenced by the new rows.
  it "still reports a method BigDecimal does not declare" do
    result = run_source(<<~RUBY)
      require "bigdecimal"
      BigDecimal("12.50").precison
    RUBY

    expect(result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message))
      .to include(a_string_including("precison"))
  end
end
