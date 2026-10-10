# frozen_string_literal: true

require "spec_helper"

# Issue #1740 — the CRuby definer record the refinement precedence walk proves a receiver's own method with. Each
# negative row is a method core RBS declares on the class while CRuby defines it on an ancestor or not at all.
RSpec.describe Rigor::Inference::Builtins::CRubyDefiners do
  it "lists a method CRuby defines on the class itself, aliases included" do
    expect(described_class.defines?("String", :center)).to be(true)
    expect(described_class.defines?("Integer", :digits)).to be(true)
    expect(described_class.defines?("Integer", :magnitude)).to be(true)
    expect(described_class.defines?("Comparable", :clamp)).to be(true)
  end

  it "does not list a method RBS redeclares on a subclass of its CRuby owner" do
    expect(described_class.defines?("Integer", :quo)).to be(false)
    expect(described_class.defines?("File", :to_path)).to be(false)
    expect(described_class.defines?("String", :clamp)).to be(false)
  end

  it "answers false for a class no catalogue covers" do
    expect(described_class.defines?("Process::Status", :&)).to be(false)
    expect(described_class.defines?("Kernel", :center)).to be(false)
  end
end
