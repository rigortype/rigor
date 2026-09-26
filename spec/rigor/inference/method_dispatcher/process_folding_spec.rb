# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::ProcessFolding do
  def process_singleton = Rigor::Type::Combinator.singleton_of("Process")
  def status_t          = Rigor::Type::Combinator.nominal_of("Process::Status")

  def fold_in(scope, method_name: :last_status, receiver: process_singleton, args: [])
    described_class.try_dispatch(cc(receiver: receiver, method_name: method_name, args: args, scope: scope))
  end

  def ran_scope = Rigor::Scope.empty.with_global(:$?, status_t)

  it "answers the bound $? past a subprocess" do
    expect(fold_in(ran_scope)).to eq(status_t)
  end

  # A `define_method` body rebinds a bound `$?` to `Dynamic[top]`, and the method reads it the same way.
  it "answers a $? bound to Dynamic[top] as it stands" do
    untyped = Rigor::Type::Combinator.untyped

    expect(fold_in(Rigor::Scope.empty.with_global(:$?, untyped))).to eq(untyped)
  end

  it "declines (defers to the overlay's Process::Status?) when $? is unbound" do
    expect(fold_in(Rigor::Scope.empty)).to be_nil
  end

  it "declines an argument-bearing call, leaving the arity to the RBS tier" do
    expect(fold_in(ran_scope, args: [Rigor::Type::Combinator.constant_of(1)])).to be_nil
  end

  it "declines another Process method and another receiver" do
    expect(fold_in(ran_scope, method_name: :pid)).to be_nil
    expect(fold_in(ran_scope, receiver: Rigor::Type::Combinator.singleton_of("Regexp"))).to be_nil
  end

  it "declines when no scope is threaded through the context" do
    expect(fold_in(nil)).to be_nil
  end
end
