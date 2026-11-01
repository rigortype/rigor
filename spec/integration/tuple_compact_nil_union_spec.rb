# frozen_string_literal: true

# Issue #2519 — `Tuple#compact` folded only an all-`Constant` Tuple and declined otherwise, so the RBS tier answered
# `Array[E]` with the element's `nil` kept. `[x].compact` with `x: Dynamic[top] | Pathname | nil` then reported
# `call.possible-nil-receiver` on a correct `.each { |r| r.directory? }`. The `# fires` line is the positive control:
# the same element without `compact` must keep the report.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "Tuple#compact strips nil from a non-constant element (#2519)" do
  def diagnostics(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "roots.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    )
    result.diagnostics.select { |d| d.qualified_rule == "call.possible-nil-receiver" }.map(&:line)
  end

  around do |example|
    Dir.mktmpdir("rigor-tuple-compact-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:source) do
    <<~RUBY
      require "pathname"

      module Roots
        def self.sel(loader)
          c = loader.respond_to?(:core_root) ? loader.core_root : nil
          c && Pathname(c)
        end

        def self.compacted(loader)
          roots = [sel(loader)].compact + [Pathname("a")]
          roots.each { |r| r.directory? }
        end

        def self.uncompacted(loader)
          [sel(loader)].each { |r| r.directory? } # fires
        end
      end
    RUBY
  end

  it "reports only the uncompacted call" do
    fires = source.lines.each_index.select { |i| source.lines[i].include?("# fires") }.map { |i| i + 1 }
    expect(diagnostics(source)).to eq(fires)
  end
end
