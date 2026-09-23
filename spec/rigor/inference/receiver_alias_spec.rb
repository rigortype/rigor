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

    it "answers a class-variable and a global compound write with a read of the variable" do
      cvar = described_class.read_of(first_statement("@@x ||= 1"))
      expect([cvar.class, cvar.name, cvar.location.slice]).to eq([Prism::ClassVariableReadNode, :@@x, "@@x"])

      global = described_class.read_of(first_statement("$x += 1"))
      expect([global.class, global.name, global.location.slice]).to eq([Prism::GlobalVariableReadNode, :$x, "$x"])
    end
  end

  # The one receiver answer the straight-line widening, the block-return threading gate and the per-element
  # fold's content-mutation scan read.
  describe ".mutated_reads" do
    def receiver(source) = Prism.parse(source).value.statements.body.last.receiver

    it "names a class variable or global the receiver reads directly, parenthesised or not" do
      expect(described_class.mutated_reads(receiver("@@c << 1")).map(&:name)).to eq([:@@c])
      expect(described_class.mutated_reads(receiver("(($g)) << 1")).map(&:name)).to eq([:$g])
    end

    # A class-variable or global write evaluates to the variable it writes, as a local or instance-variable write
    # does for {.candidates}; without it `(@@c ||= []) << 1` left `@@c` at the `[]` the `||=` stored.
    it "names the class variable or global a parenthesised write evaluates to" do
      cvar = described_class.mutated_reads(receiver("(@@c ||= []) << 1"))
      expect(cvar.map { |read| [read.class, read.name] }).to eq([[Prism::ClassVariableReadNode, :@@c]])

      global = described_class.mutated_reads(receiver("($g = []) << 1"))
      expect(global.map { |read| [read.class, read.name] }).to eq([[Prism::GlobalVariableReadNode, :$g]])
    end

    it "does not name a class variable or global through a branch that selects it" do
      expect(described_class.mutated_reads(receiver("(f ? $a : $b) << 1"))).to be_empty
    end

    it "names the locals a branch selects, as candidates does" do
      expect(described_class.mutated_reads(receiver("a = []; b = []; (f ? a : b) << 1")).map(&:name)).to eq(%i[a b])
    end
  end

  describe ".read_name" do
    it "names an `it` read, which carries no name, as the local `:it`" do
      read = Prism.parse("[[]].each { it << 1 }").value.statements.body.first.block.body.body.first.receiver
      expect(read).to be_a(Prism::ItLocalVariableReadNode)
      expect(described_class.read_name(read)).to eq(:it)
    end

    it "names every other read by its own name" do
      expect(described_class.read_name(first_statement("@@c"))).to eq(:@@c)
    end
  end

  describe ".block_local?" do
    it "holds for an `it` read and a local the innermost block binds" do
      it_block = Prism.parse("[1].each { it }").value.statements.body.first.block
      y_read, x_read = Prism.parse("x = 1\n[1].each { |y| y; x }").value.statements.body.last.block.body.body
      expect(described_class.block_local?(it_block.body.body.first)).to be(true)
      expect(described_class.block_local?(y_read)).to be(true)
      expect(described_class.block_local?(x_read)).to be(false)
    end

    it "does not hold for an instance variable" do
      expect(described_class.block_local?(first_statement("@x"))).to be(false)
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
