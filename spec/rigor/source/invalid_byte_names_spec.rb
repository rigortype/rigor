# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# Issue #1821 — a String literal may carry bytes no Symbol can hold, and `"\xff".to_sym` raises EncodingError. Each
# reader of a literal method name reads such a name as computed instead, so the file's other diagnostics survive and
# `rigor sig-gen` still emits a signature.
RSpec.describe "literal names with invalid bytes (#1821)", type: :runner do
  sources = {
    "private" => "class A\n  def ok = 1\n  private \"\\xff\"\nend\n",
    "protected" => "class A\n  protected \"\\xff\", :ok\n  def ok = 1\nend\n",
    "module_function" => "module M\n  module_function \"\\xff\"\n  def self.z = 1\nend\n",
    "method" => "class A\n  def y = method(\"\\xff\")\nend\n",
    "attr_accessor" => "class A\n  attr_accessor \"\\xff\", :ok\nend\n",
    "alias_method" => "class A\n  def x = 1\n  alias_method \"\\xff\", :x\nend\n"
  }

  def sig_gen(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.binwrite(path, source)
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [path]))
      Rigor::SigGen::Generator.new(configuration: configuration, paths: [path]).run
    end
  end

  sources.each do |label, source|
    it "analyses `#{label}` with an invalid-byte name without an internal error" do
      expect { analyze(source) }.not_to raise_error
    end

    it "generates signatures for `#{label}` with an invalid-byte name without an internal error" do
      expect { sig_gen(source) }.not_to raise_error
    end
  end
end
