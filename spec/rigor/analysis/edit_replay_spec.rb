# frozen_string_literal: true

require "spec_helper"
require "rigor/analysis/edit_replay"

# Issue #1967 — the edits `--verify-incremental-edits` replays on a sampled file.
RSpec.describe Rigor::Analysis::EditReplay do
  describe ".skeleton" do
    let(:nested_source) do
      <<~RUBY
        require "set"

        module Outer
          VERSION = 1

          class Base < Struct.new(:a)
            include Comparable
            def go = 1
          end

          module Inner
            class Leaf < Outer::Base
              private :go
            end
          end
        end

        class Top
          refine(String) { def x = 1 }
        end
      RUBY
    end

    let(:nested_skeleton) do
      <<~RUBY
        module Outer
          class Base < Struct.new(:a)
          end
          module Inner
            class Leaf < Outer::Base
            end
          end
        end
        class Top
        end
      RUBY
    end

    it "keeps nested class and module headers, superclasses included, and drops every body statement" do
      expect(described_class.skeleton(nested_source)).to eq(nested_skeleton)
    end

    it "answers empty for a file that declares nothing or does not parse" do
      expect(described_class.skeleton("$stdout = 1\n")).to eq("")
      expect(described_class.skeleton("class A\n  def go = (\nend\n")).to eq("")
    end
  end

  describe ".edits" do
    it "replays the emptied file and its skeleton" do
      edits = described_class.edits("class A\n  def go = 1\nend\n")

      # Dropping `go` is the skeleton again, so it is not replayed twice.
      expect(edits.map(&:source)).to eq(["", "class A\nend\n"])
    end

    it "replays dropping one statement of a body, visibility calls first and at most MAX_DROPS" do
      source = "module Es\n  def a = 1\n  def b = 2\n  private :a\n  module_function :b\n  public :a\nend\n"
      drops = described_class.edits(source).select { |edit| edit.label.start_with?("dropping") }

      expect(drops.size).to eq(described_class::MAX_DROPS)
      expect(drops.map(&:source)).to eq(
        ["module Es\n  def a = 1\n  def b = 2\n  module_function :b\n  public :a\nend\n",
         "module Es\n  def a = 1\n  def b = 2\n  private :a\n  public :a\nend\n"]
      )
      expect(drops.map(&:label)).to eq(["dropping the statement at line 4 of", "dropping the statement at line 5 of"])
    end

    it "fills the drops with other statements, spread over the body, when there are few visibility calls" do
      source = "class A\n  def a = 1\n  def b = 2\n  def c = 3\n  def d = 4\nend\n"
      drops = described_class.edits(source).select { |edit| edit.label.start_with?("dropping") }

      expect(drops.map { |edit| edit.label[/line (\d+)/, 1] }).to eq(%w[3 5])
    end

    it "drops a statement of a nested declaration, and nothing outside a class or module body" do
      source = "require 'x'\nmodule O\n  class I\n    private :a\n  end\nend\n"
      drops = described_class.edits(source).select { |edit| edit.label.start_with?("dropping") }

      expect(drops.map(&:source)).to include("require 'x'\nmodule O\n  class I\n  end\nend\n")
      expect(drops.map(&:source)).to all(include("require 'x'"))
    end

    it "replays only the emptied file when the skeleton is the file itself or empty" do
      expect(described_class.edits("class A\nend\n").map(&:source)).to eq([""])
      expect(described_class.edits("$stdout = 1\n").map(&:source)).to eq([""])
    end
  end
end
