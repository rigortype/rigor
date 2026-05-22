# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::RegexpFolding do
  def regexp_singleton = Rigor::Type::Combinator.singleton_of("Regexp")
  def c(value)         = Rigor::Type::Combinator.constant_of(value)

  def fold(method_name, *arg_types)
    described_class.try_dispatch(
      receiver: regexp_singleton,
      method_name: method_name,
      args: arg_types
    )
  end

  describe "escape / quote" do
    it "escapes a period to a backslash-period" do
      expect(fold(:escape, c("hello.world"))).to eq(c("hello\\.world"))
    end

    it "escapes brackets and other meta-characters" do
      expect(fold(:escape, c("[a-z]*"))).to eq(c("\\[a\\-z\\]\\*"))
    end

    it "returns the string unchanged when no meta-characters are present" do
      expect(fold(:escape, c("hello"))).to eq(c("hello"))
    end

    it "treats quote as an alias for escape" do
      expect(fold(:quote, c("hello.world"))).to eq(fold(:escape, c("hello.world")))
    end

    it "declines for a non-Constant argument" do
      expect(fold(:escape, Rigor::Type::Combinator.nominal_of("String"))).to be_nil
    end

    it "declines for a non-String constant" do
      expect(fold(:escape, c(42))).to be_nil
    end

    it "declines when more than one argument is given" do
      expect(fold(:escape, c("a"), c("b"))).to be_nil
    end

    it "declines for a non-Singleton receiver" do
      result = described_class.try_dispatch(
        receiver: c("Regexp"),
        method_name: :escape,
        args: [c("hello")]
      )
      expect(result).to be_nil
    end

    it "declines for a wrong singleton class" do
      result = described_class.try_dispatch(
        receiver: Rigor::Type::Combinator.singleton_of("String"),
        method_name: :escape,
        args: [c("hello")]
      )
      expect(result).to be_nil
    end

    it "declines for an unsupported method" do
      expect(fold(:compile, c("hello"))).to be_nil
    end
  end
end
