# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::TimeFolding do
  def time_singleton = Rigor::Type::Combinator.singleton_of("Time")
  def c(value)       = Rigor::Type::Combinator.constant_of(value)

  def fold(method_name, *arg_types)
    described_class.try_dispatch(cc(
                                   receiver: time_singleton,
                                   method_name: method_name,
                                   args: arg_types
                                 ))
  end

  describe "Time.utc / Time.gm" do
    it "folds Time.utc on constant integer arguments" do
      result = fold(:utc, c(2026), c(1), c(1))
      expect(result).to eq(c(Time.utc(2026, 1, 1)))
    end

    it "treats gm as an alias of utc" do
      expect(fold(:gm, c(2026), c(1), c(1))).to eq(fold(:utc, c(2026), c(1), c(1)))
    end

    it "folds the full year-month-day-hour-min-sec form" do
      result = fold(:utc, c(2026), c(1), c(1), c(12), c(30), c(15))
      expect(result).to eq(c(Time.utc(2026, 1, 1, 12, 30, 15)))
    end

    it "declines for a non-Constant argument" do
      expect(fold(:utc, Rigor::Type::Combinator.nominal_of("Integer"))).to be_nil
    end

    it "declines for a non-integer / non-string constant" do
      expect(fold(:utc, c(2026.5))).to be_nil
    end

    it "declines on a malformed argument shape (constructor raises)" do
      expect(fold(:utc, c(2026), c(99), c(99))).to be_nil
    end

    it "declines when no argument is given" do
      expect(fold(:utc)).to be_nil
    end
  end

  describe "dispatch gating" do
    it "declines when the receiver is not the Time singleton" do
      result = described_class.try_dispatch(cc(
                                              receiver: Rigor::Type::Combinator.singleton_of("Math"),
                                              method_name: :utc,
                                              args: [c(2026), c(1), c(1)]
                                            ))
      expect(result).to be_nil
    end

    it "declines for non-utc / non-gm methods (e.g. Time.now, Time.at)" do
      expect(fold(:now)).to be_nil
      expect(fold(:at, c(0))).to be_nil
    end
  end
end
