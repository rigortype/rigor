# frozen_string_literal: true

# Issue #2297 — the callee mutation floor resolved a self-call in a singleton-side body (`def self.run`, a `def` in
# `class << self`) against the instance-side def table, and did not follow `send(:name, ...)` /
# `public_send(:name, ...)`. Each row is a file whose `run` passes `acc = [7, 9]` to a callee that mutates it (or not)
# and then calls `upcase` on `acc[0]`; the expectation is the diagnostics `rigor check` reports for it, which Ruby
# agrees with: `"X"` when the callee writes `"x"` into slot 0, a NoMethodError on `7` when nothing does.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "the callee mutation floor resolves singleton self-calls and literal send hand-offs (#2297)" do
  def diagnostics(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "mut.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.map { |d| [d.line, d.qualified_rule] }
  end

  around do |example|
    Dir.mktmpdir("rigor-callee-singleton-send-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:undefined_upcase) { [[5, "call.undefined-method"]] }

  # `run` at lines 2-6, `acc[0].upcase` on line 5, then `defs`.
  def singleton_run(call, defs)
    <<~RUBY
      class Mut
        def self.run
          acc = [7, 9]
          #{call}
          acc[0].upcase
        end

      #{defs.gsub(/^/, '  ')}
      end
    RUBY
  end

  def instance_run(call, defs)
    singleton_run(call, defs).sub("def self.run", "def run")
  end

  context "with a singleton-side caller" do
    it "floors an argument the same-named singleton callee mutates" do
      expect(diagnostics(singleton_run("helper(acc)", <<~RUBY))).to eq([])
        def self.helper(acc) = (acc[0] = "x")
      RUBY
    end

    it "floors an argument a two-level singleton chain mutates" do
      expect(diagnostics(singleton_run("one(acc)", <<~RUBY))).to eq([])
        def self.one(acc) = two(acc)
        def self.two(acc) = (acc[0] = "x")
      RUBY
    end

    it "keeps the report when only the same-named instance chain mutates" do
      expect(diagnostics(singleton_run("stripes(acc)", <<~RUBY))).to eq(undefined_upcase)
        def self.stripes(acc) = acc.size
        def stripes(acc) = poke(acc)
        def poke(acc) = (acc[0] = "x")
      RUBY
    end

    it "resolves a singleton chain's next hop on the singleton side too" do
      expect(diagnostics(singleton_run("stripes(acc)", <<~RUBY))).to eq(undefined_upcase)
        def self.stripes(acc) = poke(acc)
        def self.poke(acc) = acc.size
        def poke(acc) = (acc[0] = "x")
      RUBY
    end

    it "floors an argument a callee defined in `class << self` mutates" do
      source = <<~RUBY
        class Mut
          class << self
            def run
              acc = [7, 9]
              helper(acc)
              acc[0].upcase
            end

            def helper(acc) = (acc[0] = "x")
          end
        end
      RUBY
      expect(diagnostics(source)).to eq([])
    end

    # Guard: the singleton def table already holds an `extend self` module's instance defs.
    it "resolves an `extend self` module's instance def from its singleton side" do
      source = <<~RUBY
        module Mut
          extend self
          def self.run
            acc = [7, 9]
            helper(acc)
            acc[0].upcase
          end

          def helper(acc) = (acc[0] = "x")
        end
      RUBY
      expect(diagnostics(source)).to eq([])
    end
  end

  # `Mut.run` reaches the later singleton `poke` and Ruby raises on `7`; `run_instance` reaches the instance `poke`.
  it "resolves one module_function def's hand-offs per side when callers on both sides reach it" do
    source = <<~RUBY
      module Mut
        def self.run
          acc = [7, 9]
          stripes(acc)
          acc[0].upcase
        end

        def run_instance
          acc = [7, 9]
          stripes(acc)
          acc[0].upcase
        end

        module_function

        def stripes(acc) = poke(acc)
        def poke(acc) = (acc[0] = "x")
        def self.poke(acc) = acc.size
      end
    RUBY
    expect(diagnostics(source)).to eq([[5, "call.undefined-method"]])
  end

  context "with an instance-side caller" do
    it "keeps resolving to the instance def when a same-named singleton def mutates" do
      expect(diagnostics(instance_run("stripes(acc)", <<~RUBY))).to eq(undefined_upcase)
        def stripes(acc) = acc.size
        def self.stripes(acc) = (acc[0] = "x")
      RUBY
    end

    it "floors an argument a module_function callee mutates" do
      source = <<~RUBY
        module Mut
          module_function

          def run
            acc = [7, 9]
            helper(acc)
            acc[0].upcase
          end

          def helper(acc) = (acc[0] = "x")
        end
      RUBY
      expect(diagnostics(source)).to eq([])
    end
  end

  context "with a send hand-off" do
    it "follows `send` with a symbol literal" do
      expect(diagnostics(instance_run("send(:poke, acc)", <<~RUBY))).to eq([])
        def poke(acc) = (acc[0] = "x")
      RUBY
    end

    it "follows `public_send` with a symbol literal" do
      expect(diagnostics(instance_run("public_send(:poke, acc)", <<~RUBY))).to eq([])
        def poke(acc) = (acc[0] = "x")
      RUBY
    end

    it "binds the arguments after the name to the callee's parameters in order" do
      expect(diagnostics(instance_run("self.send(:poke, 1, acc)", <<~RUBY))).to eq([])
        def poke(n, acc) = (acc[0] = "x" * n)
      RUBY
    end

    it "does not floor an argument bound to a parameter the callee leaves alone" do
      expect(diagnostics(instance_run("send(:poke, acc, [])", <<~RUBY))).to eq(undefined_upcase)
        def poke(other, acc) = (acc[0] = "x")
      RUBY
    end

    it "follows a literal `send` along a chain" do
      expect(diagnostics(instance_run("stripes(acc)", <<~RUBY))).to eq([])
        def stripes(acc) = send(:poke, 0, acc)
        def poke(n, acc) = (acc[n] = "x")
      RUBY
    end

    it "follows a literal `send` in a singleton-side body to the singleton def" do
      expect(diagnostics(singleton_run("send(:poke, acc)", <<~RUBY))).to eq([])
        def self.poke(acc) = (acc[0] = "x")
      RUBY
    end

    it "leaves a non-literal `send` target as it was" do
      expect(diagnostics(instance_run("send(name, acc)", <<~RUBY))).to eq(undefined_upcase)
        def name = :poke
        def poke(acc) = (acc[0] = "x")
      RUBY
    end
  end
end
