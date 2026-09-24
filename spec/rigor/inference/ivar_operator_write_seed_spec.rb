# frozen_string_literal: true

require "spec_helper"

# An instance method reads an ivar through the class-wide seed (ADR-58), and the seed's contribution from
# `@x op= v` is `@x op v` dispatched on what the class's other writes store. Those writes live in methods Ruby
# may call in any order, so the contribution cannot depend on which of them the pre-pass walked first. It did:
# the dispatch read the seed as the walk had it so far, so a `+=` written above `@x &&= 1.5` never saw the `1.5`,
# `Float` fell out of the seed, and `x == 2.5` folded always-falsey on a program that prints.
#
# Every order is checked against a control that must keep firing: without the `+=`, `@x` is `1` or `1.5` and the
# condition is always falsey at runtime too.
RSpec.describe "class ivar seed of an `op=` write", type: :runner do
  def flow_rules(source)
    analyze(source).diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.") }
  end

  def scale(*methods)
    definitions = {
      initialize: "def initialize = (@x = 1)",
      shrink: "def shrink = (@x &&= 1.5)",
      grow: "def grow = (@x += 1)"
    }
    <<~RUBY
      class Scale
        #{methods.map { |name| definitions.fetch(name) }.join("\n  ")}

        def check
          x = @x
          puts "two and a half" if x.is_a?(Float) && x == 2.5
        end
      end
    RUBY
  end

  %i[initialize shrink grow].permutation.each do |order|
    it "keeps `x == 2.5` live with the methods in the order #{order.join(', ')}" do
      # Runtime: prints, since `shrink` then `grow` leaves `@x` at `2.5`.
      expect(flow_rules(scale(*order))).to be_empty
    end
  end

  it "keeps the condition live beside a write the operator cannot take" do
    # Runtime: prints after `bump`. Dispatched on `0.5 | nil` as one union, `nil + 1` has no method, the `+=` fell
    # back to its rvalue, and the seed lost `Float`.
    %w[nil false].each do |cleared|
      expect(flow_rules(<<~RUBY)).to be_empty
        class Meter
          def initialize = (@level = 0.5)
          def bump = (@level += 1)
          def clear = (@level = #{cleared})

          def report
            l = @level
            puts "overflow" if l.is_a?(Float) && l > 1.0
          end
        end
      RUBY
    end
  end

  it "keeps the condition live beside a `||=` of the same ivar" do
    expect(flow_rules(<<~RUBY)).to be_empty
      class Meter
        def initialize = (@level = 0.5)
        def bump = (@level += 1)
        def restore = (@level ||= 0.5)

        def report
          l = @level
          puts "overflow" if l.is_a?(Float) && l > 1.0
        end
      end
    RUBY
  end

  it "still folds the condition when no `+=` can make the ivar `2.5`" do
    # Runtime: never prints; `@x` is `1` or `1.5`.
    expect(flow_rules(scale(:initialize, :shrink))).to eq(["flow.always-truthy-condition"])
  end
end
