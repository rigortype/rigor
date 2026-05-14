# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::BoundMethod do
  let(:receiver) { Rigor::Type::Combinator.constant_of("1") }

  it "stores the receiver type and method name" do
    bound = described_class.new(receiver_type: receiver, method_name: :to_i)

    expect(bound.receiver_type).to eq(receiver)
    expect(bound.method_name).to eq(:to_i)
  end

  it "erases to plain `Method` so the RBS boundary stays compatible" do
    bound = described_class.new(receiver_type: receiver, method_name: :to_i)

    expect(bound.erase_to_rbs).to eq("Method")
  end

  it "describes as Method<receiver#name>" do
    bound = described_class.new(receiver_type: receiver, method_name: :to_i)

    expect(bound.describe).to eq("Method<\"1\"#to_i>")
  end

  it "is value-equal for matching receiver + method_name" do
    a = described_class.new(receiver_type: receiver, method_name: :to_i)
    b = described_class.new(receiver_type: receiver, method_name: :to_i)
    other = described_class.new(receiver_type: receiver, method_name: :to_f)

    expect(a).to eq(b)
    expect(a).not_to eq(other)
    expect(a.hash).to eq(b.hash)
  end

  it "rejects a non-Symbol method_name" do
    expect { described_class.new(receiver_type: receiver, method_name: "to_i") }
      .to raise_error(ArgumentError, /Symbol/)
  end

  it "rejects a nil receiver_type" do
    expect { described_class.new(receiver_type: nil, method_name: :to_i) }
      .to raise_error(ArgumentError, /receiver_type/)
  end
end
