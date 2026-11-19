# frozen_string_literal: true

require "spec_helper"

# The synthetic-method tier asked directly, on a real `SyntheticMethodIndex` and a doubled environment. The
# promotions through a real RBS environment, asked through `MethodDispatcher.dispatch`, are
# `synthetic_method_promotion_spec.rb`'s; they are also what holds the tier in `SYNTHETIC_TIERS`.
RSpec.describe Rigor::Inference::MethodDispatcher::SyntheticMethodDispatch do
  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:account) { Rigor::Type::Combinator.nominal_of("Account") }
  let(:account_class) { Rigor::Type::Combinator.singleton_of("Account") }
  let(:money) { Rigor::Type::Combinator.nominal_of("Money") }
  let(:rbs_dispatch) { Rigor::Inference::MethodDispatcher::RbsDispatch }

  def synthetic(method_name, return_type: "untyped", kind: :instance, provenance: {})
    Rigor::Inference::SyntheticMethod.new(
      class_name: "Account", method_name: method_name, return_type: return_type, kind: kind, provenance: provenance
    )
  end

  # An environment whose index holds `entries` and which names the classes in `nominals`.
  def environment_with(*entries, nominals: {})
    index = Rigor::Inference::SyntheticMethodIndex.new(entries: entries)
    instance_double(Rigor::Environment, synthetic_method_index: index).tap do |environment|
      allow(environment).to receive(:nominal_for_name) { |name| nominals[name] }
    end
  end

  def dispatch(receiver, method_name, environment, args: [], block_type: nil)
    described_class.try_dispatch(
      cc(receiver: receiver, method_name: method_name, args: args, block_type: block_type, environment: environment)
    )
  end

  describe ".try_dispatch" do
    it "answers Dynamic[top] for a match nothing promotes" do
      expect(dispatch(account, :email, environment_with(synthetic(:email)))).to eq(untyped)
    end

    it "reads the instance side for an instance and the singleton side for a class object" do
      environment = environment_with(synthetic(:email), synthetic(:build, kind: :singleton))

      expect(dispatch(account, :email, environment)).to eq(untyped)
      expect(dispatch(account_class, :email, environment)).to be_nil
      expect(dispatch(account_class, :build, environment)).to eq(untyped)
      expect(dispatch(account, :build, environment)).to be_nil
    end

    it "declines a method the index does not hold, and a receiver that names no class" do
      environment = environment_with(synthetic(:email))

      expect(dispatch(account, :phone, environment)).to be_nil
      expect(dispatch(Rigor::Type::Combinator.constant_of(1), :email, environment)).to be_nil
    end

    it "declines without an environment, without an index, and on an empty index" do
      expect(dispatch(account, :email, nil)).to be_nil
      expect(dispatch(account, :email, instance_double(Rigor::Environment, synthetic_method_index: nil))).to be_nil
      expect(dispatch(account, :email, environment_with)).to be_nil
    end

    # The double answers `empty?` and nothing else, so a lookup on it fails the example.
    it "looks nothing up on an empty index, nor for a receiver that names no class" do
      index = instance_double(Rigor::Inference::SyntheticMethodIndex, empty?: true)
      environment = instance_double(Rigor::Environment, synthetic_method_index: index)

      expect(dispatch(account, :email, environment)).to be_nil
      allow(index).to receive(:empty?).and_return(false)
      expect(dispatch(Rigor::Type::Combinator.constant_of(1), :email, environment)).to be_nil
    end
  end

  describe "a Tier C match (a `return_type:` string)" do
    it "answers the class the environment names for it" do
      environment = environment_with(synthetic(:balance, return_type: "Money"), nominals: { "Money" => money })

      expect(dispatch(account, :balance, environment)).to eq(money)
    end

    it "answers Dynamic[top] when the environment does not name the class" do
      expect(dispatch(account, :balance, environment_with(synthetic(:balance, return_type: "Ghost")))).to eq(untyped)
    end

    it "does not look up the placeholders `untyped` and `void`" do
      environment = environment_with(synthetic(:email), synthetic(:touch, return_type: "void"),
                                     nominals: { "untyped" => money, "void" => money })

      expect(dispatch(account, :email, environment)).to eq(untyped)
      expect(dispatch(account, :touch, environment)).to eq(untyped)
      expect(environment).not_to have_received(:nominal_for_name)
    end

    it "takes the first match that promotes, in registration order" do
      integer = Rigor::Type::Combinator.nominal_of("Integer")
      environment = environment_with(
        synthetic(:balance, return_type: "Ghost"), synthetic(:balance, return_type: "Money"),
        synthetic(:balance, return_type: "Integer"), nominals: { "Money" => money, "Integer" => integer }
      )

      expect(dispatch(account, :balance, environment)).to eq(money)
    end
  end

  describe "a Tier B match (an `origin_module` in its provenance)" do
    let(:authenticatable) { synthetic(:valid_password?, provenance: { origin_module: "Authenticatable" }) }
    let(:bool) { Rigor::Type::Combinator.nominal_of("bool") }

    it "asks RbsDispatch on the origin module with the site's selector, arguments, block type and environment" do
      environment = environment_with(authenticatable)
      asked = nil
      allow(rbs_dispatch).to receive(:try_dispatch) do |context|
        asked = context
        bool
      end
      block = Rigor::Type::Combinator.nominal_of("Proc")

      expect(dispatch(account, :valid_password?, environment, args: [money], block_type: block)).to eq(bool)
      expect(asked).to eq(
        cc(receiver: Rigor::Type::Combinator.nominal_of("Authenticatable"), method_name: :valid_password?,
           args: [money], block_type: block, environment: environment)
      )
    end

    it "falls to the Tier C lookup, then to Dynamic[top], when the origin module answers nothing" do
      allow(rbs_dispatch).to receive(:try_dispatch).and_return(nil)
      promoted = synthetic(:owner, return_type: "Money", provenance: { origin_module: "Authenticatable" })

      expect(dispatch(account, :valid_password?, environment_with(authenticatable))).to eq(untyped)
      expect(dispatch(account, :owner, environment_with(promoted, nominals: { "Money" => money }))).to eq(money)
    end

    it "does not ask RbsDispatch for a match without an origin module" do
      allow(rbs_dispatch).to receive(:try_dispatch).and_return(bool)

      expect(dispatch(account, :email, environment_with(synthetic(:email)))).to eq(untyped)
      expect(rbs_dispatch).not_to have_received(:try_dispatch)
    end
  end

  # `try_dispatch` cannot reach this with a nil environment (it has no index to match from then); the guard is for
  # the function's other callers, so it is asked directly.
  describe ".promote_synthetic_match" do
    it "promotes nothing without an environment" do
      matches = [synthetic(:balance, return_type: "Money")]

      expect(described_class.promote_synthetic_match(matches, :balance, [], nil, nil)).to be_nil
    end
  end

  # The second entry: `MethodDispatcher.plugin_member_answers?` asks whether the index holds the member, not its type.
  describe ".synthetic_method_member?" do
    let(:environment) { environment_with(synthetic(:email), synthetic(:build, kind: :singleton)) }

    it "is true for a member on the receiver's side and false on the other side or for another name" do
      expect(described_class.synthetic_method_member?(account, :email, environment)).to be(true)
      expect(described_class.synthetic_method_member?(account_class, :build, environment)).to be(true)
      expect(described_class.synthetic_method_member?(account_class, :email, environment)).to be(false)
      expect(described_class.synthetic_method_member?(account, :build, environment)).to be(false)
      expect(described_class.synthetic_method_member?(account, :phone, environment)).to be(false)
    end

    it "is false without an environment, on an empty index, and for a receiver that names no class" do
      one = Rigor::Type::Combinator.constant_of(1)

      expect(described_class.synthetic_method_member?(account, :email, nil)).to be(false)
      expect(described_class.synthetic_method_member?(account, :email, environment_with)).to be(false)
      expect(described_class.synthetic_method_member?(one, :email, environment)).to be(false)
    end

    it "looks nothing up on an empty index, nor for a receiver that names no class" do
      index = instance_double(Rigor::Inference::SyntheticMethodIndex, empty?: true)
      unreadable = instance_double(Rigor::Environment, synthetic_method_index: index)

      expect(described_class.synthetic_method_member?(account, :email, unreadable)).to be(false)
      allow(index).to receive(:empty?).and_return(false)
      expect(described_class.synthetic_method_member?(Rigor::Type::Combinator.constant_of(1), :email, unreadable))
        .to be(false)
    end

    it "is false when the index raises" do
      index = instance_double(Rigor::Inference::SyntheticMethodIndex, empty?: false)
      allow(index).to receive(:lookup_instance).and_raise("boom")
      raising = instance_double(Rigor::Environment, synthetic_method_index: index)

      expect(described_class.synthetic_method_member?(account, :email, raising)).to be(false)
    end

    it "is what MethodDispatcher.plugin_member_answers? asks when no plugin contributes" do
      scope = instance_double(Rigor::Scope, environment: environment)
      allow(environment).to receive(:plugin_registry).and_return(nil)
      asked = { call_node: Prism.parse("email").value.statements.body.first, scope: scope }
      dispatcher = Rigor::Inference::MethodDispatcher

      expect(dispatcher.plugin_member_answers?(**asked, receiver_type: account, method_name: :email)).to be(true)
      expect(dispatcher.plugin_member_answers?(**asked, receiver_type: account, method_name: :phone)).to be(false)
    end
  end

  # The other second entry: the project-patched tier keys its registry lookup on the same name.
  describe ".synthetic_method_class_name" do
    it "names the class of an instance and of a class object, and nothing else" do
      expect(described_class.synthetic_method_class_name(account)).to eq("Account")
      expect(described_class.synthetic_method_class_name(account_class)).to eq("Account")
      expect(described_class.synthetic_method_class_name(Rigor::Type::Combinator.constant_of(1))).to be_nil
      expect(described_class.synthetic_method_class_name(untyped)).to be_nil
    end
  end
end
