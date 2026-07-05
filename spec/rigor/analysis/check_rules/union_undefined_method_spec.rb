# frozen_string_literal: true

require "spec_helper"

# `call.undefined-method` on a *union* receiver. The scalar existence check bails when the receiver has no single
# concrete class; this slice fires when every non-nil arm is a fully-known, bounded, instance class on which the method
# is absent — `A | B` responds to `m` only if both `A` and `B` do, so a method absent on every arm is undefined
# regardless of which arm the value takes. FP-safe: any Dynamic / unknown / source-declared / open / nil arm suppresses
# the diagnostic. Surfaced by the tool/mutation teeth sweep.
RSpec.describe "union-receiver undefined-method" do
  def undefined_method_messages(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
                           .select { |d| d.rule == "call.undefined-method" }
                           .map(&:message)
  end

  it "fires when the method is absent on every arm of a non-nil union" do
    source = <<~RUBY
      def f(flag)
        x = flag ? "s" : :sym
        x.no_such_method_zzz
      end
    RUBY

    expect(undefined_method_messages(source)).to contain_exactly(
      a_string_matching(/undefined method `no_such_method_zzz'/)
    )
  end

  it "stays silent when the method exists on every arm" do
    source = <<~RUBY
      def f(flag)
        x = flag ? "s" : :sym
        x.to_s
      end
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "stays silent when at least one arm supports the method" do
    # `upcase` exists on String but not Integer — the call is sound on the String arm, so firing would be a false
    # positive.
    source = <<~RUBY
      def f(flag)
        x = flag ? "s" : 1
        x.upcase
      end
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "stays silent on a same-class union (a shape-join artifact, not a multi-class union)" do
    # `[1] | [1, 2, 3]` is two Array shapes, not "an A or a B". Firing there is the scalar rule's job, and a same-class
    # union is often a join misinference (a corpus probe caught `Hash | Hash` for an Array); require ≥2 distinct arm
    # classes.
    source = <<~RUBY
      def f(flag)
        a = flag ? [1] : [1, 2, 3]
        a.no_such_method_zzz
      end
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "defers nil-bearing unions to the possible-nil-receiver rule (slice 1 is non-nil only)" do
    source = <<~RUBY
      def f(flag)
        y = flag ? "s" : nil
        y.no_such_method_zzz
      end
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end
end
