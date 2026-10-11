# frozen_string_literal: true

require "spec_helper"

# Issue #1816 — `Const = Module.new(&BODY)` hands the factory a block ARGUMENT, not a literal block. The constant is
# still declared, but the body is unreadable, so the new class's surface is unknown rather than empty.
RSpec.describe "meta-new write with a block argument (#1816)", type: :runner do
  let(:dynamic_mark) { Rigor::Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK }

  def undefined_methods(source)
    analyze(source).diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  {
    "Module.new" => "Ext = Module.new(&BODY)",
    "Class.new" => "Ext = Class.new(&BODY)",
    "Struct.new" => "Ext = Struct.new(:a, &BODY)",
    "Data.define" => "Ext = Data.define(:a, &BODY)",
    "a symbol block" => "Ext = Module.new(&:to_s)",
    "a method block" => "Ext = Class.new(&method(:puts))",
    "an or-write" => "Ext ||= Module.new(&BODY)",
    "a frozen write" => "Ext = Module.new(&BODY).freeze"
  }.each do |label, write|
    it "analyses #{label} without an internal analyzer error and marks the surface dynamic" do
      source = "BODY = proc { def hello = 1 }\n#{write}\n"
      expect { analyze(source) }.not_to raise_error

      tables = Rigor::Inference::ScopeIndexer.build_methods_and_def_nodes(Prism.parse(source).value)
      expect(tables.fetch(2).fetch("Ext", {})).to include(dynamic_mark)
    end
  end

  it "does not report a method the block body may define" do
    source = <<~RUBY
      BODY = proc { def hello = 1 }
      Ext = Module.new(&BODY)
      Ext.hello
    RUBY
    expect(undefined_methods(source)).to be_empty
  end

  # The user-visible effect of the dynamic mark: `$stdout = 1` raises at run time unless `Integer` can answer `write`,
  # and a module mixed in from an unreadable body might supply it. A literal empty body cannot, so it still reports.
  describe "a module mixed into Integer" do
    def global_write_rows(prelude)
      source = "#{prelude}\nclass Integer; include Ext; end\n$stdout = 1\n"
      analyze(source).diagnostics.select { |d| d.qualified_rule == "global.write-type-mismatch" }
    end

    {
      "a plain write" => "Ext = Module.new(&EXTERNAL_BODY)",
      "an or-write" => "Ext ||= Module.new(&EXTERNAL_BODY)",
      "a frozen write" => "Ext = Module.new(&EXTERNAL_BODY).freeze",
      "a path write" => "module Outer; end\nOuter::Ext = Module.new(&EXTERNAL_BODY)\nExt = Outer::Ext"
    }.each do |label, prelude|
      it "may answer `write` through #{label} whose body is a block argument" do
        expect(global_write_rows(prelude)).to be_empty
      end
    end

    it "still reports when the body is a literal empty block" do
      expect(global_write_rows("Ext = Module.new { }").size).to eq(1)
    end
  end
end
