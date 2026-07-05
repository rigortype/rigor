# frozen_string_literal: true

require "spec_helper"
require "rigor/inference/struct_fold_safety"

RSpec.describe Rigor::Inference::StructFoldSafety do
  # Resolves `Point` / `Line` to a member list for the constant-receiver form; everything else is unknown (nil).
  let(:layout_lookup) do
    ->(name) { { "Point" => %i[x y], "Line" => %i[from to] }[name] }
  end

  def safe(source)
    root = Prism.parse(source).value
    described_class.fold_safe_locals(root, layout_lookup)
  end

  describe "fold-safe locals" do
    it "marks a struct local whose every use is a member read" do
      expect(safe(<<~RUBY)).to eq(Set[:p])
        p = Struct.new(:x, :y).new(1, 2)
        p.x
        p.y
      RUBY
    end

    it "marks a constant-receiver struct local resolved through the layout" do
      expect(safe(<<~RUBY)).to eq(Set[:p])
        p = Point.new(1, 2)
        p.x
      RUBY
    end

    it "marks reads through the fixed Struct read methods" do
      expect(safe(<<~RUBY)).to eq(Set[:p])
        p = Point.new(1, 2)
        p.to_h
        p.deconstruct
        p[0]
        p == other
      RUBY
    end
  end

  describe "mutation / escape / aliasing (must NOT be fold-safe)" do
    it "rejects a member setter" do
      expect(safe("p = Point.new(1, 2)\np.x = 5\np.x")).to eq(Set[])
    end

    it "rejects an index write" do
      expect(safe("p = Point.new(1, 2)\np[0] = 5\np.x")).to eq(Set[])
    end

    it "rejects an operator-write on a member" do
      expect(safe("p = Point.new(1, 2)\np.x += 1\np.x")).to eq(Set[])
    end

    it "rejects an alias (the struct escapes through another binding)" do
      expect(safe("p = Point.new(1, 2)\nq = p\nq.x = 5\np.x")).to eq(Set[])
    end

    it "rejects passing the struct as a call argument (escape)" do
      expect(safe("p = Point.new(1, 2)\nmutate!(p)\np.x")).to eq(Set[])
    end

    it "rejects storing the struct in a container (escape)" do
      expect(safe("p = Point.new(1, 2)\narr << p\np.x")).to eq(Set[])
    end

    it "rejects an unknown method call (could mutate self internally)" do
      expect(safe("p = Point.new(1, 2)\np.normalize!\np.x")).to eq(Set[])
    end

    it "rejects a block-taking call that is not a pure read" do
      expect(safe("p = Point.new(1, 2)\np.tap { |s| s }\np.x")).to eq(Set[])
    end

    it "rejects a mutation inside a shared block" do
      expect(safe("p = Point.new(1, 2)\n[1].each { p.x = 5 }\np.x")).to eq(Set[])
    end

    it "rejects a bare reference (return / escape)" do
      expect(safe("p = Point.new(1, 2)\np")).to eq(Set[])
    end

    it "rejects a reassigned local" do
      expect(safe("p = Point.new(1, 2)\np.x\np = other\np.x")).to eq(Set[])
    end

    it "does not mark an unknown (non-struct) local" do
      expect(safe("p = make_something\np.x")).to eq(Set[])
    end
  end

  describe "local-variable scope boundaries" do
    it "folds a member read inside a shared block" do
      expect(safe("p = Point.new(1, 2)\n[1].each { p.x }")).to eq(Set[:p])
    end

    it "does not let a nested def's same-named local affect the outer scope" do
      # The outer `p` is fold-safe; the inner `p` (a different binding) is not scanned, so its unsafe use must not
      # disqualify the outer one.
      expect(safe(<<~RUBY)).to eq(Set[:p])
        p = Point.new(1, 2)
        p.x
        def helper
          p = Point.new(3, 4)
          mutate!(p)
        end
      RUBY
    end
  end
end
