# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Effects::LabelSet do
  let(:top) { described_class::TOP }
  let(:empty) { described_class::EMPTY }

  describe "construction" do
    it "sorts and de-duplicates its members" do
      set = described_class.new(%w[nondet.time io.db io.db exit])

      expect(set.to_a).to eq(%w[exit io.db nondet.time])
    end

    it "rejects a member that is not a well-formed label" do
      expect { described_class.new(%w[io IO.net]) }.to raise_error(ArgumentError, /well-formed effect label/)
    end

    it "is frozen, and so is its member array" do
      set = described_class.new(%w[io])

      expect(set).to be_frozen
      expect(set.to_a).to be_frozen
    end

    it "does not alias the array it was built from" do
      source = %w[io]
      set = described_class.new(source)
      source << "exit"

      expect(set.to_a).to eq(%w[io])
    end
  end

  describe "the sentinels" do
    it "distinguishes TOP from EMPTY even though both enumerate nothing" do
      expect(top.to_a).to eq([])
      expect(empty.to_a).to eq([])
      expect(top).not_to eq(empty)
      expect(top.top?).to be(true)
      expect(empty.top?).to be(false)
    end

    it "reads EMPTY as empty and TOP as not empty" do
      # TOP records nothing because it stands for everything, so `empty?` must not conflate them.
      expect(empty.empty?).to be(true)
      expect(top.empty?).to be(false)
      expect(described_class.new(%w[io]).empty?).to be(false)
    end

    it "admits every well-formed label through TOP and none through EMPTY" do
      expect(top.admits?("io.net.http")).to be(true)
      expect(top.admits?("acme.whatever")).to be(true)
      expect(top.admits?("NOT A LABEL")).to be(false)
      expect(empty.admits?("io")).to be(false)
    end

    it "records no members in TOP, so `include?` finds none" do
      expect(top.include?("io")).to be(false)
    end
  end

  describe "#include? versus #admits?" do
    let(:set) { described_class.new(%w[io]) }

    it "asks exact membership" do
      expect(set.include?("io")).to be(true)
      expect(set.include?("io.net")).to be(false)
    end

    it "asks subsumption" do
      expect(set.admits?("io.net")).to be(true)
      expect(set.admits?("iota")).to be(false)
    end
  end

  describe "#join" do
    it "unions members" do
      joined = described_class.new(%w[io.db]).join(described_class.new(%w[nondet.time io.db]))

      expect(joined.to_a).to eq(%w[io.db nondet.time])
    end

    it "is absorbed by TOP from either side" do
      set = described_class.new(%w[io.db])

      expect(set.join(top).top?).to be(true)
      expect(top.join(set).top?).to be(true)
      expect(top.join(top).top?).to be(true)
    end

    it "leaves the operands untouched" do
      left = described_class.new(%w[io.db])
      right = described_class.new(%w[nondet.time])
      left.join(right)

      expect(left.to_a).to eq(%w[io.db])
      expect(right.to_a).to eq(%w[nondet.time])
    end

    it "is identity with EMPTY" do
      set = described_class.new(%w[io.db])

      expect(set.join(empty)).to eq(set)
      expect(empty.join(set)).to eq(set)
    end
  end

  describe "#subsumed_by?" do
    it "holds when every member is admitted by some member of the bound" do
      set = described_class.new(%w[io.net.http io.db.read])

      expect(set.subsumed_by?(described_class.new(%w[io]))).to be(true)
      expect(set.subsumed_by?(described_class.new(%w[io.net io.db]))).to be(true)
    end

    it "fails when one member escapes the bound" do
      set = described_class.new(%w[io.net.http nondet.time])

      expect(set.subsumed_by?(described_class.new(%w[io]))).to be(false)
    end

    it "is not a string-prefix test" do
      expect(described_class.new(%w[iota]).subsumed_by?(described_class.new(%w[io]))).to be(false)
    end

    it "holds vacuously for EMPTY and against TOP" do
      expect(empty.subsumed_by?(described_class.new(%w[io]))).to be(true)
      expect(described_class.new(%w[io.db]).subsumed_by?(top)).to be(true)
    end

    it "bounds TOP only by TOP" do
      expect(top.subsumed_by?(described_class.new(%w[io]))).to be(false)
      expect(top.subsumed_by?(empty)).to be(false)
      expect(top.subsumed_by?(top)).to be(true)
    end
  end

  describe "equality" do
    it "is structural, so member order at construction does not matter" do
      expect(described_class.new(%w[io.db exit])).to eq(described_class.new(%w[exit io.db]))
      expect(described_class.new(%w[io.db exit]).hash).to eq(described_class.new(%w[exit io.db]).hash)
    end

    it "makes equal sets interchangeable as hash keys" do
      table = { described_class.new(%w[io.db]) => :seen }

      expect(table[described_class.new(%w[io.db])]).to eq(:seen)
    end

    it "separates unequal sets" do
      expect(described_class.new(%w[io.db])).not_to eq(described_class.new(%w[io]))
      expect(described_class.new(%w[io])).not_to eq("io")
    end
  end
end
