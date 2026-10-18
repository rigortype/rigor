# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #2115 — a constant fold past `ConstantFolding::INTEGER_FOLD_BIT_LIMIT` answers the result's class rather
# than falling through to RBS, whose `Integer#**` is declared to return `Numeric`. Under `Numeric`, correct code
# such as `(2 ** 20_000).even?` would report `call.undefined-method`.
RSpec.describe "constant-fold budget at check level (#2115)" do
  def diagnostics_for(source)
    Dir.mktmpdir("rigor-constant-fold-budget-") do |tmpdir|
      lib = File.join(tmpdir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "probe.rb"), source)
      Dir.chdir(tmpdir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new("paths" => [lib]), cache_store: nil
        )
        guarded_run(runner).diagnostics.reject { |d| d.rule.start_with?("rbs.coverage") }
      end
    end
  end

  it "types an Integer power past the bit limit as Integer, so Integer methods resolve" do
    diagnostics = diagnostics_for(<<~RUBY)
      x = 2 ** 20_000
      x.even?
      x.bit_length
      x.digits.size
      (10 ** 5000).to_s(16)
      (1 << 20_000).odd?
    RUBY
    expect(diagnostics.map { |d| "#{d.line}: #{d.rule}: #{d.message}" }).to eq([])
  end

  it "still reports a method Integer does not have on the widened result" do
    diagnostics = diagnostics_for("(2 ** 20_000).upcase\n")
    expect(diagnostics.map(&:rule)).to eq(["call.undefined-method"])
    expect(diagnostics.first.message).to include("upcase").and include("Integer")
  end
end
