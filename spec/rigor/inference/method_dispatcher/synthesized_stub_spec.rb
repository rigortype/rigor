# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The synthesized-stub tier asked directly. It reads the receiver and the environment's RBS loader and nothing else
# of the context. The last example asks it through the dispatcher on a real environment, which is what holds it in
# `MethodDispatcher`'s `STUB_TIERS`: `runner_spec.rb`'s synthesized-stub example passes with the tier removed.
RSpec.describe Rigor::Inference::MethodDispatcher::SynthesizedStub do
  def environment_with(loader)
    instance_double(Rigor::Environment, rbs_loader: loader)
  end

  def synthesizing(*names)
    environment_with(instance_double(Rigor::Environment::RbsLoader, synthesized_type_names: Set.new(names)))
  end

  def dispatch(receiver, environment)
    described_class.try_dispatch(cc(receiver: receiver, method_name: :anything, args: [], environment: environment))
  end

  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:stub_instance) { Rigor::Type::Combinator.nominal_of("Missing::Mod") }

  it "answers Dynamic[top] for an instance and for the class object of a type Rigor synthesized" do
    environment = synthesizing("Missing::Mod")

    expect(dispatch(stub_instance, environment)).to eq(untyped)
    expect(dispatch(Rigor::Type::Combinator.singleton_of("Missing::Mod"), environment)).to eq(untyped)
  end

  it "reads the receiver's class name without a leading `::`" do
    rooted = Rigor::Type::Combinator.nominal_of("::Missing::Mod")

    expect(dispatch(rooted, synthesizing("Missing::Mod"))).to eq(untyped)
  end

  it "declines a type the loader did not synthesize, and a receiver that names no class" do
    environment = synthesizing("Missing::Mod")

    expect(dispatch(Rigor::Type::Combinator.nominal_of("String"), environment)).to be_nil
    expect(dispatch(Rigor::Type::Combinator.constant_of(1), environment)).to be_nil
  end

  it "declines without an environment" do
    expect(dispatch(stub_instance, nil)).to be_nil
  end

  it "declines when the environment has no RBS loader" do
    expect(dispatch(stub_instance, environment_with(nil))).to be_nil
  end

  # Through the dispatcher, on a real environment: `Acme::Widget#remote` names `Net::FakeService`, which no
  # signature declares, so the loader synthesizes it. No tier ahead of this one answers a call on it.
  it "is the tier MethodDispatcher.dispatch answers a call on a synthesized type from" do
    Dir.mktmpdir("rigor-stub-tier-") do |tmpdir|
      File.write(File.join(tmpdir, "widget.rbs"), "class Acme::Widget\n  def remote: () -> Net::FakeService\nend\n")
      environment = Rigor::Environment.for_project(root: tmpdir, signature_paths: [tmpdir])

      result = Rigor::Inference::MethodDispatcher.dispatch(
        receiver_type: Rigor::Type::Combinator.nominal_of("Net::FakeService"),
        method_name: :do_something, arg_types: [], environment: environment
      )

      expect(result).to eq(untyped)
    end
  end
end
