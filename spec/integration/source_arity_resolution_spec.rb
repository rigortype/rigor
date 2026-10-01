# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"
require_relative "../support/ruby_run"

# ADR-119 C1b — `call.wrong-arity` through `Inference::DefinerResolution` (instance side). Each shape is a program
# whose conditional mixin (`include Q if ENV["Q"]`) Ruby runs in BOTH worlds under the suite's own Ruby: the
# diagnostic is silent wherever the chain does not stand for the name, and the one named-mark control keeps firing
# because Ruby raises in both worlds. A diagnostic assertion beside a Ruby run is what makes a silence a decline
# and not an analysis that found nothing.
RSpec.describe "call.wrong-arity through the candidate-set read (ADR-119 C1b)" do
  def arity_diagnostics(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "demo.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
      .diagnostics.select { |diagnostic| diagnostic.qualified_rule == "call.wrong-arity" }.map(&:line)
  end

  # What the final call does in the world where `ENV["Q"]` is unset (`false`) or set (`true`) — `:arity` for an
  # ArgumentError.
  def ruby_outcomes(declarations, call, prelude: nil)
    [false, true].map do |world|
      attempt = "begin; #{call}; :ok; rescue ArgumentError; :arity; end"
      program = "#{'ENV["Q"] = "1"' if world}\n#{declarations}\nputs(#{attempt})\n"
      RubyRun.stdout(program, prelude: prelude).chomp.to_sym
    end
  end

  def arity_diagnostics_files(files)
    FileUtils.mkdir_p("lib")
    files.each { |name, source| File.write(File.join("lib", name), source) }
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
      .diagnostics.select { |diagnostic| diagnostic.qualified_rule == "call.wrong-arity" }.map(&:line)
  end

  def line_of_call(declarations) = declarations.lines.size + 1

  around do |example|
    Dir.mktmpdir("rigor-source-arity-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # The control: `Q` records `bar` only, so it cannot answer `foo`, the named mark is discharged, and Ruby raises in
  # both worlds. Without relevance this would go silent with the rest.
  it "keeps firing where the named mark cannot answer the name and Ruby raises in both worlds" do
    declarations = <<~RUBY
      module Q; def bar = 1; end
      class Base; def foo(x) = x; end
      class C < Base; include Q if ENV["Q"]; end
    RUBY
    expect(ruby_outcomes(declarations, "C.new.foo")).to eq(%i[arity arity])
    expect(arity_diagnostics("#{declarations}C.new.foo\n")).to eq([line_of_call(declarations)])
  end

  it "is silent where the named mark answers the name, and Ruby's worlds disagree" do
    declarations = <<~RUBY
      module Q; def foo(x) = x; end
      class Base; def foo = 1; end
      class C < Base; include Q if ENV["Q"]; end
    RUBY
    expect(ruby_outcomes(declarations, "C.new.foo")).to eq(%i[ok arity])
    expect(arity_diagnostics("#{declarations}C.new.foo\n")).to eq([])
  end

  describe "a chain with a fork" do
    let(:header) do
      <<~RUBY
        module M; def foo(a, b) = :m; end
        module X; def foo(a) = :x; end
        module Q; def bar = 1; end
        class Base; include M; def foo(a, b, c) = :base; end
      RUBY
    end

    # Ruby answers X#foo in both worlds, so the call is an error in both and the rule declines anyway: a one-fork
    # chain is never narrowed (WD2). FLIP THIS if relevance is extended to one-fork chains.
    it "declines the one-fork witness (f3c) although Ruby raises in both worlds" do
      declarations = "#{header}class C < Base; include M; include X; include Q if ENV[\"Q\"]; end\n"
      expect(ruby_outcomes(declarations, "C.new.foo")).to eq(%i[arity arity])
      expect(arity_diagnostics("#{declarations}C.new.foo\n")).to eq([])
    end

    it "declines the fork without X (f3b), where Ruby answers Base's own def in both worlds" do
      declarations = "#{header}class C < Base; include M; include Q if ENV[\"Q\"]; end\n"
      expect(ruby_outcomes(declarations, "C.new.foo(1, 2, 3)")).to eq(%i[ok ok])
      expect(arity_diagnostics("#{declarations}C.new.foo(1, 2, 3)\n")).to eq([])
    end
  end

  # The five non-discharge shapes of WD2: each mark's named entry (or the mark itself) could answer the name.
  describe "the non-discharge shapes" do
    {
      "an include of a module the project does not declare" =>
        ["module Q; include Ext; end\n", "module Ext; def foo(*) = :ext; end\n", %i[arity ok]],
      "a define_method loop in the module" =>
        ["module Q; [:foo].each { |name| define_method(name) { |*| 2 } }; end\n", nil, %i[arity ok]],
      "a literal define_method in the module" =>
        ["module Q; define_method(:foo) { |*| 2 }; end\n", nil, %i[arity ok]],
      "a method_missing in the module" =>
        ["module Q; def method_missing(name, *) = 1; end\n", nil, %i[arity arity]],
      "a mixin call the walk cannot record" =>
        ["module X; def foo(*) = 2; end\nmodule Q; def bar = 1; end\n", nil, nil]
    }.each do |label, (module_q, prelude, expected)|
      it "is silent for #{label}" do
        sent = label == "a mixin call the walk cannot record"
        mixin = sent ? 'send(:include, X) if ENV["Q"]' : 'include Q if ENV["Q"]'
        declarations = "#{module_q}class Base; def foo(a) = a; end\nclass C < Base; #{mixin}; end\n"
        expected ||= %i[arity ok]
        expect(ruby_outcomes(declarations, "C.new.foo(1, 2)", prelude: prelude)).to eq(expected)
        expect(arity_diagnostics("#{declarations}C.new.foo(1, 2)\n")).to eq([])
      end
    end
  end

  # #1594's arity variant: the concern's `included do include A end` puts `M` (through `A`) ahead of `Base`.
  # Ruby's `C#foo` is `M#foo(x)`, so `C.new.foo(1)` is correct and master's `Base#foo()` fired on it.
  describe "a concern's included block (#1594)" do
    let(:shim) do
      <<~RUBY
        module ActiveSupport
          module Concern
            def self.extended(base) = base.instance_variable_set(:@_included_block, nil)

            def included(base = nil, &block)
              if base.nil?
                @_included_block = block
              else
                super
                base.class_eval(&@_included_block) if @_included_block
              end
            end
          end
        end
      RUBY
    end
    let(:declarations) do
      <<~RUBY
        module M; def foo(x) = x; end
        module A; include M; end
        module Concern
          extend ActiveSupport::Concern
          included do
            include A
          end
        end
        class Base; def foo = 1; end
        class C < Base; include Concern; end
      RUBY
    end

    it "is silent for a call that fits the definer Ruby reaches" do
      program = "#{declarations}p C.new.foo(1)\n"
      expect(RubyRun.stdout(program, prelude: shim).chomp).to eq("1")
      expect(arity_diagnostics("#{declarations}C.new.foo(1)\n")).to eq([])
    end
  end

  # Without the condition the mixin is a plain `include`, the chain stands, and Ruby raises in both worlds.
  it "fires once the conditional mixin is an unconditional one" do
    declarations = <<~RUBY
      module Q; def foo(x) = x; end
      class Base; def foo = 1; end
      class C < Base; include Q; end
    RUBY
    expect(ruby_outcomes(declarations, "C.new.foo")).to eq(%i[arity arity])
    expect(arity_diagnostics("#{declarations}C.new.foo\n")).to eq([line_of_call(declarations)])
  end

  # A multi-file mark with two defining closures (ADR-119 Q4): two files each reopen `User` and include a module
  # defining `greet(x)`. Ruby raises whichever file loads first, and master fired; the read declines, because the
  # order the two includes ran in is not a fact the tables hold (tp-lost by design).
  it "declines a class reopened in two files whose two includes both define the name" do
    first = "module A; def greet(x) = x; end\nclass User; include A; end\n"
    second = "module B; def greet(x) = x; end\nclass User; include B; end\n"
    call = "User.new.greet"
    [[first, second], [second, first]].each do |order|
      expect(ruby_outcomes(order.join, call)).to eq(%i[arity arity])
    end
    expect(arity_diagnostics_files("a.rb" => first, "b.rb" => second, "c.rb" => "#{call}\n")).to eq([])
  end
end
