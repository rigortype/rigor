# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/environment/required_features"

RSpec.describe Rigor::Environment::RequiredFeatures do
  def scan_source(source)
    Dir.mktmpdir("rigor-required-features-") do |dir|
      path = File.join(dir, "a.rb")
      File.binwrite(path, source)
      described_class.scan([path])
    end
  end

  it "finds a require call naming the feature, however the call is placed" do
    [
      %(require "prime"\n),
      %(require 'prime'\n),
      %(x = 1; require("prime")\n),
      %(\xEF\xBB\xBFrequire "prime"\n).b,
      %(begin require "prime"; rescue LoadError; end\n),
      %(Kernel.require "prime"\n),
      %(::Kernel.require "prime"\n),
      %(load_it = -> { require "prime" }\n),
      %(items.each { require("prime") }\n)
    ].each { |source| expect(scan_source(source)).to eq(%w[prime]), source.inspect }
  end

  # Only a whole-line comment is read as a comment: a `#` later on a line may be inside `?#`, `%q(#)`, a regexp
  # or a continued string, and reading it as a comment would drop a real require. A trailing comment therefore
  # counts, as do a heredoc and an `=begin` block — the lenient direction, which only loads the gem's own
  # signatures. `require(` with the name on the next line and `send(:require, "prime")` are not matched.
  it "ignores a require on a whole-line comment only" do
    expect(scan_source(%(# require "prime"\n))).to be_empty
    expect(scan_source(%(  # require "prime"\n))).to be_empty
    [
      %(p 1 # then require "prime"\n),
      %(x = "#"; require "prime"\n),
      %(x = ?#; require "prime"\n),
      %(x = %q(#); require "prime"\n),
      %(x = %w[a#b]; require "prime"\n),
      %(x = /#/; require "prime"\n),
      %(doc = <<~TXT\n  require "prime"\nTXT\n),
      %(=begin\nrequire "prime"\n=end\n)
    ].each { |source| expect(scan_source(source)).to eq(%w[prime]), source.inspect }
  end

  it "ignores another receiver's require, require_relative, a longer feature name and a computed name" do
    expect(scan_source(%(loader.require "prime"\n))).to be_empty
    expect(scan_source(%(require_relative "prime"\n))).to be_empty
    expect(scan_source(%(require "prime_helper"\nrequire "primes"\n))).to be_empty
    expect(scan_source(%(require name\n))).to be_empty
  end

  it "skips an unreadable path" do
    expect(described_class.scan(["/nonexistent/rigor/a.rb"])).to be_empty
  end

  it "reads a given source in place of the file" do
    Dir.mktmpdir("rigor-required-features-") do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, "require 'prime'\n")

      expect(described_class.scan([path], sources: { path => "p 1\n" })).to be_empty
      expect(described_class.scan([], sources: { path => "require 'prime'\n" })).to eq(%w[prime])
    end
  end

  it "replaces a file with a source keyed by a relative path" do
    Dir.mktmpdir("rigor-required-features-") do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p("lib")
        File.write("lib/a.rb", "require 'prime'\n")

        expect(described_class.scan([File.expand_path("lib/a.rb")], sources: { "lib/a.rb" => "p 1\n" })).to be_empty
        expect(described_class.scan(["lib/a.rb"], sources: { "./lib/a.rb" => "p 1\n" })).to be_empty
      end
    end
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

  it "keeps its memo to the files the latest scan was asked about" do
    Dir.mktmpdir("rigor-required-features-") do |dir|
      paths = %w[a b c].map { |name| File.join(dir, "#{name}.rb").tap { |path| File.write(path, "p 1\n") } }
      described_class.scan(paths)
      described_class.scan(paths.first(1))

      expected = paths.first(1).map { |path| File.expand_path(path) }
      expect(described_class.instance_variable_get(:@memo).keys).to eq(expected)
    end
  end

  it "scans the configured paths whichever files a run names" do
    Dir.mktmpdir("rigor-required-features-") do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p("lib")
        File.write("lib/setup.rb", "require 'prime'\n")
        File.write("lib/use.rb", "p 12\n")
        config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib]))

        expect(described_class.for_configuration(config, ["lib/use.rb"])).to eq(%w[prime])
      end
    end
  end

  it "turns features and a configured library into library tokens" do
    expect(described_class.tokens(%w[prime], [])).to eq(["rigor-vendored:prime"])
    expect(described_class.tokens([], %w[prime json])).to eq(["rigor-vendored:prime"])
    expect(described_class.active_dirs(%w[json rigor-vendored:prime])).to eq(%w[prime])
  end
end
