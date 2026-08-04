# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::RegexpFolding do
  def regexp_singleton = Rigor::Type::Combinator.singleton_of("Regexp")
  def c(value)         = Rigor::Type::Combinator.constant_of(value)

  def fold(method_name, *arg_types)
    described_class.try_dispatch(cc(
                                   receiver: regexp_singleton,
                                   method_name: method_name,
                                   args: arg_types
                                 ))
  end

  describe "escape / quote" do
    it "escapes a period to a backslash-period" do
      expect(fold(:escape, c("hello.world"))).to eq(c("hello\\.world"))
    end

    it "escapes brackets and other meta-characters" do
      expect(fold(:escape, c("[a-z]*"))).to eq(c("\\[a\\-z\\]\\*"))
    end

    it "returns the string unchanged when no meta-characters are present" do
      expect(fold(:escape, c("hello"))).to eq(c("hello"))
    end

    it "treats quote as an alias for escape" do
      expect(fold(:quote, c("hello.world"))).to eq(fold(:escape, c("hello.world")))
    end

    it "declines for a non-Constant argument" do
      expect(fold(:escape, Rigor::Type::Combinator.nominal_of("String"))).to be_nil
    end

    it "declines for a non-String constant" do
      expect(fold(:escape, c(42))).to be_nil
    end

    it "declines when more than one argument is given" do
      expect(fold(:escape, c("a"), c("b"))).to be_nil
    end

    it "declines for a non-Singleton receiver" do
      result = described_class.try_dispatch(cc(
                                              receiver: c("Regexp"),
                                              method_name: :escape,
                                              args: [c("hello")]
                                            ))
      expect(result).to be_nil
    end

    it "declines for a wrong singleton class" do
      result = described_class.try_dispatch(cc(
                                              receiver: Rigor::Type::Combinator.singleton_of("String"),
                                              method_name: :escape,
                                              args: [c("hello")]
                                            ))
      expect(result).to be_nil
    end

    it "declines for an unsupported method" do
      expect(fold(:try_convert, c("hello"))).to be_nil
    end
  end

  describe "new" do
    it "folds a simple pattern with no options" do
      result = fold(:new, c("hello"))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(/hello/)
    end

    it "folds a pattern with integer flags" do
      result = fold(:new, c("hello"), c(Regexp::IGNORECASE))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(/hello/i)
    end

    it "folds a pattern with true (IGNORECASE shorthand)" do
      result = fold(:new, c("hello"), c(true))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value.options).to eq(Regexp.new("hello", true).options)
    end

    it "folds a pattern with false (no flags)" do
      result = fold(:new, c("hello"), c(false))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(/hello/)
    end

    it "declines when given no arguments" do
      expect(fold(:new)).to be_nil
    end

    it "declines when the pattern is not a Constant" do
      expect(fold(:new, Rigor::Type::Combinator.nominal_of("String"))).to be_nil
    end

    it "declines when the pattern is a non-String Constant" do
      expect(fold(:new, c(42))).to be_nil
    end

    it "declines when more than two arguments are given" do
      expect(fold(:new, c("hello"), c(0), c("n"))).to be_nil
    end

    it "declines when the second argument is not a Constant" do
      expect(fold(:new, c("hello"), Rigor::Type::Combinator.nominal_of("Integer"))).to be_nil
    end

    it "returns nil gracefully for an invalid pattern rather than raising" do
      # Regexp.new with an unbalanced group should decline (rescue → nil)
      expect(fold(:new, c("(unclosed"))).to be_nil
    end
  end

  describe "compile (Regexp.new alias)" do
    it "folds a simple pattern with no options" do
      result = fold(:compile, c("hello"))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(/hello/)
    end

    it "folds a pattern with integer flags" do
      result = fold(:compile, c("hello"), c(Regexp::IGNORECASE))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(/hello/i)
    end

    it "behaves identically to new for the same arguments" do
      expect(fold(:compile, c("hello"), c(true))).to eq(fold(:new, c("hello"), c(true)))
    end

    it "declines when the pattern is not a Constant" do
      expect(fold(:compile, Rigor::Type::Combinator.nominal_of("String"))).to be_nil
    end

    it "declines when the pattern is a non-String Constant" do
      expect(fold(:compile, c(42))).to be_nil
    end

    it "returns nil gracefully for an invalid pattern rather than raising" do
      expect(fold(:compile, c("(unclosed"))).to be_nil
    end

    it "declines for a non-Singleton receiver" do
      result = described_class.try_dispatch(cc(
                                              receiver: c("Regexp"),
                                              method_name: :compile,
                                              args: [c("hello")]
                                            ))
      expect(result).to be_nil
    end
  end

  describe "last_match (proven-match-edge narrowing)" do
    def match_data_t = Rigor::Type::Combinator.nominal_of("MatchData")
    def string_t     = Rigor::Type::Combinator.nominal_of("String")
    def nil_t        = Rigor::Type::Combinator.constant_of(nil)

    # A scope on the truthy match edge: `$~` narrowed to MatchData and the numbered globals narrowed as
    # `Narrowing#regex_match_predicate_scopes` leaves them. `$1` present (String) means capture group 1 is
    # unconditional.
    def proven_scope(extra = {})
      defaults = { :$~ => match_data_t, :$1 => string_t }
      defaults.merge(extra).reduce(Rigor::Scope.empty) do |s, (name, type)|
        type.nil? ? s : s.with_global(name, type)
      end
    end

    def fold_in(scope, method_name, *arg_types)
      described_class.try_dispatch(cc(
                                     receiver: regexp_singleton,
                                     method_name: method_name,
                                     args: arg_types,
                                     scope: scope
                                   ))
    end

    it "narrows the zero-arg form to MatchData on a proven-match edge" do
      expect(fold_in(proven_scope, :last_match)).to eq(match_data_t)
    end

    it "narrows last_match(N) to String when group N is unconditional ($N present)" do
      expect(fold_in(proven_scope, :last_match, c(1))).to eq(string_t)
    end

    it "surfaces String? for last_match(N) when group N is optional ($N absent)" do
      scope = proven_scope(:$1 => nil) # only $~ narrowed, $1 not present
      expect(fold_in(scope, :last_match, c(2))).to eq(Rigor::Type::Combinator.union(string_t, nil_t))
    end

    it "declines (defers to RBS) when no match edge narrowed $~" do
      expect(fold_in(Rigor::Scope.empty, :last_match)).to be_nil
    end

    it "declines when $~ is bound to nil (falsey match edge)" do
      scope = Rigor::Scope.empty.with_global(:$~, nil_t)
      expect(fold_in(scope, :last_match)).to be_nil
    end

    it "declines when the index argument is non-constant" do
      expect(fold_in(proven_scope, :last_match, string_t)).to be_nil
    end

    it "declines a named-capture symbol or zero index, deferring to RBS" do
      expect(fold_in(proven_scope, :last_match, c(:k))).to be_nil
      expect(fold_in(proven_scope, :last_match, c(0))).to be_nil
    end

    it "declines when no scope is threaded through the context" do
      expect(fold(:last_match)).to be_nil
    end
  end

  describe "union" do
    def tuple_of(*elements) = Rigor::Type::Combinator.tuple_of(*elements)

    it "folds the splatted-strings form" do
      result = fold(:union, c("a"), c("b"))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Regexp.union("a", "b"))
    end

    it "folds a single-array-argument form identically to the splatted form" do
      expect(fold(:union, tuple_of(c("a"), c("b")))).to eq(fold(:union, c("a"), c("b")))
    end

    it "folds zero arguments to Ruby's never-match regexp" do
      result = fold(:union)
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Regexp.union)
    end

    it "folds a single already-Regexp argument unchanged" do
      result = fold(:union, c(/a/))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Regexp.union(/a/))
    end

    it "folds a mix of String and Regexp elements" do
      result = fold(:union, c("a"), c(/b/))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Regexp.union("a", /b/))
    end

    it "declines when a splatted element is not a Constant" do
      expect(fold(:union, c("a"), Rigor::Type::Combinator.nominal_of("String"))).to be_nil
    end

    it "declines when a splatted element is a non-String, non-Regexp Constant" do
      expect(fold(:union, c("a"), c(42))).to be_nil
    end

    it "declines when the sole array argument holds a non-constant element" do
      expect(fold(:union, tuple_of(c("a"), Rigor::Type::Combinator.nominal_of("String")))).to be_nil
    end

    it "declines when the sole argument is a Dynamic array, not a Tuple" do
      expect(fold(:union, Rigor::Type::Combinator.nominal_of("Array"))).to be_nil
    end

    it "declines when the element count exceeds the union cap" do
      elements = Array.new(65) { |i| c(i.to_s) }
      expect(fold(:union, *elements)).to be_nil
    end
  end

  describe "linear_time?" do
    it "folds a String pattern argument" do
      result = fold(:linear_time?, c("a.*b"))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Regexp.linear_time?("a.*b"))
    end

    it "folds a Regexp pattern argument" do
      result = fold(:linear_time?, c(/a.*b/))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Regexp.linear_time?(/a.*b/))
    end

    it "declines for a non-Constant argument" do
      expect(fold(:linear_time?, Rigor::Type::Combinator.nominal_of("String"))).to be_nil
    end

    it "declines for a non-String, non-Regexp Constant" do
      expect(fold(:linear_time?, c(42))).to be_nil
    end

    it "declines when given zero arguments" do
      expect(fold(:linear_time?)).to be_nil
    end

    it "declines when given a second argument (e.g. the timeout: keyword slot)" do
      expect(fold(:linear_time?, c("a.*b"), c(1))).to be_nil
    end

    it "returns nil gracefully for an invalid pattern rather than raising" do
      expect(fold(:linear_time?, c("(unclosed"))).to be_nil
    end
  end
end
