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

  it "binds the local to the rvalue's class when the slot read is wholly gradual" do
    # Runtime: the slot is absent, so `x` is the new `{}`; the literal shape is erased because the table is not
    # empty after the first store.
    expect(dumped_type(<<~RUBY)).to eq("Hash[Dynamic[top], Dynamic[top]]")
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

  # S1 (PR #2288 review): the rvalue's literal precision must not leak into later reads of a slot another call filled.
  describe "later reads of the bound local (no false positives)" do
    def diagnostics_for(body)
      analyze(body).diagnostics.reject { |d| d.severity.to_s == "info" }.map { |d| [d.rule, d.message] }
    end

    {
      "a hash filled elsewhere" => <<~RUBY,
        class Registry
          def initialize = (@by_owner = {})
          def register(owner, name) = ((@by_owner[owner] ||= {})[:name] = name)
          def name_of(owner)
            entry = (@by_owner[owner] ||= {})
            entry[:name].upcase
          end
        end
      RUBY
      "an array memo" => "def top(ctx)\n  stack = ctx[:stack] ||= []\n  stack.last.size\nend\n",
      "a scalar rvalue" => "def a(h, k)\n  x = (h[k] ||= 1)\n  x.upcase\nend\n",
      "a nested scalar" => "def b(h, k)\n  x = (h[k] ||= {})\n  y = (x[:j] ||= 1)\n  y.upcase\nend\n",
      "an array first" => "def c(h, k)\n  x = (h[k] ||= [])\n  x.first.upcase\nend\n",
      "a symbol rvalue" => "def d(h, k)\n  x = (h[k] ||= :a)\n  1 if x == :b\nend\n"
    }.each do |label, source|
      it "reports nothing for #{label}" do
        expect(diagnostics_for(source)).to eq([])
      end
    end
  end
end
