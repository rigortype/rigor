# frozen_string_literal: true

require "spec_helper"
require "rigor/analysis/edit_replay"

# Issue #1967 — the edits `--verify-incremental-edits` replays on a sampled file.
RSpec.describe Rigor::Analysis::EditReplay do
  describe ".skeleton" do
    it "keeps nested class and module headers, superclasses included, and drops every body statement" do
      source = <<~RUBY
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

      expect(described_class.skeleton(source)).to eq(<<~RUBY)
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

    it "answers empty for a file that declares nothing or does not parse" do
      expect(described_class.skeleton("$stdout = 1\n")).to eq("")
      expect(described_class.skeleton("class A\n  def go = (\nend\n")).to eq("")
    end
  end

  describe ".edits" do
    it "replays the emptied file and its skeleton" do
      edits = described_class.edits("class A\n  def go = 1\nend\n")

      expect(edits.map(&:source)).to eq(["", "class A\nend\n"])
    end

    it "replays only the emptied file when the skeleton is the file itself or empty" do
      expect(described_class.edits("class A\nend\n").map(&:source)).to eq([""])
      expect(described_class.edits("$stdout = 1\n").map(&:source)).to eq([""])
    end
  end
end
