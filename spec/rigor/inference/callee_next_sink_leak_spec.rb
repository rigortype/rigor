# frozen_string_literal: true

require "spec_helper"

# ADR-129 WD1 (PR #2868) — a callee body re-typed for its return starts outside its caller's jump sinks. A recursive
# call inside the caller's own block re-walks that block, and its `next` used to land in the outer walk's `next` sink,
# whose consumer accepts it by node identity: the outer block's value gained the recursive call's arm. Ruby never runs
# that `next` for the outer block, so the arm was spurious.
RSpec.describe "a callee's `next` inside a recursive call", type: :runner do
  def dumped_type(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end.first
  end

  it "keeps the recursive call's `next` out of the caller's block value" do
    type = dumped_type(<<~RUBY)
      class P
        def f(n) = [1].map { |y| next n if y > 0; f(:sym) }
      end
      dump_type(P.new.f(1))
    RUBY

    expect(type).to eq("[1 | Dynamic[top]]")
    expect(type).not_to include(":sym")
  end

  it "keeps a `next` carrying an array out of it too" do
    type = dumped_type(<<~RUBY)
      class P
        def g(n) = [1].map { |y| next [n] if y > 0; n == 1 ? g(:sym) : 0 }
      end
      dump_type(P.new.g(1))
    RUBY

    expect(type).not_to include(":sym")
    expect(type).to eq("[Dynamic[top] | [1]]")
  end
end
