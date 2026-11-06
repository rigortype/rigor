# frozen_string_literal: true

# Issue #2792 — a `method_missing` RBS declares on the receiver's class or an ancestor answers every name Ruby
# dispatches there, so `call.undefined-method` must not fire (`SimpleDelegator.new("x").to_str`, which `Delegator`
# forwards). Core's `BasicObject#method_missing`, the one every object reaches, raises and opens nothing. Each row's
# Ruby behaviour was witnessed on Ruby 4.0 with `ruby -rdelegate`.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "An RBS-declared method_missing and call.undefined-method (#2792)" do
  def write_project(sig, calls, source: "")
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "types.rbs"), sig)
    File.write(File.join("lib", "caller.rb"),
               "require \"delegate\"\n#{source}\ndef run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
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
    Dir.mktmpdir("rigor-rbs-method-missing-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "opens a SimpleDelegator, built here or returned by a signature, whose Delegator RBS declares method_missing" do
    write_project("class Factory\n  def self.make: () -> SimpleDelegator\nend\n",
                  ['SimpleDelegator.new("x").to_str', "Factory.make.zork"])
    expect(undefined_messages).to be_empty
  end

  it "opens a project subclass of SimpleDelegator through its RBS ancestor (#2793's third shape)" do
    write_project("class W < SimpleDelegator\nend\n", ['W.new("x").upcase'], source: "class W < SimpleDelegator\nend\n")
    expect(undefined_messages).to be_empty
  end

  it "opens a class whose own RBS declares method_missing, public or private" do
    sig = <<~RBS
      class Ghost
        def method_missing: (Symbol, *untyped) -> untyped
      end
      class PrivGhost
        private def method_missing: (Symbol, *untyped) -> untyped
      end
    RBS
    write_project(sig, %w[Ghost.new.anything PrivGhost.new.anything])
    expect(undefined_messages).to be_empty
  end

  it "opens a class that includes a module whose RBS declares method_missing" do
    sig = <<~RBS
      module Hooky
        def method_missing: (Symbol, *untyped) -> untyped
      end
      class Incl
        include Hooky
      end
    RBS
    write_project(sig, %w[Incl.new.anything])
    expect(undefined_messages).to be_empty
  end

  it "still fires where only BasicObject's core method_missing is reachable" do
    sig = "class Base0 < BasicObject\nend\nclass Plain\nend\n"
    write_project(sig, %w[Base0.new.nothing Plain.new.nothing])
    expect(undefined_messages).to eq(["undefined method `nothing' for Base0", "undefined method `nothing' for Plain"])
  end

  it "does not open receivers through a project RBS reopening of Object, Kernel, Module or Class" do
    sig = %w[Object Kernel Module Class].map do |name|
      keyword = name == "Kernel" ? "module" : "class"
      "#{keyword} #{name}\n  def method_missing: (Symbol, *untyped) -> untyped\nend\n"
    end.join
    write_project("#{sig}class Plain\nend\n", %w[Plain.new.nothing Plain.nothing], source: "class Plain\nend\n")
    expect(undefined_messages).to eq(
      ["undefined method `nothing' for Plain", "undefined method `nothing' for singleton(Plain)"]
    )
  end

  it "does not open a class whose RBS declares respond_to_missing? alone" do
    write_project("class OnlyRtm\n  def respond_to_missing?: (*untyped) -> bool\nend\n", %w[OnlyRtm.new.nothing])
    expect(undefined_messages).to eq(["undefined method `nothing' for OnlyRtm"])
  end

  it "does not open the class object: Delegator's method_missing is an instance method" do
    write_project("", %w[SimpleDelegator.nothing_on_class])
    expect(undefined_messages).to eq(["undefined method `nothing_on_class' for singleton(SimpleDelegator)"])
  end

  it "opens the class object when its RBS declares a singleton method_missing" do
    write_project("class Meta\n  def self.method_missing: (Symbol, *untyped) -> untyped\nend\n",
                  %w[Meta.anything Meta.new.anything])
    expect(undefined_messages).to eq(["undefined method `anything' for Meta"])
  end

  # Guard, not a pin: the type was `Dynamic[top]` before #2792 too; this keeps the fix from inventing one.
  it "keeps the forwarded call's type what an unresolved call answers" do
    write_project("", ['r = SimpleDelegator.new("x").to_str', "Rigor::Testing.dump_type(r)"])
    dumps = diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
    expect(dumps).to eq(["dump_type: Dynamic[top]"])
  end
end
