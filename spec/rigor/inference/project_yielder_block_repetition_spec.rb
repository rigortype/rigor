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
        def self.with_while; i = 0; r = nil; while i < 3; r = yield(i); i += 1; end; r; end
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
    "a forward through a named &blk" => "Y.named([1, 2, 3])",
    "a callee that yields inside while" => "Y.with_while",
    "a callee that yields inside times" => "Y.with_times",
    "a callee that yields inside each_with_index" => "Y.with_index([1, 2, 3])",
    "an instance-method callee" => "K.new.last_val([1, 2, 3])"
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

  it "keeps the finding the single-run value supports (control)" do
    source = "#{helpers}count = 0\nr = Y.once { count += 1 }\nputs 'two' if r == 2\n"
    expect(always_truthy_lines(source)).to eq([helpers.lines.size + 3])
  end
end
