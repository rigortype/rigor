# frozen_string_literal: true

# Issue #2297 — the callee mutation floor resolved a self-call in a singleton-side body (`def self.run`, a `def` in
# `class << self`) against the instance-side def table, and did not follow `send(:name, ...)` /
# `public_send(:name, ...)`. Each row is a file whose `run` passes `acc = [7, 9]` to a callee that mutates it (or not)
# and then calls `upcase` on `acc[0]`; the expectation is the diagnostics `rigor check` reports for it, which Ruby
# agrees with: `"X"` when the callee writes `"x"` into slot 0, a NoMethodError on `7` when nothing does. On the
# singleton side the floor also reads the same-named instance def, so two controls pin the true positives that costs
# (`approval-queue.d/callee-floor-singleton-side.md`).

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

  def dumped(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "mut.rb"), %(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
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

    # Control, an accepted loss: Ruby raises on `7`, as only the instance `stripes` chain mutates, but the singleton
    # side also reads the same-named instance def.
    it "floors an argument only the same-named instance chain mutates" do
      expect(diagnostics(singleton_run("stripes(acc)", <<~RUBY))).to eq([])
        def self.stripes(acc) = acc.size
        def stripes(acc) = poke(acc)
        def poke(acc) = (acc[0] = "x")
      RUBY
    end

    # Control, an accepted loss: Ruby reaches the non-mutating `self.poke` and raises on `7`; the next hop of a
    # singleton chain reads the same-named instance `poke` too.
    it "floors an argument the same-named instance def mutates at a singleton chain's next hop" do
      expect(diagnostics(singleton_run("stripes(acc)", <<~RUBY))).to eq([])
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

  # `Mut.run` reaches the later, mutating `self.poke` ("X"); `run_instance` reaches the instance `poke` and Ruby raises
  # on `7`. The module_function `stripes` is one def on both sides, so its hand-offs must not share one answer.
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
        def poke(acc) = acc.size
        def self.poke(acc) = (acc[0] = "x")
      end
    RUBY
    expect(diagnostics(source)).to eq([[11, "call.undefined-method"]])
  end

  # Each channel floors through every def the call resolves to before the next channel runs, so the instance def's
  # direct mutation takes the bare floor even though the singleton def, read first, mutates nothing.
  it "applies the bare floor through the second def a singleton-side call resolves to" do
    source = <<~RUBY
      class Mut
        def self.run
          acc = [7, 9]
          stripes(acc)
          dump_type(acc)
        end

        def self.stripes(acc) = acc.size
        def stripes(acc) = (acc[0] = "x")
      end
    RUBY
    expect(dumped(source)).to eq(["Array[Dynamic[top]]"])
  end

  # Each shape hands the argument from the singleton side to a mutating instance def, or reaches a singleton def the
  # index does not record, through a path the floor does not follow; Ruby answers "X" for each.
  context "with a singleton-side hand-off the floor does not follow" do
    it "floors through the same-named instance def behind a `new.call` facade" do
      expect(diagnostics(singleton_run("call(acc)", <<~RUBY))).to eq([])
        def self.call(acc) = new.call(acc)
        def call(acc) = (acc[0] = "x")
      RUBY
    end

    # Ruby answers `[1, 2]`; reading `a` at its entry contents at every position folded `[1, 1]`.
    it "counts a block's call into the same-named instance def behind a facade as a mutation of its capture" do
      source = <<~RUBY
        class Mut
          def self.run
            a = [1]
            r = [1, 2].map { |e| v = a.size; add(a, e); v }
            dump_type(r)
          end

          def self.add(a, e) = new.add(a, e)
          def add(a, e) = (a << e)
        end
      RUBY
      expect(dumped(source)).to eq(["[non-negative-int, non-negative-int]"])
    end

    it "floors through the same-named instance def behind a singleton instance" do
      expect(diagnostics(singleton_run("helper(acc)", <<~RUBY))).to eq([])
        def self.instance = @instance ||= new
        def self.helper(acc) = instance.helper(acc)
        def helper(acc) = (acc[0] = "x")
      RUBY
    end

    # Guard: passes before the instance-def reading too; the index already publishes `module_function :name` and
    # `module_function def` on the singleton side.
    it "floors through a def made a module function by `module_function :name`" do
      source = <<~RUBY
        module Mut
          def self.run
            acc = [7, 9]
            poke(acc)
            acc[0].upcase
          end

          def poke(acc) = (acc[0] = "x")
          module_function :poke
        end
      RUBY
      expect(diagnostics(source)).to eq([])
    end

    it "floors through the same-named instance def beside `define_singleton_method`" do
      expect(diagnostics(singleton_run("poke(acc)", <<~RUBY))).to eq([])
        define_singleton_method(:poke) { |acc| acc[0] = "x" }
        def poke(acc) = (acc[0] = "x")
      RUBY
    end

    it "floors through the same-named instance def beside an `alias_method` in `class << self`" do
      source = <<~RUBY
        class Mut
          class << self
            def run
              acc = [7, 9]
              poke(acc)
              acc[0].upcase
            end

            def real(acc) = (acc[0] = "x")
            alias_method :poke, :real
          end

          def poke(acc) = (acc[0] = "x")
        end
      RUBY
      expect(diagnostics(source)).to eq([])
    end
  end

  context "with an instance-side caller" do
    # Guard: the base engine already resolved an instance-side self-call on the instance side.
    it "keeps resolving to the instance def when a same-named singleton def mutates" do
      expect(diagnostics(instance_run("stripes(acc)", <<~RUBY))).to eq(undefined_upcase)
        def stripes(acc) = acc.size
        def self.stripes(acc) = (acc[0] = "x")
      RUBY
    end

    # Guard: module_function already worked on the base engine.
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

    it "reads `send` as an ordinary self-call when the class defines its own `send`" do
      expect(diagnostics(instance_run("send(:ping, acc)", <<~RUBY))).to eq([])
        def send(kind, buf) = (buf[0] = "x")
      RUBY
    end

    it "reads `public_send` as an ordinary self-call when the class defines its own `public_send`" do
      expect(diagnostics(instance_run("public_send(:ping, acc)", <<~RUBY))).to eq([])
        def public_send(kind, buf) = (buf[0] = "x")
        def ping(buf) = buf.size
      RUBY
    end

    # Guard: a non-literal target is unchanged from the base engine (Ruby answers "X"; the report stays).
    it "leaves a non-literal `send` target as it was" do
      expect(diagnostics(instance_run("send(name, acc)", <<~RUBY))).to eq(undefined_upcase)
        def name = :poke
        def poke(acc) = (acc[0] = "x")
      RUBY
    end
  end
end
