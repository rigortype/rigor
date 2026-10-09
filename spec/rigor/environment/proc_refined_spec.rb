# frozen_string_literal: true

# Issue #1665 — `data/core_overlay/proc.rbs` declares Ruby 4.1's `Proc#refined` through a module `Proc` includes.
#
# This half lives under `spec/rigor/environment` because that is what CI's "RBS compatibility (RBS 3.x)" job runs:
# a broken overlay degrades `Proc`'s whole instance surface on that line. The inference half is in
# `spec/integration/proc_refined_spec.rb`.
require "spec_helper"

RSpec.describe "Proc#refined (core overlay)" do
  let(:loader) { Rigor::Environment::RbsLoader.new(libraries: []) }

  def proc_instance_methods
    loader.instance_definition("Proc")&.methods
  end

  it "declares (*Module) -> self from the core overlay" do
    method = proc_instance_methods&.[](:refined)

    expect(method).not_to be_nil
    expect(method.method_types.map(&:to_s)).to eq(["(*::Module) -> self"])
    expect(method.defs.map { |definition| definition.member.location.buffer.name.to_s })
      .to all(end_with("data/core_overlay/proc.rbs"))
  end

  it "leaves Proc's upstream instance methods buildable" do
    expect(proc_instance_methods&.keys).to include(:call, :curry, :lambda?, :parameters, :refined)
  end

  # A later rbs or a project `sig/` may declare the method directly. Its `def` overrides the included one instead of
  # raising `DuplicatedMethodDefinitionError`, which would leave every `Proc` method `Dynamic[top]` and the typo on the
  # last line unreported.
  it "lets a direct signature of Proc#refined stand without degrading Proc", type: :runner do
    sig = "class Proc\n  def refined: (*Module modules) -> Integer\nend\n"
    result = analyze(<<~RUBY, sig: { "proc.rbs" => sig })
      require "rigor/testing"
      include Rigor::Testing
      pr = proc { 1 }
      dump_type(pr.refined(Comparable))
      pr.refinedd
    RUBY
    summary = result.diagnostics.filter_map do |diagnostic|
      if diagnostic.message.start_with?("dump_type")
        diagnostic.message.delete_prefix("dump_type: ")
      elsif diagnostic.severity == :error
        diagnostic.qualified_rule
      end
    end

    expect(summary).to eq(%w[Integer call.undefined-method])
  end
end
