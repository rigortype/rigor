# frozen_string_literal: true

# ADR-127 WD3 — the callee floor does not depend on the order the file's defs are written in. Each program is cut into
# units (top-level classes, or the defs of one class), the units are laid out in many orders, and every layout must
# report the same diagnostics. The memo audit runs throughout, so a memo key that misses an input fails on its first
# hit.
require "spec_helper"

RSpec.describe "the callee floor is independent of def order (ADR-127)", type: :runner do
  around do |example|
    Rigor::Inference::MemoAudit.enable!
    example.run
  ensure
    Rigor::Inference::MemoAudit.disable!
  end

  # Diagnostics as `[rule, source line]`, so a layout that moves a line does not change what is compared.
  def findings(source)
    lines = source.lines
    analyze(source).diagnostics.reject { |d| d.severity == :info }
                   .map { |d| [d.qualified_rule, lines[d.line - 1].to_s.strip] }.sort
  end

  # Every layout of up to three units, otherwise the identity, the reverse, a half rotation and a seeded sample.
  def layouts(units)
    return units.permutation.to_a if units.size <= 3

    random = Random.new(127)
    [units, units.reverse, units.rotate(units.size / 2), *Array.new(4) { units.shuffle(random: random) }].uniq
  end

  def assert_one_answer(units, wrap: ->(body) { body })
    answers = layouts(units).map { |layout| findings(wrap.call(layout.join("\n"))) }
    expect(answers.uniq.size).to eq(1)
    answers.first
  end

  def helper_module(name, body)
    "module #{name}\n  module Helper\n    #{body}\n  end\nend"
  end

  def mut_class(defs)
    "class Mut\n#{defs}\nend"
  end

  let(:head_of) { "def head_of(acc) = acc[0]" }

  def run_method(name, call)
    "def #{name}\n  acc = [7, 9]\n  #{call}\n  head_of(acc).upcase # #{name}\nend"
  end

  it "answers the a/b witness the same in every def order (a: 70 leaves, b: 40 of the same)" do
    leaves = (1..70).map { |i| "def leaf#{i}(x) = x.size" }
    units = [
      head_of, run_method("run_a", "a(acc)"), run_method("run_b", "b(acc)"),
      "def a(x) = (#{(1..70).map { |i| "leaf#{i}(x)" }.join('; ')})",
      "def b(x) = (#{(1..40).map { |i| "leaf#{i}(x)" }.join('; ')})",
      leaves.join("\n")
    ]
    found = assert_one_answer(units, wrap: ->(body) { mut_class(body) })
    # `a` reaches 71 nodes (floored by the cut), `b` 41 (the literal keeps its facts).
    expect(found).to eq([["call.undefined-method", "head_of(acc).upcase # run_b"]])
  end

  it "answers a forty-leaf read-only fan-out the same in every def order (#2520)" do
    units = [
      head_of, run_method("run", "stripes(acc)"),
      "def stripes(acc) = (#{(1..40).map { |i| "leaf#{i}(acc)" }.join('; ')})",
      (1..40).map { |i| "def leaf#{i}(acc) = acc.size" }.join("\n")
    ]
    found = assert_one_answer(units, wrap: ->(body) { mut_class(body) })
    expect(found).to eq([["call.undefined-method", "head_of(acc).upcase # run"]])
  end

  it "answers a fan-out that ends in one writer the same in every def order" do
    units = [
      head_of, run_method("run", "stripes(acc)"),
      "def stripes(acc) = (#{(1..40).map { |i| "leaf#{i}(acc)" }.join('; ')})",
      (1..39).map { |i| "def leaf#{i}(acc) = acc.size" }.join("\n"),
      'def leaf40(acc) = (acc[0] = "x")'
    ]
    expect(assert_one_answer(units, wrap: ->(body) { mut_class(body) })).to eq([])
  end

  it "answers the #2516 namespaced hand-off the same in every unit order" do
    units = %w[A B].map do |ns|
      <<~RUBY
        module #{ns}
          class Caller#{ns}
            def run(argv)
              options = { format: "text" }
              OptionParser.new { |opts| B::Opts.a(opts, options) }.parse!(argv)
              if options[:format] == "json" # cond#{ns}
                puts "{}"
              end
            end
          end
        end
      RUBY
    end
    units << helper_module("A", "def self.c(parser, options) = parser.on('--f') { |v| options[:format] = v }")
    units << helper_module("B", "def self.c(parser, options) = puts(options.to_s)")
    units << "module B\n  class Opts\n    def self.a(parser, options) = Helper.c(parser, options)\n  end\nend"
    found = assert_one_answer(units)
    expect(found.map(&:first)).to eq(["flow.always-truthy-condition"] * 2)
  end

  def narrowed_units
    [
      'require "optparse"',
      "class Helper\n  def c(parser, options) = parser.on('--f F') { |v| options[:format] = v }\nend",
      "class SubHelper < Helper\nend",
      "INST = Helper.new",
      "class Wrap\n  def self.a(parser, options) = INST.c(parser, options)\nend",
      <<~RUBY,
        class Caller
          def first(argv)
            o = { format: "text" }
            if INST.is_a?(SubHelper)
              OptionParser.new { |p| Wrap.a(p, o) }.parse!(argv)
            end
            o
          end
        end
      RUBY
      <<~RUBY
        class Caller
          def second(argv)
            options = { format: "text" }
            OptionParser.new { |p| Wrap.a(p, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    ]
  end

  it "answers the #2524 narrowed-constant program the same in every unit order" do
    expect(assert_one_answer(narrowed_units)).to eq([])
  end
end
