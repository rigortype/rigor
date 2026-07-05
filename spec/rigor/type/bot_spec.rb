# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Bot do
  describe "singleton access" do
    it "exposes a single shared instance via .instance" do
      expect(described_class.instance).to be_a(described_class)
      expect(described_class.instance).to equal(described_class.instance)
    end

    it "is frozen" do
      expect(described_class.instance).to be_frozen
    end

    it "forbids direct construction" do
      expect { described_class.new }.to raise_error(NoMethodError, /private method ['`]new['`]/)
    end
  end

  describe "describe" do
    it "renders as \"bot\" regardless of verbosity" do
      expect(described_class.instance.describe).to eq("bot")
      expect(described_class.instance.describe(:long)).to eq("bot")
    end
  end

  describe "erase_to_rbs" do
    it "erases to the bare RBS bot form" do
      expect(described_class.instance.erase_to_rbs).to eq("bot")
    end
  end

  describe "lattice membership" do
    it "is the bot lattice point and nothing else" do
      bot = described_class.instance
      expect(bot.top).to eq(Rigor::Trinary.no)
      expect(bot.bot).to eq(Rigor::Trinary.yes)
      expect(bot.dynamic).to eq(Rigor::Trinary.no)
    end
  end

  describe "value semantics" do
    it "is equal (by ==) to any Bot, matching structurally not just by identity" do
      # `new` is private, so the only way to get a second reference is reflective construction — this is what pins that
      # `==` checks `is_a?(Bot)` rather than accidentally degrading to `equal?`.
      other = described_class.allocate
      expect(described_class.instance).to eq(other)
    end

    it "is not equal to a different lattice extreme" do
      expect(described_class.instance).not_to eq(Rigor::Type::Top.instance)
    end

    it "hashes consistently with the class hash" do
      expect(described_class.instance.hash).to eq(described_class.hash)
    end
  end

  describe "inspect" do
    it "renders a debug string naming the class" do
      expect(described_class.instance.inspect).to eq("#<Rigor::Type::Bot>")
    end
  end
end
