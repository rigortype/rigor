# frozen_string_literal: true

require "spec_helper"
require_relative "../support/ruby_run"

# ADR-119 PR C1c (instance side) — the override lints (`def.override-visibility-reduced`,
# `def.override-return-widened`, `def.override-param-narrowed`) and `def.method-visibility-mismatch` read their
# definer through `Inference::DefinerResolution`. Where the chain does not settle (a conditional or block-scoped
# `include` / `prepend`, a concern's `included do include A end`) the read is `Unknown` and the lint stays silent,
# instead of answering from the breadth-first order the walk used before. Each shape is witnessed by Ruby first;
# each is followed by a control on the same lint that must still fire, so a run that analysed nothing cannot pass
# by reporting nothing. Refs #1562, #1594.
RSpec.describe "relationship lints over DefinerResolution (ADR-119 C1c)", type: :runner do
  def rules(source, sig: {})
    analyze(source, sig: sig).diagnostics.reject { |d| d.severity == :info }.map { |d| [d.line, d.rule] }
  end

  let(:concern_shim) do
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

  describe "a concern's `included do include A end` (#1594)" do
    # Ruby's order is `[C, A, M, Concern, Base]`: `C#foo` overrides the PRIVATE `M#foo`, which is no reduction.
    # Master's order found `Base#foo` (public) and reported one.
    let(:visibility_source) do
      <<~RUBY
        module M; private; def foo = "M"; end
        module A; include M; end
        module Concern
          extend ActiveSupport::Concern
          included do
            include A
          end
        end
        class Base; def foo = 1; end
        class C < Base
          include Concern
          private
          def foo = 2
        end
      RUBY
    end

    # The same chain for the return-type lint: `M#foo` returns String, `Base#foo` Integer, and `C#foo` String.
    let(:widened_sig) do
      { "d.rbs" => <<~RBS }
        class Base
          def foo: () -> Integer
        end
        module M
          def foo: () -> String
        end
        module A
          include M
        end
        module Concern
        end
        class C < Base
          def foo: () -> String
        end
      RBS
    end

    it "runs C#foo over the private M#foo under Ruby" do
      printed = RubyRun.stdout("#{visibility_source}p C.ancestors.first(5)\np M.private_instance_methods(false)\n",
                               prelude: concern_shim)
      expect(printed).to eq("[C, A, M, Concern, Base]\n[:foo]\n")
    end

    it "does not report a reduced visibility against the superclass's public method" do
      expect(rules(visibility_source)).to eq([])
    end

    it "still reports the reduction on a class with no such concern (control)" do
      source = <<~RUBY
        class Base; def foo = 1; end
        class K < Base
          private
          def foo = 2
        end
      RUBY
      expect(rules(source)).to eq([[4, "def.override-visibility-reduced"]])
    end

    it "does not report a widened return against the superclass's signature" do
      source = visibility_source.sub("module M; private; def", "module M; def").sub("  private\n", "")
                                .sub("def foo = 2", 'def foo = "c"')
      expect(rules(source, sig: widened_sig)).to eq([])
    end

    it "still reports a widened return on a plain subclass (control)" do
      sig = { "d.rbs" => <<~RBS }
        class Base
          def foo: () -> Integer
        end
        class K < Base
          def foo: () -> String
        end
      RBS
      source = <<~RUBY
        class Base; def foo = 1; end
        class K < Base
          def foo = "k"
        end
      RUBY
      expect(rules(source, sig: sig)).to eq([[3, "def.override-return-widened"]])
    end
  end

  describe "a prepend the walk cannot prove runs" do
    let(:body) do
      <<~RUBY
        module P; def foo = 1; end
        class C
          %<prepend>s
          private
          def foo = 2
        end
        C.new.foo
      RUBY
    end

    # `P#foo` is public and sits ahead of `C#foo`; Ruby calls it. Master reported both a reduction of `P#foo` and
    # a private call.
    { "conditional" => 'prepend P if ENV["X"]', "block" => "[1].each { prepend P }" }.each do |shape, prepend|
      it "runs the public P#foo under Ruby (#{shape})" do
        source = format(body, prepend: prepend)
        printed = RubyRun.stdout("ENV['X'] = '1'\n#{source.sub('C.new.foo', "p C.new.foo\np C.ancestors.first(2)")}")
        expect(printed).to eq("1\n[P, C]\n")
      end

      it "declines both lints (#{shape})" do
        expect(rules(format(body, prepend: prepend))).to eq([])
      end
    end

    it "still reports the private call when nothing is prepended (control)" do
      expect(rules(format(body, prepend: ""))).to eq([[7, "def.method-visibility-mismatch"]])
    end

    it "keeps the call unreported where a plain `prepend P` puts a public definer ahead (#1568)" do
      expect(rules(format(body, prepend: "prepend P"))).to eq([])
    end
  end

  # A receiverless `def` inside `class << self` is a singleton def, whatever the instance side holds: the return-type
  # lint reads `Scope#singleton_class_body?`, not the two discovered-method tables, which took a name defined on both
  # facets for the instance def and compared `K.load`'s body against `K#load`'s signature.
  describe "a `class << self` def beside an instance def of the same name" do
    let(:load_sig) do
      { "k.rbs" => <<~RBS }
        class K
          def load: () -> Integer
          def self.load: () -> String
        end
      RBS
    end
    let(:load_source) do
      <<~RUBY
        class K
          def load = 1 if ENV["X"]

          class << self
            def load = %<body>s
          end
        end
      RUBY
    end

    it "runs the singleton load over the instance load under Ruby" do
      printed = RubyRun.stdout("ENV['X'] = '1'\n#{format(load_source,
                                                         body: '"s"')}p K.load\np K.instance_methods(false)\n")
      expect(printed).to eq("\"s\"\n[:load]\n")
    end

    it "compares the body with the singleton signature" do
      expect(rules(format(load_source, body: '"s"'), sig: load_sig)).to eq([])
    end

    it "still reports a body that disagrees with the singleton signature (control)" do
      expect(rules(format(load_source, body: "2"), sig: load_sig)).to eq([[5, "def.return-type-mismatch"]])
    end
  end

  # A receiver-eval block defines on another object than the class body's `self`, so the side a receiverless `def`
  # answers for is the indexer's record of that node, not the scope's `class << self` mark.
  describe "a receiverless def in a receiver-eval block" do
    def eval_sig(singleton_return)
      { "d.rbs" => <<~RBS }
        class D
          def load: () -> String
          def self.load: () -> #{singleton_return}
        end
      RBS
    end

    {
      "instance_eval in the class body defines D.load" =>
        ["Integer", "class D\n  instance_eval do\n    def load = 1\n  end\nend\n"],
      "E.instance_eval inside class << self defines E.load" =>
        ["String",
         "class E; end\nclass D\n  class << self\n    E.instance_eval do\n      def load = 1\n    end\n  end\nend\n"],
      "E.class_eval inside class << self defines E#load" =>
        ["String",
         "class E; end\nclass D\n  class << self\n    E.class_eval do\n      def load = 1\n    end\n  end\nend\n"]
    }.each do |name, (singleton_return, source)|
      it "does not compare the body with D's signatures: #{name}" do
        expect(rules(source, sig: eval_sig(singleton_return))).to eq([])
      end
    end

    it "runs those defs on the other receiver under Ruby" do
      printed = RubyRun.stdout(
        "class E; end\nclass D; end\nD.instance_eval { def load = 1 }\nE.class_eval { def load = 2 }\n" \
        "p D.load, E.new.load, D.instance_methods(false)\n"
      )
      expect(printed).to eq("1\n2\n[]\n")
    end
  end

  # `private :foo` in a subclass records a visibility for an inherited method; the class heads the chain with no
  # `def` of its own, and the call still reaches a private method.
  describe "a visibility change without a def" do
    let(:source) do
      <<~RUBY
        class B; def foo = 1; end
        class C < B; private :foo; end
        C.new.foo
      RUBY
    end

    it "raises NoMethodError under Ruby" do
      program = "#{source.lines[0..1].join}begin; C.new.foo; rescue NoMethodError => e; puts e.class; end\n"
      expect(RubyRun.stdout(program)).to eq("NoMethodError\n")
    end

    it "still reports the private call" do
      expect(rules(source)).to eq([[3, "def.method-visibility-mismatch"]])
    end
  end
end
