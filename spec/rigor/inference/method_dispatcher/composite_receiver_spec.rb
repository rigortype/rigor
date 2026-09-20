# frozen_string_literal: true

require "spec_helper"

# Issue #1101 — the composite-receiver projection tier at the bottom of `MethodDispatcher#resolve`.
#
# Every tier above it needs a receiver it can NAME, so a `Union` or a `Difference` whose members would
# each resolve still fell through the whole chain and landed `Dynamic[top]`. The corpus shape is
# `params[:k]` on a Rails app: rigor-actionpack types it `ActionController::Parameters | nil`, and the
# `Parameters` arm resolves only through the user-class fallback — a tier BELOW `RbsDispatch`, where the
# only union distribution lived. `spec/integration/plugins/actionpack_plugin_spec.rb` carries the
# end-to-end half of this (`params[:k].present?` and friends through the real plugin); this file pins the
# dispatcher rule itself, including the shapes the rule declines.
RSpec.describe "MethodDispatcher composite-receiver projection" do
  def comb = Rigor::Type::Combinator

  def dispatch(receiver, method_name, args: [])
    Rigor::Inference::MethodDispatcher.dispatch(
      receiver_type: receiver, method_name: method_name, arg_types: args,
      environment: Rigor::Environment.default
    )
  end

  def bool = comb.union(comb.constant_of(true), comb.constant_of(false))
  # A class no RBS knows — the stand-in for `ActionController::Parameters`, which the actionpack plugin
  # mints as a nominal and which ships no signature. It resolves only through the user-class fallback.
  def rbs_less = comb.nominal_of("ProjectOnlyWidget")
  def other_rbs_less = comb.nominal_of("ProjectOnlyGadget")
  def nil_constant = comb.constant_of(nil)

  describe "the positive control this file's declines are read against" do
    it "resolves an RBS-less nominal through the user-class ancestor fallback" do
      expect(dispatch(rbs_less, :to_s)).to eq(comb.nominal_of("String"))
      expect(dispatch(rbs_less, :==, args: [comb.nominal_of("Object")])).to eq(bool)
    end
  end

  describe "Union receivers" do
    it "dispatches each member and unions the answers when one member needs a tier below RBS" do
      receiver = comb.union(rbs_less, nil_constant)

      # `NilClass#to_s` folds to `Constant[""]`; `ProjectOnlyWidget#to_s` reaches `Object#to_s`.
      expect(dispatch(receiver, :to_s)).to eq(comb.union(comb.constant_of(""), comb.nominal_of("String")))
      expect(dispatch(receiver, :nil?)).to eq(bool)
      expect(dispatch(receiver, :==, args: [comb.nominal_of("Object")])).to eq(bool)
    end

    it "binds `self` to the projected member, so a `-> self` method reassembles the union" do
      # Both members are RBS-less on purpose: with `String | Symbol` the RBS tier's own union arm
      # answers first and the example would pass without this tier existing at all. `Kernel#dup` is
      # `-> self`, and the user-class fallback substitutes each member as its own `self`.
      receiver = comb.union(rbs_less, other_rbs_less)

      expect(dispatch(receiver, :dup)).to eq(receiver)
    end

    it "declines as a whole when ANY member declines — never a partial answer" do
      # The RBS-less member reaches only the user-class fallback, which resolves `#to_s` through
      # `Object` and has no `#upcase` to offer. A union that answered `String` for `#upcase` would be
      # claiming the method exists on a receiver half of whose inhabitants raise NoMethodError.
      # (`String | Integer` would make the same point but never reach this tier — the RBS tier's own
      # union arm declines it first, so the example would pass with this tier deleted.)
      receiver = comb.union(rbs_less, comb.nominal_of("String"))

      expect(dispatch(receiver, :upcase)).to be_nil
      # Positive neighbour on the same receiver: a selector BOTH members carry resolves, and only this
      # tier can answer it — the RBS tier declines the union because the RBS-less arm has no signature.
      expect(dispatch(receiver, :to_s)).to eq(comb.nominal_of("String"))
    end
  end

  describe "Difference receivers" do
    it "resolves `A - nil` on `A`: removing nil cannot change method resolution" do
      expect(dispatch(comb.difference(rbs_less, nil_constant), :to_s)).to eq(comb.nominal_of("String"))
    end

    it "treats `Nominal[NilClass]` as nil too, not only the value-pinned `Constant[nil]`" do
      expect(dispatch(comb.difference(rbs_less, comb.nominal_of("NilClass")), :to_s)).to eq(comb.nominal_of("String"))
    end

    it "strips the nil arm out of a union base — the `T.must(x)` shape over a nullable local" do
      # rigor-sorbet's `strip_nil` builds exactly this for `T.must(x)` where `x: ProjectOnlyWidget?`.
      # The answer must be the non-nil arm's alone: `Constant[""]` from a nil arm `T.must` removed
      # would be a value the expression provably cannot hold.
      receiver = comb.difference(comb.union(rbs_less, nil_constant), nil_constant)

      expect(dispatch(receiver, :to_s)).to eq(comb.nominal_of("String"))
      expect(dispatch(receiver, :nil?)).to eq(comb.constant_of(false))
    end

    it "declines a non-nil removal: projecting to the base re-admits exactly what was removed" do
      # `(String | Integer) - Integer` is Strings only. Dispatching on the base would union `Integer`'s
      # answer back in — a WIDER type than the decline, on a carrier with no algebra for subtracting a
      # union member. `RbsDispatch`'s #533 erasure still answers these for an RBS-known base, which is
      # why `#to_s` below is not nil; what must not happen is this tier widening `#upcase`.
      base = comb.union(comb.nominal_of("String"), comb.nominal_of("Integer"))
      receiver = comb.difference(base, comb.nominal_of("Integer"))

      expect(dispatch(receiver, :upcase)).to be_nil
      # Positive neighbour: the same base with a NIL removal does project, and `#upcase` resolves.
      resolvable = comb.difference(comb.union(comb.nominal_of("String"), nil_constant), nil_constant)
      expect(dispatch(resolvable, :upcase)).to eq(comb.nominal_of("String"))
    end

    it "leaves the #533 base erasure in place for an RBS-known base" do
      # Unchanged behaviour, pinned here because the new tier sits below it and must not have moved it:
      # `non-empty-string` still answers `#upcase` through the refinement-aware catalog above RBS.
      expect(dispatch(comb.non_empty_string, :upcase)).to eq(comb.non_empty_string)
      expect(dispatch(comb.difference(comb.nominal_of("String"), comb.nominal_of("Integer")), :length))
        .to eq(comb.non_negative_int)
    end
  end

  describe "bounds" do
    it "declines a union wider than the fan-out cap rather than walking the chain once per member" do
      members = (1..9).map { |i| comb.nominal_of("WidgetKind#{i}") }

      expect(dispatch(comb.union(*members), :to_s)).to be_nil
      # Positive neighbour: one member fewer is inside the cap and resolves.
      expect(dispatch(comb.union(*members.first(8)), :to_s)).to eq(comb.nominal_of("String"))
    end
  end
end
