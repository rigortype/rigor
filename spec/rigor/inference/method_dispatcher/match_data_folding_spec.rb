# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::MatchDataFolding do
  def c(value)         = Rigor::Type::Combinator.constant_of(value)
  def match_data_t     = Rigor::Type::Combinator.nominal_of("MatchData")
  def string_t         = Rigor::Type::Combinator.nominal_of("String")
  def optional_string  = Rigor::Type::Combinator.union(string_t, c(nil))
  def tuple(*elements) = Rigor::Type::Combinator.tuple_of(*elements)

  # The truthy edge of `line =~ /(a)(b)?(c)/`: `$~` narrowed to MatchData, and `$1` / `$3` to String because their
  # groups are unconditional. `$2` stays unbound, as `Narrowing#regex_match_predicate_scopes` leaves an optional group.
  def proven_scope(globals = { :$1 => string_t, :$3 => string_t })
    { :$~ => match_data_t }.merge(globals).reduce(Rigor::Scope.empty) do |scope, (name, type)|
      scope.with_global(name, type)
    end
  end

  # The call node the dispatcher threads through; only its receiver expression is consulted.
  def call_node(source)
    Prism.parse(source).value.statements.body.first
  end

  def fold(source, method_name, *args, scope: proven_scope, receiver: match_data_t)
    described_class.try_dispatch(cc(
                                   receiver: receiver,
                                   method_name: method_name,
                                   args: args,
                                   call_node: call_node(source),
                                   scope: scope
                                 ))
  end

  describe "on a proven match" do
    it "folds an inclusive range to one slot per group" do
      expect(fold("$~[1..3]", :[], c(1..3))).to eq(tuple(string_t, optional_string, string_t))
    end

    it "folds an exclusive range" do
      expect(fold("$~[1...3]", :[], c(1...3))).to eq(tuple(string_t, optional_string))
    end

    it "reads index 0, the whole match, as String" do
      expect(fold("$~[0..1]", :[], c(0..1))).to eq(tuple(string_t, string_t))
    end

    it "folds the (start, length) form" do
      expect(fold("$~[1, 2]", :[], c(1), c(2))).to eq(tuple(string_t, optional_string))
    end

    it "folds values_at with constant Integer arguments" do
      expect(fold("$~.values_at(1, 3)", :values_at, c(1), c(3))).to eq(tuple(string_t, string_t))
    end

    it "folds a slice of a no-argument Regexp.last_match" do
      expect(fold("Regexp.last_match[1..2]", :[], c(1..2))).to eq(tuple(string_t, optional_string))
      expect(fold("::Regexp.last_match[2, 2]", :[], c(2), c(2))).to eq(tuple(optional_string, string_t))
    end
  end

  describe "declines to RBS" do
    it "for an endless or beginless range" do
      expect(fold("$~[1..]", :[], c(1..))).to be_nil
      expect(fold("$~[..3]", :[], c(..3))).to be_nil
    end

    it "for a negative index or length" do
      expect(fold("$~[-1..2]", :[], c(-1..2))).to be_nil
      expect(fold("$~[1..-1]", :[], c(1..-1))).to be_nil
      expect(fold("$~[-2, 1]", :[], c(-2), c(1))).to be_nil
      expect(fold("$~[1, -1]", :[], c(1), c(-1))).to be_nil
      expect(fold("$~.values_at(-1)", :values_at, c(-1))).to be_nil
    end

    it "for an index above the highest bound group" do
      expect(fold("$~[1..4]", :[], c(1..4))).to be_nil
      expect(fold("$~[3, 2]", :[], c(3), c(2))).to be_nil
      expect(fold("$~.values_at(1, 4)", :values_at, c(1), c(4))).to be_nil
    end

    it "when no numbered group is bound (named captures, `when /a/, /b/`)" do
      expect(fold("$~[0..0]", :[], c(0..0), scope: proven_scope({}))).to be_nil
    end

    it "ignores a `$10` binding, which forgetting the match globals does not clear (#1384)" do
      scope = proven_scope({ :$10 => string_t })
      expect(fold("$~[0..0]", :[], c(0..0), scope: scope)).to be_nil
    end

    it "for a non-constant index" do
      range_t = Rigor::Type::Combinator.nominal_of("Range", type_args: [Rigor::Type::Combinator.nominal_of("Integer")])
      expect(fold("$~[r]", :[], range_t)).to be_nil
      expect(fold("$~.values_at(i)", :values_at, Rigor::Type::Combinator.nominal_of("Integer"))).to be_nil
    end

    it "for an empty slice, a single Integer index, and values_at with no arguments" do
      expect(fold("$~[2...2]", :[], c(2...2))).to be_nil
      expect(fold("$~[1, 0]", :[], c(1), c(0))).to be_nil
      expect(fold("$~[1]", :[], c(1))).to be_nil
      expect(fold("$~.values_at", :values_at)).to be_nil
    end

    it "for another MatchData method" do
      expect(fold("$~.captures", :captures)).to be_nil
    end

    it "when the receiver is not the frame's current match" do
      expect(fold("md[1..2]", :[], c(1..2))).to be_nil
      expect(fold("Regexp.last_match(0)[1..2]", :[], c(1..2))).to be_nil
      expect(fold("Foo::Regexp.last_match[1..2]", :[], c(1..2))).to be_nil
      expect(fold("other.last_match[1..2]", :[], c(1..2))).to be_nil
    end

    it "when the receiver type is not MatchData" do
      expect(fold("$~[1..2]", :[], c(1..2), receiver: string_t)).to be_nil
    end

    it "without a proven match" do
      expect(fold("$~[1..2]", :[], c(1..2), scope: Rigor::Scope.empty)).to be_nil
      nil_scope = Rigor::Scope.empty.with_global(:$~, c(nil))
      expect(fold("$~[1..2]", :[], c(1..2), scope: nil_scope)).to be_nil
    end

    it "when no scope or call node is threaded through" do
      expect(described_class.try_dispatch(cc(receiver: match_data_t, method_name: :[], args: [c(1..2)]))).to be_nil
    end
  end
end
