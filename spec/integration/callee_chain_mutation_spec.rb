# frozen_string_literal: true

# Issue #2104 — a collection handed to a method that hands it on to a method that mutates it was floored only when
# the first callee mutated it itself, so `acc = INIT.dup; stripes(acc); head_of(acc).upcase` kept `acc` the literal
# `[7, 9]` and reported `call.undefined-method` for `7` on correct code (`XXH3#hash_long`). Each row is a file whose
# `run` mutates `acc` (or not) through a chain of self-calls and then calls `upcase` on `acc[0]`; the expectation is
# the diagnostics `rigor check` reports for it.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a callee chain that mutates an argument floors it (#2104)" do
  def diagnostics(body, call: "stripes(acc)")
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "mut.rb"), <<~RUBY)
      class Mut
        P1 = 7
        INIT = [P1, 9].freeze

        def run
          acc = INIT.dup
          #{call}
          head_of(acc).upcase
        end

        def head_of(acc) = acc[0]

      #{body.gsub(/^/, '  ')}
      end
    RUBY
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.map { |d| [d.line, d.qualified_rule] }
  end

  around do |example|
    Dir.mktmpdir("rigor-callee-chain-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:undefined_upcase) { [[8, "call.undefined-method"]] }

  it "floors an argument a two-level chain mutates" do
    expect(diagnostics(<<~RUBY)).to eq([])
      def stripes(acc) = poke(acc)
      def poke(acc) = (acc[0] = "x")
    RUBY
  end

  it "floors an argument a three-level chain mutates" do
    expect(diagnostics(<<~RUBY)).to eq([])
      def stripes(acc) = middle(1, acc)
      def middle(n, acc) = poke(acc)
      def poke(acc) = (acc[0] = "x")
    RUBY
  end

  it "floors an argument forwarded as a keyword and taken as one" do
    expect(diagnostics(<<~RUBY)).to eq([])
      def stripes(acc) = middle(into: acc)
      def middle(into:) = poke(target: into)
      def poke(target:) = (target[0] = "x")
    RUBY
  end

  it "floors an argument the caller passes as a keyword to a callee that mutates it" do
    expect(diagnostics(<<~RUBY, call: "poke(target: acc)")).to eq([])
      def poke(target:) = (target[0] = "x")
    RUBY
  end

  it "floors an argument forwarded with the keyword shorthand" do
    expect(diagnostics(<<~RUBY)).to eq([])
      def stripes(acc) = poke(acc:)
      def poke(acc:) = (acc[0] = "x")
    RUBY
  end

  it "floors an argument the caller passes with the keyword shorthand" do
    expect(diagnostics(<<~RUBY, call: "poke(acc:)")).to eq([])
      def poke(acc:) = (acc[0] = "x")
    RUBY
  end

  it "floors an argument forwarded after a splat, whose position says nothing about its parameter" do
    expect(diagnostics(<<~RUBY)).to eq([])
      def stripes(acc) = poke(*[], acc)
      def poke(acc, n = 0) = (acc[0] = "x")
    RUBY
  end

  it "floors an argument forwarded from inside an iterator block" do
    expect(diagnostics(<<~RUBY)).to eq([])
      def stripes(acc) = 2.times { |s| poke(acc, s) }
      def poke(acc, s) = (acc[0] = "x" * s)
    RUBY
  end

  it "does not yet count a mutation inside a callee's non-escaping block (the remaining XXH3 gap)" do
    # Pins a decision, not a wish: the bare-collection floor this would apply fires `def.return-type-mismatch` on
    # haml's `AttributeCompiler#compile`, so the census leaves it out until the floor can keep the element type.
    expect(diagnostics(<<~RUBY)).to eq(undefined_upcase)
      def stripes(acc) = poke(acc)
      def poke(acc) = 2.times { |i| acc[i] = "x" }
    RUBY
  end

  it "floors an argument a mutually recursive chain mutates" do
    expect(diagnostics(<<~RUBY)).to eq([])
      def stripes(acc) = ping(acc, 3)
      def ping(acc, n) = n.zero? ? poke(acc) : pong(acc, n - 1)
      def pong(acc, n) = ping(acc, n)
      def poke(acc) = (acc[0] = "x")
    RUBY
  end

  it "floors an argument a chain hands past the read cap, whose end it cannot see" do
    chain = (1..20).map { |i| "def hop#{i}(acc) = hop#{i + 1}(acc)" }
    expect(diagnostics(<<~RUBY)).to eq([])
      def stripes(acc) = hop1(acc)
      #{chain.join("\n")}
      def hop21(acc) = acc.size
    RUBY
  end

  it "keeps the literal shape, and the true positive, through a chain that never mutates" do
    expect(diagnostics(<<~RUBY)).to eq(undefined_upcase)
      def stripes(acc) = middle(acc)
      def middle(acc) = peek(acc: acc)
      def peek(acc:) = acc.size
    RUBY
  end

  it "keeps the literal shape through a recursive chain that never mutates, and terminates" do
    # With the closure's visited check removed this example spins until something interrupts it, and an interrupted
    # run can still answer the same diagnostics, so the time is the assertion that the closure terminates.
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(diagnostics(<<~RUBY)).to eq(undefined_upcase)
      def stripes(acc) = walk(acc, 3)
      def walk(acc, n) = n.zero? ? acc.size : walk(acc, n - 1)
    RUBY
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 20
  end

  it "does not read a block parameter that shadows the forwarded parameter as the parameter" do
    expect(diagnostics(<<~RUBY)).to eq(undefined_upcase)
      def stripes(acc) = [[1]].each { |acc| poke(acc) }
      def poke(acc) = (acc[0] = "x")
    RUBY
  end

  describe "the content-mutated parameter effects surface" do
    it "reports a mutated keyword parameter by its keyword, after the positions" do
      def_node = Prism.parse(<<~RUBY).value.statements.body.first
        def fill(a, b, into:, also:)
          a << 1
          also << 1
          into[0] = 1
        end
      RUBY
      evaluator = Rigor::Inference::StatementEvaluator.new(scope: Rigor::Scope.empty)
      expect(evaluator.content_mutated_parameter_positions(def_node)).to eq([0, :also, :into])
    end
  end

  describe "the effects surface for a forwarded parameter" do
    it "reports a parameter handed on to a self-call the empty scope cannot resolve" do
      def_node = Prism.parse(<<~RUBY).value.statements.body.first
        def stripes(acc, n, kept)
          poke(n, acc)
          kept.size
        end
      RUBY
      evaluator = Rigor::Inference::StatementEvaluator.new(scope: Rigor::Scope.empty)
      expect(evaluator.content_mutated_parameter_positions(def_node)).to eq([0, 1])
    end
  end
end
