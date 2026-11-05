# frozen_string_literal: true

# Issue #2793 — a Forwardable delegator macro defines the methods it names, so `call.undefined-method` must not
# fire on them once a `sig/` declares the class without them (dependabot-core's `Dependabot::Credential`, whose
# `def_delegators :@credential, :fetch, …` drew `undefined method 'fetch'`). Each row's Ruby behaviour was
# witnessed on Ruby 4.0 with `ruby -rforwardable`.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "Forwardable delegators and call.undefined-method (#2793)" do
  def write_project(body, calls, sig: "class Box\nend\n", extend_with: "Forwardable", keyword: "class")
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "box.rbs"), sig)
    File.write(File.join("lib", "box.rb"),
               "require \"forwardable\"\n#{keyword} Box\n  extend #{extend_with}\n  #{body}\nend\n")
    File.write(File.join("lib", "caller.rb"), "def run(box)\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
  end

  def diagnostics
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]).diagnostics
  end

  def undefined_messages
    diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-forwardable-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "records def_delegators' literal names as instance methods, and still fires for any other name" do
    write_project("def_delegators :@x, :fetch, :keys", %w[Box.new.fetch Box.new.keys Box.new.nope])
    expect(undefined_messages).to eq(["undefined method `nope' for Box"])
  end

  it "records the alias def_delegator defines, never the delegated name" do
    write_project("def_delegator :@x, :last, :final", %w[Box.new.final Box.new.last])
    expect(undefined_messages).to eq(["undefined method `last' for Box"])
  end

  it "records def_delegator's method name when no alias is given, and a string accessor's" do
    write_project("def_delegator :@x, :first\n  def_delegator \"@x.first\", :to_s, :fs",
                  %w[Box.new.first Box.new.fs])
    expect(undefined_messages).to be_empty
  end

  it "records delegate's and instance_delegate's hash keys, a name or an array of them" do
    write_project("delegate [:min, :max] => :@x\n  instance_delegate %i[sum] => :@x\n  delegate count: :@x",
                  %w[Box.new.min Box.new.max Box.new.sum Box.new.count Box.new.nope])
    # The must-still-fire arm: a key the walk failed to read would mark the class open and silence `nope` too.
    expect(undefined_messages).to eq(["undefined method `nope' for Box"])
  end

  it "records the def_instance_delegator(s) spellings" do
    write_project("def_instance_delegators :@x, :size\n  def_instance_delegator :@x, :first, :head",
                  %w[Box.new.size Box.new.head])
    expect(undefined_messages).to be_empty
  end

  it "records SingleForwardable's delegators on the singleton side only" do
    write_project("def_delegators :@y, :size\n  def_single_delegator :@y, :first, :head",
                  [], sig: "module Box\nend\n", extend_with: "SingleForwardable", keyword: "module")
    File.write(File.join("lib", "caller.rb"),
               "class Includer\n  include Box\nend\ndef run\n  Box.size\n  Box.head\n  Includer.new.size\nend\n")
    File.write(File.join("sig", "includer.rbs"), "class Includer\n  include Box\nend\n")
    expect(undefined_messages).to eq(["undefined method `size' for Includer"])
  end

  it "records a delegator in a class << self body on the singleton side" do
    write_project("class << self\n    extend Forwardable\n    def_delegators :@z, :length\n  end",
                  %w[Box.length Box.new.length])
    expect(undefined_messages).to eq(["undefined method `length' for Box"])
  end

  it "keeps the delegated methods' return types unknown" do
    write_project("def_delegators :@x, :fetch", ["dump_type(Box.new.fetch(1))"])
    dumped = diagnostics.select { |d| d.message.start_with?("dump_type") }.map(&:message)
    expect(dumped).to eq(["dump_type: Dynamic[top]"])
  end

  it "does not type a delegated method by a def the delegator replaces" do
    write_project("def fetch(_k) = 1\n  def_delegators :@x, :fetch", ["dump_type(Box.new.fetch(1))"])
    dumped = diagnostics.select { |d| d.message.start_with?("dump_type") }.map(&:message)
    expect(dumped).to eq(["dump_type: Dynamic[top]"])
  end

  it "treats a class with non-literal delegated names as open" do
    write_project("NAMES = %i[fetch]\n  def_delegators :@x, *NAMES", %w[Box.new.fetch Box.new.anything])
    expect(undefined_messages).to be_empty
  end

  it "treats a class whose delegate hash has a computed key as open" do
    write_project("NAMES = %i[fetch]\n  delegate NAMES => :@x", %w[Box.new.fetch Box.new.anything])
    expect(undefined_messages).to be_empty
  end

  it "treats a subclass of a class with non-literal delegated names as open" do
    write_project("NAMES = %i[fetch]\n  def_delegators :@x, *NAMES", %w[Sub.new.fetch])
    File.write(File.join("lib", "sub.rb"), "class Sub < Box\nend\n")
    File.write(File.join("sig", "sub.rbs"), "class Sub < Box\nend\n")
    expect(undefined_messages).to be_empty
  end

  it "records a delegator written in another file than the class's declaration" do
    write_project("def initialize; end", %w[Box.new.fetch])
    File.write(File.join("lib", "box_delegation.rb"), "class Box\n  def_delegators :@x, :fetch\nend\n")
    expect(undefined_messages).to be_empty
  end

  it "records a delegator under a branch as a possible method, which the rule does not report" do
    write_project("if ENV[\"X\"]\n    def_delegators :@x, :fetch\n  end", %w[Box.new.fetch])
    expect(undefined_messages).to be_empty
  end

  # Guard: ActiveSupport's `delegate :fetch, to: :@x` has a positional argument, so the single-hash reading of
  # `delegate` already declines it; this pins that its `to:` key is not taken for a delegated name.
  it "does not read ActiveSupport's delegate form as Forwardable's" do
    write_project("delegate :fetch, to: :@x", %w[Box.new.to])
    expect(undefined_messages).to eq(["undefined method `to' for Box"])
  end
end
