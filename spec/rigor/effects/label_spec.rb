# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Effects::Label do
  describe ".valid?" do
    it "accepts a single segment and a dot-path" do
      expect(described_class.valid?("io")).to be(true)
      expect(described_class.valid?("io.net.http")).to be(true)
      expect(described_class.valid?("nondet.time")).to be(true)
    end

    it "accepts digits after the first character of a segment" do
      expect(described_class.valid?("io.s3")).to be(true)
      expect(described_class.valid?("h2")).to be(true)
    end

    it "rejects a segment that does not start with a lowercase letter" do
      %w[IO 3io _io .io io..net io. io._net].each do |candidate|
        expect(described_class.valid?(candidate)).to be(false), "expected #{candidate.inspect} to be rejected"
      end
    end

    it "rejects separators the grammar does not have" do
      ["io-net", "io_net", "io/net", "io net", "email:send"].each do |candidate|
        expect(described_class.valid?(candidate)).to be(false), "expected #{candidate.inspect} to be rejected"
      end
    end

    it "rejects the empty string and non-strings" do
      expect(described_class.valid?("")).to be(false)
      expect(described_class.valid?(:io)).to be(false)
      expect(described_class.valid?(nil)).to be(false)
    end

    it "rejects a multi-line string that would otherwise match line-wise" do
      # `\A`/`\z` rather than `^`/`$`: an envelope reader must not accept a smuggled newline.
      expect(described_class.valid?("io\nrm -rf")).to be(false)
    end
  end

  describe ".subsumes?" do
    it "admits a descendant" do
      expect(described_class.subsumes?("io", "io.net.http")).to be(true)
      expect(described_class.subsumes?("io.net", "io.net.http")).to be(true)
    end

    it "is reflexive" do
      expect(described_class.subsumes?("io", "io")).to be(true)
      expect(described_class.subsumes?("io.net.http", "io.net.http")).to be(true)
    end

    it "matches on segment boundaries, not on characters" do
      # The whole point of the relation: a string-prefix test would say true here.
      expect(described_class.subsumes?("io", "iota")).to be(false)
      expect(described_class.subsumes?("cache", "cachet.read")).to be(false)
      expect(described_class.subsumes?("mutate.self", "mutate.selfish")).to be(false)
    end

    it "does not run upwards" do
      expect(described_class.subsumes?("io.net.http", "io.net")).to be(false)
      expect(described_class.subsumes?("io.net", "io")).to be(false)
    end

    it "answers false for a malformed operand rather than raising" do
      expect(described_class.subsumes?("io", "IO.net")).to be(false)
      expect(described_class.subsumes?("", "io")).to be(false)
      expect(described_class.subsumes?(nil, "io")).to be(false)
    end
  end

  describe ".segments" do
    it "splits outermost first" do
      expect(described_class.segments("io.db.read")).to eq(%w[io db read])
      expect(described_class.segments("io")).to eq(%w[io])
    end

    it "returns an empty array for a malformed label" do
      expect(described_class.segments("io..net")).to eq([])
      expect(described_class.segments(nil)).to eq([])
    end

    it "returns a frozen array" do
      expect(described_class.segments("io.db.read")).to be_frozen
    end
  end

  describe ".parent" do
    it "drops the innermost segment" do
      expect(described_class.parent("io.net.http")).to eq("io.net")
      expect(described_class.parent("io.net")).to eq("io")
    end

    it "is nil for a root and for a malformed label" do
      expect(described_class.parent("io")).to be_nil
      expect(described_class.parent("io..net")).to be_nil
    end
  end

  describe ".ancestors" do
    it "lists the proper ancestors outermost first" do
      expect(described_class.ancestors("io.net.http")).to eq(%w[io io.net])
      expect(described_class.ancestors("io.net")).to eq(%w[io])
    end

    it "excludes the label itself" do
      expect(described_class.ancestors("io.net.http")).not_to include("io.net.http")
    end

    it "is empty for a root and for a malformed label" do
      expect(described_class.ancestors("io")).to eq([])
      expect(described_class.ancestors("io.")).to eq([])
    end
  end

  describe ".root" do
    it "is the outermost segment" do
      expect(described_class.root("io.db.read")).to eq("io")
      expect(described_class.root("telemetry")).to eq("telemetry")
    end

    it "is nil for a malformed label" do
      expect(described_class.root("Io")).to be_nil
    end
  end
end
