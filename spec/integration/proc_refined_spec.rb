# frozen_string_literal: true

# Issue #1665 — Ruby 4.1's `Proc#refined(*modules)` resolves and returns the receiver's own type.
#
# No ruby/rbs release declares the method, so `->(s) { s.shout }.refined(Shout)` reported `call.undefined-method`
# on correct 4.1 code. CRuby copies the receiver with its class, lambda-ness, parameters and source location
# (`rb_proc_dup_with_iseq_and_recipe` in `vm.c`; `test_refined_preserves_lambda` and
# `test_refined_preserves_location_and_parameters` in `test/ruby/test_proc.rb`), and returns the receiver itself
# when given no module, so the overlay declares `-> self` rather than `-> Proc`.
#
# Declared unconditionally, not only for `target_ruby >= 4.1`: gating would report every correct 4.1 project still on
# the default `target_ruby`. The RBS-definition half is in `spec/rigor/environment/proc_refined_spec.rb`.
require "spec_helper"

RSpec.describe "Proc#refined", type: :runner do
  def summary(source, sig: {})
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig)
    result.diagnostics.filter_map do |diagnostic|
      if diagnostic.message.start_with?("dump_type")
        diagnostic.message.delete_prefix("dump_type: ")
      elsif diagnostic.severity == :error
        diagnostic.qualified_rule
      end
    end
  end

  # THE REPORTED FALSE POSITIVE. The last line is the positive control: a Proc method that does not exist still
  # reports, so the silence above is not `Proc` degraded to `Dynamic[top]`.
  it "resolves the issue's repro and keeps the lambda's type" do
    expect(summary(<<~RUBY)).to eq(%w[Proc Proc call.undefined-method])
      module Shout
        refine(String) { def shout = upcase + "!" }
      end

      l = ->(s) { s.shout }
      pr = l.refined(Shout)
      dump_type(l)
      dump_type(pr)
      pr.refinedd(Shout)
    RUBY
  end

  it "answers Proc for an untyped Proc, with no module and with several" do
    expect(summary(<<~RUBY)).to eq(%w[Proc Proc Proc])
      dump_type(Proc.new { 1 }.refined)
      dump_type(proc { |a, b| a }.refined(Comparable, Kernel))
      dump_type(Proc.new { 1 }.refined(Comparable))
    RUBY
  end

  # `-> self`, not `-> Proc`: CRuby builds the copy with `rb_obj_class(self)`, so a Proc subclass stays that subclass
  # and its own methods stay reachable.
  it "returns the receiver's own class for a Proc subclass" do
    sig = {
      "tagged_proc.rbs" => <<~RBS
        class TaggedProc < Proc
          def tag: () -> Symbol
        end

        module TaggedProcs
          def self.build: () -> TaggedProc
        end
      RBS
    }
    expect(summary(<<~RUBY, sig: sig)).to eq(%w[TaggedProc Symbol])
      refined = TaggedProcs.build.refined(Comparable)
      dump_type(refined)
      dump_type(refined.tag)
    RUBY
  end
end
