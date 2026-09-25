# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1358 — Ruby keeps the regex match globals in the method frame's special-variable slot, and every block and
# closure made in the method reaches that same slot, while a `def`, class or module body has a slot of its own.
RSpec.describe Rigor::Inference::MatchRebinding do
  let(:scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }

  def last_statement(source) = Prism.parse(source).value.statements.body.last
  def root(source) = Prism.parse(source).value
  def may_match?(source) = described_class.may_match?(last_statement(source), scope)

  describe ".may_match?" do
    it "counts a call that rebinds `$~` whatever its argument, in a nested block or lambda too" do
      expect(may_match?("items.each { |i| i =~ /(z)/ }")).to be(true)
      expect(may_match?("items.each { |i| i.sub('a', '') }")).to be(true)
      expect(may_match?("items.each { -> { s.scan('q') } }")).to be(true)
    end

    # `h[k]`, `s.split(":")` and `s.index(x)` are lookups far more often than matches, and counting them dropped the
    # narrowing on correct code.
    it "counts `[]`, `split`, `index` and their kin only with an argument known to be a Regexp" do
      expect(may_match?("fields.each { |f| out[f] = row[f] }")).to be(false)
      expect(may_match?("parts.each { |p| p.split(':') }")).to be(false)
      expect(may_match?("parts.each { |p| p[0, 2]; p.index(sep) }")).to be(false)
      expect(may_match?("parts.each { |p| p[/(z)/] }")).to be(true)
      expect(may_match?("parts.each { |p| p.split(Regexp.new(sep)) }")).to be(true)
    end

    it "does not count `match?`, which never sets `$~`" do
      expect(may_match?("items.each { |i| i.match?(/(z)/) }")).to be(false)
    end

    it "counts `===` on a receiver that may be a Regexp, not one that resolves to a class" do
      expect(may_match?("items.each { |i| re === i }")).to be(true)
      expect(may_match?("items.each { |i| String === i }")).to be(false)
    end

    it "counts a `when` condition that may be a Regexp, and not a literal or a class" do
      expect(may_match?("case i when /(z)/ then 1 end")).to be(true)
      expect(may_match?("case i when WORD_RE then 1 end")).to be(true)
      expect(may_match?("case i when re then 1 end")).to be(true)
      expect(may_match?("case i when *res then 1 end")).to be(true)
      expect(may_match?("case i when String, 'q', :s, 1..2, nil then 1 end")).to be(false)
    end

    it "counts an `in` / `=>` pattern holding a value that may be a Regexp, and not its structure or classes" do
      expect(may_match?("case i; in [/(z)/] then 1; else 2; end")).to be(true)
      expect(may_match?("i in WORD_RE")).to be(true)
      expect(may_match?("re = nil; i in ^re")).to be(true)
      expect(may_match?("i in [Integer, String] | { name: String } | nil")).to be(false)
      expect(may_match?("i => [x, *rest]")).to be(false)
    end

    it "counts a bare regex condition and a write to `$~`" do
      expect(may_match?("1 if /(z)/")).to be(true)
      expect(may_match?("items.each { |m| $~ = m }")).to be(true)
      expect(may_match?("items.each { |m| $x = m }")).to be(false)
    end

    it "does not count a `def`, class or module body, or a `defined?` operand" do
      expect(may_match?("items.each { def m(x) = x =~ /(z)/ }")).to be(false)
      expect(may_match?("items.each { module M; X = 'a' =~ /(z)/; end }")).to be(false)
      expect(may_match?("defined?(x =~ /(z)/)")).to be(false)
    end

    it "does not count a call whose name cannot match, such as an implicit-self one" do
      expect(may_match?("items.each { |i| puts i.upcase }")).to be(false)
    end
  end

  describe ".block_may_match?" do
    def block_may_match?(source, in_scope = scope) = described_class.block_may_match?(last_statement(source), in_scope)

    it "answers for a block literal by its body" do
      expect(block_may_match?("items.each { |i| i =~ /(z)/ }")).to be(true)
      expect(block_may_match?("items.each { |i| puts i }")).to be(false)
    end

    it "counts a `&expr` block argument, which may be a proc made in this frame" do
      expect(block_may_match?("items.each(&handler)")).to be(true)
      expect(block_may_match?("items.each(&method(:m))")).to be(true)
    end

    it "counts a Symbol block argument only for a method that rebinds `$~`" do
      expect(block_may_match?("items.each(&:freeze)")).to be(false)
      expect(block_may_match?("items.inject(&:=~)")).to be(true)
      expect(block_may_match?("items.inject(&:[])")).to be(false)
    end

    it "does not count an anonymous `&`, or a call without a block" do
      forwarding = last_statement("def m(&) = items.each(&)").body.body.first

      expect(described_class.block_may_match?(forwarding, scope)).to be(false)
      expect(block_may_match?("items.first")).to be(false)
    end

    context "with the method's own `&block` parameter" do
      def forwarded_may_match?(source)
        def_node = last_statement(source)
        framed = scope.with_match_frame(def_node.body, def_node.parameters)
        call = def_node.body.breadth_first_search do |node|
          node.is_a?(Prism::CallNode) && node.name == :each && node.block.is_a?(Prism::BlockArgumentNode)
        end
        described_class.block_may_match?(call, framed)
      end

      it "does not count it, since it forwards the block the caller made" do
        expect(forwarded_may_match?("def m(env, &blk); env.each(&blk); end")).to be(false)
      end

      it "counts it once the body rebinds or shadows the name" do
        expect(forwarded_may_match?("def m(env, &blk); blk = proc { |x| x =~ /(q)/ }; env.each(&blk); end")).to be(true)
        expect(forwarded_may_match?("def m(procs, env, &blk); procs.each { |blk| env.each(&blk) }; end")).to be(true)
      end
    end
  end

  describe ".call_may_match?" do
    def call_may_match?(source) = described_class.call_may_match?(last_statement(source), scope)

    it "counts a block that runs in the receiver chain or an argument" do
      expect(call_may_match?("items.select { |i| i =~ /(z)/ }.map(&:upcase)")).to be(true)
      expect(call_may_match?("log(items.map { |i| i =~ /(z)/ })")).to be(true)
      expect(call_may_match?("log(items.map(&handler))")).to be(true)
    end

    it "does not count a lambda there, which does not run yet, or a call without a block" do
      expect(call_may_match?("register(-> { s =~ /(z)/ })")).to be(false)
      expect(call_may_match?("log(s.sub(/(z)/, ''))")).to be(false)
      expect(call_may_match?("items.select { |i| i.empty? }.map(&:upcase)")).to be(false)
    end
  end

  describe ".matching_closure?" do
    def matching_closure?(source) = described_class.matching_closure?(root(source), scope)

    it "counts a lambda literal, or a block a call keeps to run later, whose body may match" do
      expect(matching_closure?("f = -> { s =~ /(z)/ }")).to be(true)
      expect(matching_closure?("f = lambda { s =~ /(z)/ }")).to be(true)
      expect(matching_closure?("f = Proc.new { s =~ /(z)/ }")).to be(true)
      expect(matching_closure?("fs = items.map { |i| -> { i =~ /(z)/ } }")).to be(true)
      expect(matching_closure?("register(-> { s =~ /(z)/ })")).to be(true)
    end

    it "does not count a closure that cannot match, a block the call runs now, or a nested `def`'s closure" do
      expect(matching_closure?("f = -> { s.upcase }")).to be(false)
      expect(matching_closure?("lookup = ->(k) { h[k] }")).to be(false)
      expect(matching_closure?("items.each { |i| i =~ /(z)/ }")).to be(false)
      expect(matching_closure?("def m = -> { s =~ /(z)/ }")).to be(false)
    end

    it "counts a closure in a method's parameter defaults, which run in the method's frame" do
      def_node = last_statement('def m(s, f = -> { "zz" =~ /(q)/ }) = f.call')

      expect(Rigor::Inference::MatchRebinding::Frame.new(def_node.body, def_node.parameters).matching_closure?(scope))
        .to be(true)
      expect(Rigor::Inference::MatchRebinding::Frame.new(def_node.body).matching_closure?(scope)).to be(false)
    end
  end

  describe ".block_entry" do
    let(:string) { Rigor::Type::Combinator.nominal_of("String") }
    let(:narrowed) { scope.with_global(:$1, string) }

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
