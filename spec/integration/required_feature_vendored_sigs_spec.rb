# frozen_string_literal: true

# Issue #1700 — the vendored `prime` signatures load only when the project's source requires `prime`.
#
# `prime` left the default gems for the bundled gems and rbs 4.x no longer ships `stdlib/prime`, so after
# `require "prime"` a call into it on a receiver Rigor knows (`12.prime_division`) reported
# `call.undefined-method`. The gem's own `sig/` is vendored under `data/vendored_gem_sigs/prime/`, but it declares
# a top-level `class Prime` and reopens `Integer`, so it is gated on a literal `require "prime"` in the run's
# source: a project with its own `Prime` and no such require must not have the gem's signatures read against it.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "vendored signatures gated on a required feature (#1700)" do
  def config
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
  end

  def run(cache_store: nil)
    guarded_run(Rigor::Analysis::Runner.new(configuration: config, cache_store: cache_store), %w[lib])
  end

  def call_rows(result)
    calls = result.diagnostics.select { |d| d.qualified_rule.start_with?("call.") }
    calls.map { |d| "#{d.qualified_rule} #{d.message}" }
  end

  def write(path, source)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  around do |example|
    Dir.mktmpdir("rigor-required-feature-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "types prime's API after require \"prime\" and still reports a misspelt method" do
    write("lib/factor.rb", <<~RUBY)
      require "prime"

      p 12.prime_division
      p 7.prime?
      p Prime.each(10).to_a
      p Prime.prime?(7)
      p Integer.from_prime_division([[2, 2], [3, 1]])
      p 12.prime_divisionn
    RUBY

    expect(call_rows(run)).to contain_exactly(a_string_matching(/undefined method `prime_divisionn' for 12/))
  end

  it "loads them for a file that relies on another file's require" do
    write("lib/setup.rb", "require 'prime'\n")
    write("lib/use.rb", "p 12.prime_division\n")

    expect(call_rows(run)).to be_empty
  end

  it "does not read them against a project's own Prime when nothing requires prime" do
    write("lib/prime.rb", <<~RUBY)
      class Prime
        def initialize(n)
          @n = n
        end

        def prime?
          @n > 1
        end
      end

      p Prime.new(3).prime?
    RUBY

    expect(call_rows(run)).to be_empty
  end

  it "rebuilds rather than serving a cached environment when a file gains or drops the require" do
    store = Rigor::Cache::Store.new(root: File.join(Dir.pwd, ".rigor-cache"))
    write("lib/use.rb", "p 12.prime_division\n")
    expect(call_rows(run(cache_store: store))).to contain_exactly(a_string_matching(/prime_division/))

    write("lib/use.rb", "require \"prime\"\np 12.prime_division\n")
    expect(call_rows(run(cache_store: store))).to be_empty

    write("lib/use.rb", "p 12.prime_division\n")
    expect(call_rows(run(cache_store: store))).to contain_exactly(a_string_matching(/prime_division/))
  end

  it "moves the incremental snapshot fingerprint only for a project that requires a gated feature" do
    write("lib/use.rb", "p 12\n")
    before = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: %w[lib])

    write("lib/other.rb", "p 13\n")
    expect(Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: %w[lib])).to eq(before)

    write("lib/use.rb", "require 'prime'\np 12\n")
    expect(Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: %w[lib])).not_to eq(before)
  end
end
