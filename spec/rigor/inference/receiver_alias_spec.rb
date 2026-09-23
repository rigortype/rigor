# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::ReceiverAlias do
  def first_statement(source)
    Prism.parse(source).value.statements.body.first
  end

  # `read_of` constructs Prism nodes positionally (`source, node_id, location, flags` and the fields), the
  # signature every `Prism` 1.x node has; a Prism release that changes it fails here rather than as a silent
  # mis-narrowing.
  describe ".read_of" do
    it "answers a local write with a read of the local at the write's name and depth" do
      write = first_statement("x = 1")
      read = described_class.read_of(write)
      expect(read).to be_a(Prism::LocalVariableReadNode)
      expect([read.name, read.depth, read.location.slice]).to eq([:x, 0, "x"])
    end

    it "answers an instance-variable compound write with a read of the instance variable" do
      read = described_class.read_of(first_statement("@x ||= 1"))
      expect(read).to be_a(Prism::InstanceVariableReadNode)
      expect(read.name).to eq(:@x)
    end
  end

  describe ".candidates" do
    it "names the variable a parenthesised write evaluates to" do
      call = Prism.parse("buf = nil\n(buf ||= []) << 1").value.statements.body.last
      expect(described_class.candidates(call.receiver).map(&:name)).to eq([:buf])
    end

    it "names nothing for a call result" do
      call = first_statement("foo.bar << 1")
      expect(described_class.candidates(call.receiver)).to be_empty
    end
  end
end
