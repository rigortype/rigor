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
end
