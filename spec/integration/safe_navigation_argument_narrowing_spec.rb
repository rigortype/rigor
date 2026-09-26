# frozen_string_literal: true

# Issue #1468 — Ruby evaluates the arguments of `recv&.m(args)` only when `recv` is non-nil, but they were typed
# without that narrowing, so `klass&.new(klass.flag? ? 1 : nil)` reported an error-level
# `call.possible-nil-receiver` on correct code. The gap predates v0.3.9 (`pick2`); a computed-key read of a hash
# shape including `nil` for the keys it does not declare (#1278) is what made `pick` reach it, on the Mastodon
# v4.5.10 `Admin::Metrics::Dimension` / `Measure` constructors the release-gate sweep pins.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "safe-navigation arguments read the receiver non-nil (#1468)" do
  def diagnostics
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    )
    result.diagnostics.map { |d| [d.line, d.qualified_rule] }
  end

  around do |example|
    Dir.mktmpdir("rigor-safe-nav-arguments-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "keeps pick and pick2 silent and reports a different nilable local" do
    # `flag?` does not fold, so the ternary is a live condition and nothing but the receiver rule can speak.
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "pick.rb"), <<~RUBY)
      class Foo
        def self.flag? = rand < 0.5
        def initialize(x); end
      end

      MAP = { foo: Foo }.freeze

      def pick(key)
        klass = MAP[key.to_sym]
        klass&.new(klass.flag? ? 1 : nil)
      end

      def pick2(x)
        y = x ? "s" : nil
        y&.concat(y.upcase)
      end

      def control(x)
        y = x ? "s" : nil
        z = x ? nil : "t"
        y&.concat(z.upcase)
      end
    RUBY

    expect(diagnostics).to eq([[21, "call.possible-nil-receiver"]])
  end
end
