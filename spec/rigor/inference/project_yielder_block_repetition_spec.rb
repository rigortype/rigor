# frozen_string_literal: true

require "spec_helper"

# Issue #2303 — a literal block in expression position passed to a PROJECT method that yields inside a loop or a
# block was typed as a single run: `count += 1` read its entry binding, the block's value was `1`, and a caller's
# `a == 3` folded to always-falsey although Ruby runs the block three times. The block-value pass now asks
# `ProjectYielder` whether the callee may run the block more than once; a callee that yields once keeps the precise
# single-run value.
RSpec.describe "project yielder block repetition", type: :runner do
  def always_truthy_lines(source = nil, files: {})
    result = files.empty? ? analyze(source) : analyze(files: files)
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.line if diagnostic.rule.to_s == "flow.always-truthy-condition"
    end
  end

  def dumped_type(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end.first
  end

  let(:helpers) do
    <<~RUBY
      module Y
        def self.last_val(entries); v = nil; entries.each { |e| v = yield(e) }; v; end
        def self.named(entries, &blk) = last_val(entries, &blk)
        def self.dotted(...) = last_val(...)
        def self.with_times; r = nil; 3.times { |i| r = yield(i) }; r; end
        def self.with_index(xs); r = nil; xs.each_with_index { |x, _i| r = yield(x) }; r; end
        def self.once; yield(1); end
        def self.maybe_once(x); yield(x) if x; end
      end

      class K
        def last_val(entries); v = nil; entries.each { |e| v = yield(e) }; v; end
      end
    RUBY
  end

  {
    "a callee that yields inside an iterator block" => "Y.last_val([1, 2, 3])",
    "a callee that yields inside times" => "Y.with_times",
    "a callee that yields inside each_with_index" => "Y.with_index([1, 2, 3])",
    "an instance-method callee" => "K.new.last_val([1, 2, 3])",
    "a forward through a named &blk" => "Y.named([1, 2, 3])",
    # A guard: a `...` forward does not carry the block's value to the caller today, so nothing observes the count.
    "a forward through ... (guard)" => "Y.dotted([1, 2, 3])"
  }.each do |callee, call|
    it "reports nothing on the value of a block #{callee} runs repeatedly" do
      source = "#{helpers}count = 0\na = #{call} { |_| count += 1 }\nputs 'three' if a == 3\n"
      expect(always_truthy_lines(source)).to eq([])
    end
  end

  it "reports nothing when the repeating callee is defined in another file" do
    files = {
      "lib.rb" => "module Z\n  def self.last_val(xs); v = nil; xs.each { |e| v = yield(e) }; v; end\nend\n",
      "main.rb" => "count = 0\na = Z.last_val([1, 2, 3]) { |_| count += 1 }\nputs 'three' if a == 3\n"
    }
    expect(always_truthy_lines(files: files)).to eq([])
  end

  it "keeps the precise single-run value of a block a callee yields to once" do
    expect(dumped_type("#{helpers}count = 0\ndump_type(Y.once { count += 1 })")).to eq("1")
  end

  it "keeps the precise single-run value of a block a callee yields to at most once" do
    expect(dumped_type("#{helpers}count = 0\ndump_type(Y.maybe_once(true) { count += 1 })")).to eq("1")
  end

  # A callee that runs the block once on every path must keep the single run: the cross-run binding adds the `nil`
  # a later run would read, and `r.upcase` was reported a possible nil receiver on correct code.
  describe "a callee that runs the block at most once per path" do
    let(:once_helpers) do
      <<~RUBY
        class Lock
          def tapper; 1.then { yield }; end
          def locked; Mutex.new.synchronize { yield }; end
          def cased(k); case k; when 1 then yield(:a) else yield(:b) end; end
          def matched(k); case k; in Integer then yield(:a) else yield(:b) end; end
          def early(k); return yield(1) if k; yield(2); end
          def raising(k); raise ArgumentError unless k; yield(1); end
          def guarded(&blk); return "z" unless blk; yield; end
          def branched(f); if f then yield(1) else yield(2) end; end
          def unlessed(f); unless f then yield(1) else yield(2) end; end
        end
        module R; def self.either(f); f ? yield(1) : yield(2); end; end
      RUBY
    end

    # A helper that does not parse would let every "reports nothing" example pass with no analysis behind it.
    it "parses both helper sets (guard)" do
      expect(Prism.parse(helpers + once_helpers).errors).to be_empty
    end

    def nil_receiver_lines(source)
      analyze(source).diagnostics.filter_map { |d| d.line if d.rule.to_s == "call.possible-nil-receiver" }
    end

    {
      "a yield in a then block" => "Lock.new.tapper",
      "a yield in a synchronize block" => "Lock.new.locked",
      "case/when arms" => "Lock.new.cased(1)",
      "case/in arms" => "Lock.new.matched(1)",
      "a return yield before a yield" => "Lock.new.early(true)",
      "a &blk read before a yield" => "Lock.new.guarded",
      "if/else arms" => "Lock.new.branched(true)",
      "unless/else arms" => "Lock.new.unlessed(true)",
      "ternary arms" => "R.either(true)"
    }.each do |shape, call|
      it "reports no possible nil receiver on a block value through #{shape}" do
        source = "#{once_helpers}s = 'a'\nr = #{call} { t = s; s = nil; t }\nputs r.upcase\n"
        expect(nil_receiver_lines(source)).to eq([])
      end
    end

    # A guard: the raise ends its path, but its argument holds no run, so the walk counts one either way.
    it "reports no possible nil receiver through a raise before the yield (guard)" do
      source = "#{once_helpers}s = 'a'\nr = Lock.new.raising(true) { t = s; s = nil; t }\nputs r.upcase\n"
      expect(nil_receiver_lines(source)).to eq([])
    end

    it "keeps the always-truthy finding through ternary arms" do
      source = "#{once_helpers}c = 0\nr = R.either(true) { c += 1 }\nputs 'one' if r == 1\n"
      expect(always_truthy_lines(source)).to eq([once_helpers.lines.size + 3])
    end
  end

  it "keeps the finding the single-run value supports (control)" do
    source = "#{helpers}count = 0\nr = Y.once { count += 1 }\nputs 'two' if r == 2\n"
    expect(always_truthy_lines(source)).to eq([helpers.lines.size + 3])
  end
end
