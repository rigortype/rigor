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

  def always_truthy_rules(source)
    result = analyze(source)
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.rule if diagnostic.rule.to_s == "flow.always-truthy-condition"
    end
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

    it "answers each call site through the forward with its own block" do
      answers = ["'a'", "1", ":x"].map { |value| dumped_type("#{helpers}dump_type(M.anon([1]) { |_| #{value} })") }
      expect(answers).to eq([%("a"?), "1?", ":x?"])
    end

    it "feeds the forwarded block to an RBS-dispatched callee" do
      source = "module F\n  def self.mapper(arr, &) = arr.map(&)\nend\ndump_type(F.mapper([1]) { |_| 'a' })"
      expect(dumped_type(source)).to eq(%(Array["a"]))
    end

    # The forward's target may run the block many times, so a local the block rebinds is not its entry binding:
    # `count += 1` reaches 3 here, and reading it as `1` folded `a == 3` to always-falsey.
    it "reports nothing on a block value a forwarding callee's target runs repeatedly" do
      expect(always_truthy_rules(<<~RUBY)).to eq([])
        module Y
          def self.last_val(entries); v = nil; entries.each { |e| v = yield(e) }; v; end
          def self.anon(entries, &) = last_val(entries, &)
        end
        def probe
          count = 0
          a = Y.anon([1, 2, 3]) { |_| count += 1 }
          puts "three" if a == 3
        end
      RUBY
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

    # A block in expression position is never entered by the statement walk, so the tail-only pass is the only walk
    # that reaches its `return`, and its record must stand.
    describe "for a block in expression position" do
      let(:expression_source) do
        <<~RUBY
          module U
            def self.element(arr) = [arr.each { |e| return :early if e }]
            def self.receiver(arr) = arr.each { |e| return :early if e }.size
            def self.endless(arr) = arr.find { |e| return :early if e }.to_i
            def self.argument(entries)
              log(entries.each { |e| x = 1; return e if e })
            end
            def self.log(_x) = nil
          end
        RUBY
      end

      {
        "an array element" => ["U.element([1])", ":early | [Array[Integer]]"],
        "a chain receiver" => ["U.receiver([1])", ":early | non-negative-int"],
        "an endless-def body" => ["U.endless([1])", "0 | :early | Integer"],
        "a call argument" => ["U.argument([1])", "1?"]
      }.each do |position, (call, expected)|
        it "keeps the early return from #{position}" do
          expect(dumped_type("#{expression_source}dump_type(#{call})")).to eq(expected)
        end
      end

      it "reports nothing on a value only the early return can produce" do
        expect(always_truthy_rules(<<~RUBY)).to eq([])
          module V
            def self.first_sym(arr)
              log(arr.each { |e| return e if e.is_a?(Symbol) })
              nil
            end
            def self.log(_x) = nil
          end
          r = V.first_sym([1, :a])
          puts r.to_proc.call("x") if r
        RUBY
      end
    end
  end
end
