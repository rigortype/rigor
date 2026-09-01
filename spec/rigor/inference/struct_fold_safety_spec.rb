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

  describe "straight-line member setters (slice 4)" do
    it "accepts a local mutated only through a straight-line member setter" do
      expect(safe("p = Point.new(1, 2)\np.x = 5\np.x")).to eq(Set[:p])
    end

    it "accepts several straight-line member setters" do
      expect(safe("p = Point.new(1, 2)\np.x = 5\np.y = 6\np.x")).to eq(Set[:p])
    end

    it "still rejects a member setter inside a loop" do
      expect(safe("p = Point.new(1, 2)\nwhile c\n  p.x = p.x + 1\nend\np.x")).to eq(Set[])
    end

    it "still rejects a member setter inside a block" do
      expect(safe("p = Point.new(1, 2)\n[1].each { p.x = 5 }\np.x")).to eq(Set[])
    end

    it "still rejects an index write alongside a setter" do
      expect(safe("p = Point.new(1, 2)\np.x = 5\np[0] = 9\np.x")).to eq(Set[])
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

  # Issue #525 — the in-body half. Whether a method body may be told "the caller's member map is still your
  # struct's state", which is what licenses folding a receiverless member read inside it.
  describe ".self_fold_safe_body?" do
    def body_of(source)
      Prism.parse(source).value.statements.body.first.body
    end

    def clears?(source, members = %i[text indent])
      described_class.self_fold_safe_body?(body_of(source), members)
    end

    describe "clears — every use of self is a pure read" do
      it "clears an implicit-self member read" do
        expect(clears?("def shout\n  text.upcase\nend")).to be(true)
      end

      it "clears an explicit `self.member` read" do
        expect(clears?("def shout\n  self.text.upcase\nend")).to be(true)
      end

      it "clears a fixed Struct read and `self.class`" do
        expect(clears?("def pair\n  [to_h, self.class]\nend")).to be(true)
      end

      it "clears a member read inside a block (blocks share self)" do
        expect(clears?("def shout\n  [1].map { text }\nend")).to be(true)
      end

      it "clears when a nested def would be unsafe (it does not run in this body)" do
        # The nested def's `self.text =` executes only when THAT method is called, not during this body.
        expect(clears?("def shout\n  def reset!\n    self.text = \"\"\n  end\n  text\nend")).to be(true)
      end
    end

    describe "refuses — the map may not survive to the read" do
      it "refuses a member setter on self" do
        expect(clears?("def go\n  self.text = \"z\"\n  text\nend")).to be(false)
      end

      it "refuses an index write on self" do
        expect(clears?("def go\n  self[:text] = \"z\"\n  text\nend")).to be(false)
      end

      it "refuses a call to a sibling method, which could mutate a member" do
        # The body has no setter of its OWN — this is the shape a setter-only guard would wrongly clear.
        expect(clears?("def go\n  reset!\n  text\nend")).to be(false)
      end

      it "refuses when self escapes as an argument" do
        expect(clears?("def go(sink)\n  sink.take(self)\n  text\nend")).to be(false)
      end

      it "refuses when self escapes as the returned value" do
        expect(clears?("def go\n  self\nend")).to be(false)
      end

      it "refuses a setter reached through a block" do
        expect(clears?("def go\n  [1].each { self.text = \"z\" }\n  text\nend")).to be(false)
      end

      it "refuses a name that is not a member of THIS carrier" do
        # `text` is a member reader for the default carrier but not for this one, so the same body flips.
        expect(clears?("def go\n  text\nend", %i[from to])).to be(false)
      end

      it "refuses a bare `super`" do
        # An ancestor body runs against this same `self`, and the sibling resolver walks own-class defs
        # only, so nothing can vouch for it.
        expect(clears?("def shout\n  super\n  text\nend")).to be(false)
      end

      it "refuses `super(...)` with arguments" do
        expect(clears?("def shout(v)\n  super(v)\n  text\nend")).to be(false)
      end

      it "refuses a nil body" do
        expect(described_class.self_fold_safe_body?(nil, %i[text])).to be(false)
      end
    end
  end
end
