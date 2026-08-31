# frozen_string_literal: true

require "spec_helper"

# `Foo.instance` for the stdlib `Singleton` mixin. Ruby grows the method through an `included` hook and the
# upstream RBS leaves `Singleton::SingletonClassMethods` empty, so no other tier can answer it.
RSpec.describe Rigor::Inference::MethodDispatcher::SingletonMixinDispatch do
  def scope_with(includes: {}, classes: {})
    base = Rigor::Scope.empty
    base.with_discovery(base.discovery.with(discovered_includes: includes, discovered_classes: classes))
  end

  def dispatch(receiver, scope, method_name: :instance, args: [])
    described_class.try_dispatch(cc(receiver: receiver, method_name: method_name, args: args, scope: scope))
  end

  let(:registry) { Rigor::Type::Combinator.singleton_of("Registry") }

  it "answers Nominal[C] for C.instance when C includes Singleton" do
    result = dispatch(registry, scope_with(includes: { "Registry" => ["Singleton"] }))
    expect(result).to eq(Rigor::Type::Combinator.nominal_of("Registry"))
  end

  it "accepts the ::-qualified spelling of the mixin" do
    result = dispatch(registry, scope_with(includes: { "Registry" => ["::Singleton"] }))
    expect(result).to eq(Rigor::Type::Combinator.nominal_of("Registry"))
  end

  it "declines for a class that includes something else" do
    expect(dispatch(registry, scope_with(includes: { "Registry" => %w[Comparable] }))).to be_nil
  end

  it "declines when the project declares its own Singleton, where the name means something else" do
    scope = scope_with(includes: { "Registry" => ["Singleton"] }, classes: { "Singleton" => "Singleton" })
    expect(dispatch(registry, scope)).to be_nil
  end

  it "declines for an instance receiver — `instance` is a class method" do
    nominal = Rigor::Type::Combinator.nominal_of("Registry")
    scope = scope_with(includes: { "Registry" => ["Singleton"] })
    expect(described_class.try_dispatch(cc(receiver: nominal, method_name: :instance, args: [], scope: scope)))
      .to be_nil
  end

  it "declines for another selector, and for `instance` called with arguments" do
    scope = scope_with(includes: { "Registry" => ["Singleton"] })
    expect(dispatch(registry, scope, method_name: :new)).to be_nil
    expect(dispatch(registry, scope, args: [Rigor::Type::Combinator.untyped])).to be_nil
  end

  it "declines without a scope — the internal dispatcher callers thread none" do
    expect(described_class.try_dispatch(cc(receiver: registry, method_name: :instance, args: []))).to be_nil
  end
end
