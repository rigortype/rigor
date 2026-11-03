# frozen_string_literal: true

require "spec_helper"
require "prism"

# #2708 — `Reflection.declarations_in`: the public facade over the engine's declaration walk, which `rigor-alba` and
# `rigor-typelizer` read instead of `Rigor::Inference::DeclarationWalk`.
RSpec.describe Rigor::Reflection, ".declarations_in" do
  def parse(source)
    Prism.parse(source).value
  end

  def declared(source)
    described_class.declarations_in(parse(source)).map { |declaration| [declaration.name, declaration.nesting] }
  end

  def calls(source)
    seen = []
    described_class.declarations_in(parse(source)) { |call, owner| seen << [call.name, owner] }
    seen
  end

  describe "the classes" do
    it "names a class by the lexical modules and classes around it" do
      source = "module Admin\n  class User\n    class Role; end\n  end\nend\n"

      expect(declared(source)).to eq([["Admin::User", ["Admin"]], ["Admin::User::Role", ["Admin::User", "Admin"]]])
    end

    it "reports `Module.nesting` where the header is written, without the class itself" do
      expect(declared("class Top; end")).to eq([["Top", []]])
    end

    it "qualifies a compact header under the enclosing name and nests it as one entry" do
      expect(declared("module A\n  class B::C; end\nend\n")).to eq([["A::B::C", ["A"]]])
    end

    it "reports a class reopened in the file once per header, in source order" do
      expect(declared("class A; end\nclass B; end\nclass A; end\n").map(&:first)).to eq(%w[A B A])
    end

    it "omits modules and singleton classes" do
      expect(declared("module M; end\nclass K\n  class << self; end\nend\n")).to eq([["K", []]])
    end

    it "omits a class no name reaches" do
      source = "class K\n  Class.new { def x; end }\n  class << self\n    class Hidden; end\n  end\nend\n"

      expect(declared(source).map(&:first)).to eq(["K"])
    end

    it "hands back the Prism::ClassNode, whose superclass and body the plugin reads" do
      declaration = described_class.declarations_in(parse("class A < B; include M; end")).first

      expect(declaration.node).to be_a(Prism::ClassNode)
      expect(declaration.node.superclass.name).to eq(:B)
    end

    it "reports no calls without a block" do
      expect { described_class.declarations_in(parse("foo\nclass A; bar; end\n")) }.not_to raise_error
    end
  end

  describe "the calls" do
    it "yields each call with the class or module it sits in, and nil outside any" do
      source = "top\nmodule M\n  class A\n    inside\n  end\nend\nCls = Class.new { anon }\n"

      expect(calls(source)).to eq([[:top, nil], [:inside, "M::A"], [:anon, nil]])
    end

    it "does not yield the `Class.new` call of a constant write, only the calls in its block" do
      expect(calls("class A
  Inner = Class.new(Base) { macro }
end
")).to eq([[:macro, "A"]])
    end

    it "yields an outer call before the calls inside its block" do
      expect(calls("class A\n  outer { inner }\nend\n")).to eq([[:outer, "A"], [:inner, "A"]])
    end

    it "reports the enclosing class for a call in a `class << self` body" do
      expect(calls("class A\n  class << self\n    macro\n  end\nend\n")).to eq([[:macro, "A"]])
    end

    it "reports the class around a `Class.new` block, since the owner is lexical" do
      expect(calls("class A\n  Class.new { macro }\nend\n")).to eq([[:new, "A"], [:macro, "A"]])
    end

    it "reports nil below a bare header inside `class << self`, which no name spells" do
      expect(calls("class A\n  class << self\n    class D\n      macro\n    end\n  end\nend\n")).to eq([[:macro, nil]])
    end

    it "keeps reporting the classes alongside the calls" do
      declarations = described_class.declarations_in(parse("class A; x; end")) { |_call, _owner| nil }

      expect(declarations.map(&:name)).to eq(["A"])
    end
  end
end
