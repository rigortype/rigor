# frozen_string_literal: true

require "spec_helper"

# Issue #3338 — argument-free `Array#pop` on a receiver proven non-empty answers the element type.
#
# Core RBS spells `pop: () -> E?`, while `shift` / `first` / `last` / `sample` carry `%a{implicitly-returns-nil}`
# and so already read `E`. After `return if xs.empty?` the receiver is `non-empty-array[E]` (ADR-47 §4-4), so
# `xs.pop` removes an element that is there. The worklist loop `until stack.empty?; node = stack.pop; node.foo`
# reported `call.possible-nil-receiver` on correct code.
#
# Every example below was checked against Ruby 4.0.5: `["a"].pop` is `"a"`, a second `pop` is `nil`, and
# `["a", "b"].pop(1)` is `["b"]`.
RSpec.describe "Array#pop on non-empty-array", type: :runner do
  def dumps(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def nil_receiver_lines(source)
    analyze(source).diagnostics.filter_map do |diagnostic|
      diagnostic.line if diagnostic.rule == "call.possible-nil-receiver"
    end
  end

  it "answers the element type for `pop` after an `empty?` guard" do
    source = <<~RUBY
      def f
        xs = gets.to_s.chars
        return if xs.empty?
        dump_type(xs.pop)
      end
    RUBY
    expect(dumps(source)).to eq(["String"])
  end

  it "answers the element type on the true edge of `any?`" do
    source = <<~RUBY
      def f
        xs = gets.to_s.chars
        dump_type(xs.pop) if xs.any?
      end
    RUBY
    expect(dumps(source)).to eq(["String"])
  end

  # The refinement describes the content: the first `pop` may have emptied the array.
  it "reads a second `pop` as nilable again" do
    source = <<~RUBY
      def f
        xs = gets.to_s.chars
        return if xs.empty?
        dump_type(xs.pop)
        dump_type(xs.pop)
      end
    RUBY
    expect(dumps(source)).to eq(%w[String String?])
  end

  # `shift` drops the refinement too; its own non-nil answer is the `%a{implicitly-returns-nil}` read, which
  # does not depend on the refinement, so the `pop` after it is the observable.
  it "reads `pop` after a `shift` as nilable" do
    source = <<~RUBY
      def f
        xs = gets.to_s.chars
        return if xs.empty?
        xs.shift
        dump_type(xs.pop)
      end
    RUBY
    expect(dumps(source)).to eq(["String?"])
  end

  it "leaves `pop(n)` answering an array" do
    source = <<~RUBY
      def f
        xs = gets.to_s.chars
        return if xs.empty?
        dump_type(xs.pop(1))
      end
    RUBY
    expect(dumps(source)).to eq(["Array[String]"])
  end

  it "keeps `pop` nilable on an unrefined array" do
    source = <<~RUBY
      def f
        xs = gets.to_s.chars
        dump_type(xs.pop)
      end
    RUBY
    expect(dumps(source)).to eq(["String?"])
  end

  it "keeps the nilable member's `nil` in a union with an unrefined array" do
    source = <<~RUBY
      def f(flag)
        xs = gets.to_s.chars
        ints = gets.to_s.bytes
        return if xs.empty?
        u = flag ? xs : ints
        dump_type(u.pop)
      end
    RUBY
    expect(dumps(source)).to eq(["Integer | String | nil"])
  end

  it "keeps `&.pop` on a nilable non-empty array nilable" do
    source = <<~RUBY
      def f(flag)
        xs = gets.to_s.chars
        return if xs.empty?
        y = flag ? xs : nil
        dump_type(y&.pop)
      end
    RUBY
    expect(dumps(source)).to eq(["String?"])
  end

  it "leaves a literal tuple's `pop` unchanged" do
    expect(dumps("dump_type([1].pop)")).to eq(["1?"])
  end

  it "reports no possible-nil receiver in the worklist loop" do
    source = <<~RUBY
      def f
        stack = gets.to_s.chars
        until stack.empty?
          node = stack.pop
          node.upcase
          stack.concat(node.chars) if node.size > 1
        end
      end
    RUBY
    expect(nil_receiver_lines(source)).to be_empty
  end

  it "still reports the receiver of an unguarded `pop`" do
    source = <<~RUBY
      def f
        xs = gets.to_s.chars
        node = xs.pop
        node.upcase
        nil
      end
    RUBY
    expect(nil_receiver_lines(source)).to eq([4])
  end
end
