# frozen_string_literal: true

require "spec_helper"

# Issue #1155 — `x = (tbl[k] ||= {})`. A `||=` whose `[]` read is wholly gradual is the memoization idiom, and the
# value-position typer reads it as the rvalue (`StatementEvaluator#index_compound_write_value`). The statement
# evaluator, which binds the local `x` and types a chain off it, used the union `Dynamic | {}` instead, so the next
# level's `x[m] ||= v` read a `Dynamic | {}` receiver (a union WITH a Dynamic member, no longer wholly gradual) and
# the memoized value surfaced as `Dynamic | v`. That untyped arm sent a class-ivar memo table's reader to
# `sig.skipped.untyped-return`.
RSpec.describe "index `||=` bound to a local (memoization idiom)", type: :runner do
  def dumped_type(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end.first
  end

  it "binds the local to the rvalue when the slot read is wholly gradual" do
    # Runtime: the slot is absent, so `x` is the new `{}`.
    expect(dumped_type(<<~RUBY)).to eq("{}")
      class Memo
        class << self
          def table(key)
            x = (@memo[key] ||= {})
            dump_type(x)
          end
        end
        @memo = {}
      end
    RUBY
  end

  it "types the second level of a two-level memo table as the rvalue (guard: value position already did)" do
    # Runtime: the leaf is the new `Object`.
    expect(dumped_type(<<~RUBY)).to eq("Object")
      class Memo
        class << self
          def leaf(a, b)
            by_a = (@memo[a] ||= {})
            dump_type(by_a[b] ||= Object.new)
          end
        end
        @memo = {}
      end
    RUBY
  end

  it "keeps the union when the slot read is typed (control)" do
    # Runtime: `x` is `1` or `2`; the slot read is typed, so no memo reading applies.
    expect(dumped_type(<<~RUBY)).to eq("1 | 2")
      def pick(flag)
        h = flag ? { a: 1 } : { a: nil }
        x = (h[:a] ||= 2)
        dump_type(x)
      end
    RUBY
  end
end
