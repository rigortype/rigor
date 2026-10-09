# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/environment/required_features"

RSpec.describe Rigor::Environment::RequiredFeatures do
  def scan_source(source)
    Dir.mktmpdir("rigor-required-features-") do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, source)
      described_class.scan([path])
    end
  end

  it "finds a literal require in either quote style, with or without parentheses" do
    expect(scan_source(%(require "prime"\n))).to eq(%w[prime])
    expect(scan_source(%(require 'prime'\n))).to eq(%w[prime])
    expect(scan_source(%(x = 1; require("prime")\n))).to eq(%w[prime])
  end

  it "ignores require_relative, a longer feature name, a computed name and a mention in a comment" do
    expect(scan_source(%(require_relative "prime"\n))).to be_empty
    expect(scan_source(%(require "prime_helper"\nrequire "primes"\n))).to be_empty
    expect(scan_source(%(require name\n))).to be_empty
    expect(scan_source(%(# require "prime"\nputs "see `require 'prime'`"\n))).to be_empty
  end

  it "re-reads a file whose stat moved" do
    Dir.mktmpdir("rigor-required-features-") do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "p 1\n")
      expect(described_class.scan([path])).to be_empty

      File.write(path, "require 'prime'\np 1\n")
      expect(described_class.scan([path])).to eq(%w[prime])
    end
  end

  it "skips an unreadable path" do
    expect(described_class.scan(["/nonexistent/rigor/a.rb"])).to be_empty
  end

  it "turns features into library tokens, leaving a configured library to RBS resolution" do
    expect(described_class.tokens(%w[prime], [])).to eq(["rigor-vendored:prime"])
    expect(described_class.tokens(%w[prime], %w[prime])).to be_empty
    expect(described_class.active_dirs(%w[json rigor-vendored:prime])).to eq(%w[prime])
  end
end
