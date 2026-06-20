# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Environment::ClassRegistry do
  let(:registry) { described_class.default }

  it "recognises slice 1 built-ins" do
    %w[Integer Float String Symbol NilClass TrueClass FalseClass Object BasicObject].each do |name|
      klass = Object.const_get(name)
      expect(registry.registered?(klass)).to be true
      expect(registry.nominal_for(klass).class_name).to eq(name)
    end
  end

  it "recognises slice 2 built-ins added during the strengthening round" do
    %w[Array Hash Range Regexp Proc Method Module Class
       Numeric Comparable Enumerable
       Exception StandardError RuntimeError ArgumentError TypeError
       NameError NoMethodError KeyError IndexError RangeError ZeroDivisionError
       IO File Dir Encoding].each do |name|
      klass = Object.const_get(name)
      expect(registry.registered?(klass)).to be true
      expect(registry.nominal_for(klass).class_name).to eq(name)
    end
  end

  it "rejects classes it does not know" do
    unknown = Class.new
    expect(registry.registered?(unknown)).to be false
    expect { registry.nominal_for(unknown) }.to raise_error(KeyError)
  end

  describe "#nominal_for_name" do
    it "resolves built-ins by Symbol or String" do
      expect(registry.nominal_for_name(:Integer).class_name).to eq("Integer")
      expect(registry.nominal_for_name("Hash").class_name).to eq("Hash")
      expect(registry.nominal_for_name(:StandardError).class_name).to eq("StandardError")
    end

    it "returns nil for unknown names" do
      expect(registry.nominal_for_name(:UnknownConstant)).to be_nil
      expect(registry.nominal_for_name("Some::Path")).to be_nil
    end

    it "returns nil for nil" do
      expect(registry.nominal_for_name(nil)).to be_nil
    end
  end

  describe "#register validation" do
    # A fresh (non-shareable) registry — the `default` one is frozen.
    let(:fresh) { described_class.new }

    it "registers a Module and returns self" do
      expect(fresh.register(Integer)).to be(fresh)
      expect(fresh.registered?(Integer)).to be(true)
    end

    it "raises ArgumentError naming the class of a non-Module argument" do
      expect { fresh.register(42) }
        .to raise_error(ArgumentError, /expected Class or Module, got Integer/)
    end

    it "raises ArgumentError for an anonymous class with no name" do
      expect { fresh.register(Class.new) }
        .to raise_error(ArgumentError, /anonymous class has no name/)
    end
  end

  describe "#class_ordering" do
    it "classifies the ancestry relation between two registered names" do
      expect(registry.class_ordering("Integer", "Integer")).to eq(:equal)
      expect(registry.class_ordering("Integer", "Numeric")).to eq(:subclass)
      expect(registry.class_ordering("Numeric", "Integer")).to eq(:superclass)
      expect(registry.class_ordering("Integer", "String")).to eq(:disjoint)
    end

    it "returns :unknown when either name is not registered" do
      expect(registry.class_ordering("Integer", "NoSuchClass")).to eq(:unknown)
      expect(registry.class_ordering("NoSuchClass", "Integer")).to eq(:unknown)
    end

    it "normalizes a leading :: and accepts Symbol names" do
      # normalize_name strips the top-level "::" and coerces to String,
      # so "::Integer" and :Integer resolve to the same registered class.
      expect(registry.class_ordering("::Integer", "Integer")).to eq(:equal)
      expect(registry.class_ordering(:Integer, :Numeric)).to eq(:subclass)
    end
  end
end
