# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/inference/scope_indexer"

# ADR-119 WD7 — `unpositioned_mixins` names the include / prepend / extend edges whose ORDER the mixin tables cannot
# vouch for, so a reader that depends on the order of a class's ancestors can decline where it is not known. The
# tables themselves are unchanged: every edge is still recorded, and this table only flags it. When in doubt an edge
# is unpositioned, which sends the class to the answer the reader gave before it had the table.
RSpec.describe Rigor::Inference::ScopeIndexer::MixinAccumulator do
  def index_of(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, source)
      described_index = Rigor::Inference::ScopeIndexer.discovered_project_index_for_paths([path])
      described_index.fetch(:def_index)
    end
  end

  def unpositioned(source)
    index_of(source).fetch(:unpositioned_mixins)
  end

  context "when the edge's position is not a fact" do
    it "flags an include inside a def" do
      source = <<~RUBY
        class C
          def setup = self.class.include(M)
          def other
            include N
          end
        end
      RUBY

      expect(unpositioned(source)).to eq("C" => ["N"])
    end

    it "flags a prepend inside a def" do
      source = <<~RUBY
        class C
          def setup
            prepend M
          end
        end
      RUBY

      expect(unpositioned(source)).to eq("C" => ["M"])
    end

    it "flags an edge under if, unless and a modifier", :aggregate_failures do
      { "if X\n    include M\n  end" => "M",
        "unless X\n    prepend M\n  end" => "M",
        "include M if X" => "M",
        "prepend M unless X" => "M" }.each do |body, name|
        expect(unpositioned("class C\n  #{body}\nend\n")).to eq("C" => [name]), body
      end
    end

    it "flags an edge inside `included do` and `class_eval`", :aggregate_failures do
      expect(unpositioned("module Concern\n  included do\n    include M\n  end\nend\n")).to eq("Concern" => ["M"])
      expect(unpositioned("class C\n  class_eval do\n    include M\n  end\nend\n")).to eq("C" => ["M"])
    end

    it "flags the receiver form, keyed by the receiver" do
      source = <<~RUBY
        class Base; end
        class C
          Base.prepend(M)
        end
      RUBY

      expect(unpositioned(source)).to eq("Base" => ["M"])
    end

    it "flags every named module of an argument list that shares it with an unnameable argument" do
      source = <<~RUBY
        class C
          include A, helper_call
        end
      RUBY

      expect(unpositioned(source)).to eq("C" => ["A"])
    end

    it "flags an extend inside a method" do
      source = <<~RUBY
        class C
          def self.boot
            extend M
          end
        end
      RUBY

      expect(unpositioned(source)).to eq("C" => ["M"])
    end

    it "still records the edge in the ordinary tables" do
      index = index_of("class C\n  include M if X\nend\n")

      expect(index.fetch(:includes)).to eq("C" => ["M"])
    end
  end

  context "when the edge is a direct statement of the body" do
    it "does not flag a direct include, prepend and extend" do
      source = <<~RUBY
        class C
          include A
          prepend B
          extend D
          include E, F
        end
        module Outer
          class Inner
            include G
          end
        end
      RUBY

      expect(unpositioned(source)).to eq({})
    end

    it "does not flag `extend self` or a bare module_function", :aggregate_failures do
      expect(unpositioned("module M\n  extend self\nend\n")).to eq({})
      expect(unpositioned("module M\n  module_function\n  def x = 1\nend\n")).to eq({})
    end

    it "does not flag `class << self; include M`" do
      expect(unpositioned("class C\n  class << self\n    include M\n  end\nend\n")).to eq({})
    end

    it "does not flag a direct edge of a compact-header class" do
      expect(unpositioned("class A::B\n  include M\nend\n")).to eq({})
    end
  end

  context "when one edge is written both ways" do
    it "keeps the edge unpositioned within a file" do
      source = <<~RUBY
        class C
          include M
          include M if X
        end
      RUBY

      expect(unpositioned(source)).to eq("C" => ["M"])
    end

    it "keeps the edge unpositioned across files, whichever file writes it directly" do
      Dir.mktmpdir do |dir|
        direct = File.join(dir, "a.rb")
        guarded = File.join(dir, "b.rb")
        File.write(direct, "class C\n  include M\nend\n")
        File.write(guarded, "class C\n  include M if X\n  include N\nend\n")

        [[direct, guarded], [guarded, direct]].each do |paths|
          table = Rigor::Inference::ScopeIndexer.discovered_project_index_for_paths(paths)
                                                .fetch(:def_index).fetch(:unpositioned_mixins)
          expect(table).to eq("C" => ["M"])
        end
      end
    end
  end

  context "with a compact class header re-anchored to the top level" do
    it "rekeys the flagged edge with the class it belongs to" do
      source = <<~RUBY
        class Outer; end
        class Outer::Leaf; end
        module Wrap
          class Outer::Leaf
            include M if X
          end
        end
      RUBY

      index = index_of(source)

      expect(index.fetch(:compact_header_renames)).to eq("Wrap::Outer::Leaf" => "Outer::Leaf")
      expect(index.fetch(:includes)).to eq("Outer::Leaf" => ["M"])
      expect(index.fetch(:unpositioned_mixins)).to eq("Outer::Leaf" => ["M"])
    end
  end
end
