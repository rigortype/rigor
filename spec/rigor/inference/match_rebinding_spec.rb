# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1358 — Ruby keeps the regex match globals in the method frame's special-variable slot, and every block and
# closure made in the method reaches that same slot, while a `def`, class or module body has a slot of its own.
RSpec.describe Rigor::Inference::MatchRebinding do
  def last_statement(source) = Prism.parse(source).value.statements.body.last
  def root(source) = Prism.parse(source).value

  describe ".may_match?" do
    it "counts a match-capable call anywhere in the node, in a nested block or lambda too" do
      expect(described_class.may_match?(last_statement("items.each { |i| i =~ /(z)/ }"))).to be(true)
      expect(described_class.may_match?(last_statement("items.each { -> { s.sub(/a/, '') } }"))).to be(true)
    end

    it "counts a regex `when` condition, a regex in a pattern, and a bare regex condition" do
      expect(described_class.may_match?(last_statement("case i when /(z)/ then 1 end"))).to be(true)
      expect(described_class.may_match?(last_statement("case i; in [/(z)/] then 1; else 2; end"))).to be(true)
      expect(described_class.may_match?(last_statement("i in /(z)/"))).to be(true)
      expect(described_class.may_match?(last_statement("1 if /(z)/"))).to be(true)
    end

    it "does not count a `def`, class or module body, or a `defined?` operand" do
      expect(described_class.may_match?(last_statement("items.each { def m(x) = x =~ /(z)/ }"))).to be(false)
      expect(described_class.may_match?(last_statement("items.each { module M; X = 'a' =~ /(z)/; end }")))
        .to be(false)
      expect(described_class.may_match?(last_statement("defined?(x =~ /(z)/)"))).to be(false)
    end

    it "does not count a non-regex `when`, or a call whose name cannot match" do
      expect(described_class.may_match?(last_statement("case i when String, 'q' then 1 end"))).to be(false)
      expect(described_class.may_match?(last_statement("items.each { |i| puts i.upcase }"))).to be(false)
    end
  end

  describe ".block_may_match?" do
    it "answers for a block literal by its body" do
      expect(described_class.block_may_match?(last_statement("items.each { |i| i =~ /(z)/ }"))).to be(true)
      expect(described_class.block_may_match?(last_statement("items.each { |i| puts i }"))).to be(false)
    end

    it "counts a `&expr` block argument, which may be a proc made in this frame" do
      expect(described_class.block_may_match?(last_statement("items.each(&handler)"))).to be(true)
      expect(described_class.block_may_match?(last_statement("items.each(&method(:m))"))).to be(true)
    end

    it "does not count a Symbol block argument, an anonymous `&`, or a call without a block" do
      forwarding = last_statement("def m(&) = items.each(&)").body.body.first

      expect(described_class.block_may_match?(last_statement("items.each(&:freeze)"))).to be(false)
      expect(described_class.block_may_match?(forwarding)).to be(false)
      expect(described_class.block_may_match?(last_statement("items.first"))).to be(false)
    end
  end

  describe ".matching_closure?" do
    it "counts a lambda literal, or a block a call keeps to run later, whose body may match" do
      expect(described_class.matching_closure?(root("f = -> { s =~ /(z)/ }"))).to be(true)
      expect(described_class.matching_closure?(root("f = lambda { s =~ /(z)/ }"))).to be(true)
      expect(described_class.matching_closure?(root("f = Proc.new { s =~ /(z)/ }"))).to be(true)
      expect(described_class.matching_closure?(root("fs = items.map { |i| -> { i =~ /(z)/ } }"))).to be(true)
      expect(described_class.matching_closure?(root("register(-> { s =~ /(z)/ })"))).to be(true)
    end

    it "does not count a closure that cannot match, a block the call runs now, or a nested `def`'s closure" do
      expect(described_class.matching_closure?(root("f = -> { s.upcase }"))).to be(false)
      expect(described_class.matching_closure?(root("items.each { |i| i =~ /(z)/ }"))).to be(false)
      expect(described_class.matching_closure?(root("def m = -> { s =~ /(z)/ }"))).to be(false)
    end
  end

  describe ".block_entry" do
    let(:string) { Rigor::Type::Combinator.nominal_of("String") }
    let(:narrowed) { Rigor::Scope.empty.with_global(:$1, string) }

    def block(source) = last_statement(source).block

    it "forgets the match globals for a body that may match, which a later iteration enters after it ran" do
      entry = described_class.block_entry(narrowed, block("items.each { |i| r = $1; i =~ /(z)/ }"))

      expect(entry.global(:$1)).to be_nil
    end

    it "keeps them for a body that cannot match, since the block shares the frame" do
      expect(described_class.block_entry(narrowed, block("items.each { |i| $1 }"))).to equal(narrowed)
    end

    it "forgets them for any body in a frame that makes a closure that may match" do
      framed = narrowed.with_match_frame(root("f = proc { s =~ /(z)/ }"))

      expect(described_class.block_entry(framed, block("items.each { |i| $1 }")).global(:$1)).to be_nil
    end
  end
end
