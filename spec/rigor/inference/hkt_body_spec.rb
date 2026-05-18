# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::HktBody do
  let(:str_nominal) { Rigor::Type::Combinator.nominal_of(String) }

  describe Rigor::Inference::HktBody::TypeLeaf do
    it "stores a pre-built Rigor type" do
      node = described_class.new(type: str_nominal)
      expect(node.type).to eq(str_nominal)
    end

    it "rejects nil type" do
      expect { described_class.new(type: nil) }
        .to raise_error(ArgumentError, /type must not be nil/)
    end

    it "is structurally equal across constructions" do
      a = described_class.new(type: str_nominal)
      b = described_class.new(type: str_nominal)
      expect(a).to eq(b)
    end
  end

  describe Rigor::Inference::HktBody::Param do
    it "stores the parameter name as a Symbol" do
      expect(described_class.new(name: :K).name).to eq(:K)
    end

    it "rejects non-Symbol name" do
      expect { described_class.new(name: "K") }
        .to raise_error(ArgumentError, /name must be a Symbol/)
    end
  end

  describe Rigor::Inference::HktBody::AppRef do
    it "stores uri and args" do
      ref = described_class.new(uri: :"json::value", args: [Rigor::Inference::HktBody::Param.new(name: :K)])
      expect(ref.uri).to eq(:"json::value")
      expect(ref.args.size).to eq(1)
    end

    it "freezes its args" do
      ref = described_class.new(uri: :"json::value", args: [Rigor::Inference::HktBody::Param.new(name: :K)])
      expect(ref.args).to be_frozen
    end

    it "rejects un-namespaced uri" do
      expect { described_class.new(uri: :value, args: [Rigor::Inference::HktBody::Param.new(name: :K)]) }
        .to raise_error(ArgumentError, /must be namespaced/)
    end

    it "rejects empty args" do
      expect { described_class.new(uri: :"json::value", args: []) }
        .to raise_error(ArgumentError, /args must be non-empty/)
    end
  end

  describe Rigor::Inference::HktBody::Union do
    let(:leaf) { Rigor::Inference::HktBody::TypeLeaf.new(type: Rigor::Type::Combinator.nominal_of(String)) }

    it "stores arms" do
      union = described_class.new(arms: [leaf, leaf])
      expect(union.arms.size).to eq(2)
    end

    it "freezes its arms" do
      union = described_class.new(arms: [leaf])
      expect(union.arms).to be_frozen
    end

    it "rejects empty arms" do
      expect { described_class.new(arms: []) }
        .to raise_error(ArgumentError, /arms must be non-empty/)
    end
  end

  describe Rigor::Inference::HktBody::Conditional do
    let(:k_param) { Rigor::Inference::HktBody::Param.new(name: :K) }
    let(:str_leaf) { Rigor::Inference::HktBody::TypeLeaf.new(type: str_nominal) }
    let(:test) { Rigor::Inference::HktBody::TestSubtype.new(left: k_param, right: str_leaf) }

    it "stores test, then_branch, and else_branch" do
      cond = described_class.new(test: test, then_branch: str_leaf, else_branch: str_leaf)
      expect(cond.test).to eq(test)
      expect(cond.then_branch).to eq(str_leaf)
      expect(cond.else_branch).to eq(str_leaf)
    end

    it "rejects nil test/then/else" do
      expect { described_class.new(test: nil, then_branch: str_leaf, else_branch: str_leaf) }
        .to raise_error(ArgumentError, /test must not be nil/)
      expect { described_class.new(test: test, then_branch: nil, else_branch: str_leaf) }
        .to raise_error(ArgumentError, /then_branch must not be nil/)
      expect { described_class.new(test: test, then_branch: str_leaf, else_branch: nil) }
        .to raise_error(ArgumentError, /else_branch must not be nil/)
    end
  end

  describe Rigor::Inference::HktBody::TestSubtype do
    let(:left) { Rigor::Inference::HktBody::Param.new(name: :K) }
    let(:right) { Rigor::Inference::HktBody::TypeLeaf.new(type: str_nominal) }

    it "stores left and right" do
      test = described_class.new(left: left, right: right)
      expect(test.left).to eq(left)
      expect(test.right).to eq(right)
    end

    it "rejects nil sides" do
      expect { described_class.new(left: nil, right: right) }
        .to raise_error(ArgumentError, %r{left/right must not be nil})
    end
  end

  describe Rigor::Inference::HktBody::TestMembership do
    let(:left) { Rigor::Inference::HktBody::Param.new(name: :K) }
    let(:option) { Rigor::Inference::HktBody::TypeLeaf.new(type: Rigor::Type::Constant.new(:foo)) }

    it "stores left and options" do
      test = described_class.new(left: left, options: [option, option])
      expect(test.options.size).to eq(2)
    end

    it "rejects empty options" do
      expect { described_class.new(left: left, options: []) }
        .to raise_error(ArgumentError, /options must be non-empty/)
    end

    it "freezes options" do
      test = described_class.new(left: left, options: [option])
      expect(test.options).to be_frozen
    end
  end

  describe Rigor::Inference::HktBody::NominalApp do
    let(:param_k) { Rigor::Inference::HktBody::Param.new(name: :K) }

    it "stores class_name and args" do
      app = described_class.new(class_name: "Array", args: [param_k])
      expect(app.class_name).to eq("Array")
      expect(app.args).to eq([param_k])
    end

    it "rejects empty class_name" do
      expect { described_class.new(class_name: "", args: [param_k]) }
        .to raise_error(ArgumentError, /class_name must be/)
    end

    it "rejects empty args" do
      expect { described_class.new(class_name: "Array", args: []) }
        .to raise_error(ArgumentError, /args must be non-empty/)
    end
  end
end
