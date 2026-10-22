# frozen_string_literal: true

require "spec_helper"

# Issue #1157 / #2299 — two ways a block-taking helper's return read `Dynamic[top]` although every exit was typed.
#
# 1. A method that hands its own block on (`g(x, &)`, `g(x, &blk)`) gave the callee's `yield` no value, because
#    only a literal block or a `yield` carried the caller's block type through user-method inference.
# 2. The block-return pass re-types a block body's LAST statement alone; a `return r if r` there read `r` unbound
#    (`Dynamic[top]`) and filed that as one of the ENCLOSING method's returns.
RSpec.describe "forwarded block yield type", type: :runner do
  def dumped_type(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end.first
  end

  let(:helpers) do
    <<~RUBY
      module M
        def self.first(entries)
          entries.each { |e| r = yield e; return r if r }
          nil
        end

        def self.anon(entries, &) = first(entries, &)

        def self.named(entries, &blk) = first(entries, &blk)

        def self.rebound(entries, &blk)
          blk = proc { |_| 1 }
          first(entries, &blk)
        end

        def self.shadowed(entries, &blk)
          [1].each { |blk| blk }
          first(entries, &blk)
        end
      end
    RUBY
  end

  describe "a forwarded block" do
    it "gives the callee's yield the caller's block type through an anonymous &" do
      expect(dumped_type("#{helpers}dump_type(M.anon([1]) { |_| 'a' })")).not_to include("Dynamic")
    end

    it "gives the callee's yield the caller's block type through a named &blk" do
      expect(dumped_type("#{helpers}dump_type(M.named([1]) { |_| 'a' })")).not_to include("Dynamic")
    end

    it "types the forward exactly as a literal block would" do
      forwarded = dumped_type("#{helpers}dump_type(M.anon([1]) { |_| 'a' })")
      literal = dumped_type("#{helpers}dump_type(M.first([1]) { |_| 'a' })")
      expect(forwarded).to eq(literal)
    end

    it "keeps a rebound &blk untyped (control: the block is no longer the caller's)" do
      expect(dumped_type("#{helpers}dump_type(M.rebound([1]) { |_| 'a' })")).to include("Dynamic")
    end

    it "keeps a &blk shadowed by a block parameter untyped (control)" do
      expect(dumped_type("#{helpers}dump_type(M.shadowed([1]) { |_| 'a' })")).to include("Dynamic")
    end
  end

  describe "the tail-only block-return pass" do
    let(:loop_source) do
      <<~'RUBY'
        module N
          def self.hit(o)
            [o].each { |e| r = yield e; return r if r }
            nil
          end

          def self.via(name)
            owner = "x"
            name.split("::").each { |seg| next if seg.empty?; owner = hit(seg) { |a| "#{a}!" } }
            owner
          end

          def self.typed_return(name)
            [name].each { |e| r = e.to_s; return r if r }
            nil
          end
        end
      RUBY
    end

    it "does not widen the callee's return to Dynamic through a next-bearing loop" do
      expect(dumped_type("#{loop_source}dump_type(N.via('a::b'))")).not_to include("Dynamic")
    end

    it "still records a real return with a typed value (control)" do
      expect(dumped_type("#{loop_source}dump_type(N.typed_return('a'))")).to eq(%("a"?))
    end
  end
end
