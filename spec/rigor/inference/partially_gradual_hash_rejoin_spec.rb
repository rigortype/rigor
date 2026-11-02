# frozen_string_literal: true

require "spec_helper"

# Issue #2555 L3 — `Hash.new(0)` is `Hash[Dynamic[top], Integer]`, a carrier with one gradual parameter and one
# precise one. `MutationRejoin.keep_precise_parameters` restored the precise side over a store, so
# `h = Hash.new(0); h[:y] = "s"; h[:y].upcase` reported `undefined method 'upcase' for Integer` on code Ruby runs. On
# a local carrying the `:synthesised` construction fact the precise side is the engine's own fold of the default, and
# the store joins it. A local that escapes carries no fact and keeps the earlier reading: the control.
RSpec.describe "a partially gradual synthesised Hash re-grows its precise side (issue #2555)", type: :runner do
  def diagnostics(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def undefined_method_rules(source)
    diagnostics(source).map(&:rule).grep("call.undefined-method")
  end

  it "joins a store into Hash.new(0)'s value side and reports nothing" do
    expect(undefined_method_rules(<<~RUBY)).to be_empty
      def m
        h = Hash.new(0)
        h[:y] = "s"
        h[:y].upcase
      end
    RUBY
    expect(dumped_types(<<~RUBY)).to eq(["Integer | String"])
      def m
        h = Hash.new(0)
        h[:y] = "s"
        dump_type(h[:y])
      end
    RUBY
  end

  it "keeps the counter idiom's Integer" do
    expect(dumped_types(<<~RUBY)).to eq(["Integer"])
      def m
        c = Hash.new(0)
        c[:x] += 1
        dump_type(c[:x])
      end
    RUBY
  end

  it "keeps the earlier reading on a local that escapes" do
    expect(dumped_types(<<~RUBY)).to eq(["Integer"])
      def keep(_) = nil
      def m
        h = Hash.new(0)
        keep(h)
        h[:y] = "s"
        dump_type(h[:y])
      end
    RUBY
  end
end
