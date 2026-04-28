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
end
