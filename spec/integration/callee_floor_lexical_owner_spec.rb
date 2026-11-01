# frozen_string_literal: true

# Issue #2522, #2521 (lever L1 of #2555) — a hand-off inside a callee resolves its receiver constant once, under the
# `Module.nesting` the declaration walk recorded for the def it sits in, and a def reached through an inherited lookup
# is walked: its self-calls resolve in the receiver's class, its constants in its own nesting.
require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"

RSpec.describe "the callee floor resolves a hand-off under the def's recorded nesting (#2522, #2521)", type: :runner do
  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }
  let(:writes) { 'def self.c(parser, options) = parser.on("--f") { |v| options[:format] = v }' }
  let(:reads) { "def self.c(parser, options) = puts(options.to_s)" }

  def caller_of(call, name: "Caller", tag: "json")
    <<~RUBY
      class #{name}
        def run(argv)
          options = { format: "text" }
          OptionParser.new { |opts| #{call} }.parse!(argv)
          if options[:format] == "#{tag}"
            puts "{}"
          end
        end
      end
    RUBY
  end

  # A top-level `Helper` and a `B::Helper`, and `B::Opts.a` handing its hash to the bare `Helper`, the class spelled
  # compactly (`class B::Opts`, Ruby reads `::Helper`) or nested (`module B; class Opts`, Ruby reads `B::Helper`).
  def spelled(top, inner, compact:)
    opts = "def self.a(parser, options) = Helper.c(parser, options)"
    header = compact ? "class B::Opts\n  #{opts}\nend" : "module B\n  class Opts\n    #{opts}\n  end\nend"
    "module Helper\n  #{top}\nend\nmodule B\n  module Helper\n    #{inner}\n  end\nend\n#{header}\n" \
      "#{caller_of('B::Opts.a(opts, options)')}"
  end

  describe "a compact class header" do
    it "follows the top-level Helper only, keeping the literal when it reads and B::Helper writes" do
      expect(rules(spelled(reads, writes, compact: true))).to eq(always)
    end

    it "floors when the top-level Helper writes (control)" do
      expect(rules(spelled(writes, reads, compact: true))).to eq([])
    end
  end

  describe "a nested class header" do
    it "follows B::Helper, flooring when it writes" do
      expect(rules(spelled(reads, writes, compact: false))).to eq([])
    end

    it "keeps the literal when B::Helper reads and the top-level Helper writes (control)" do
      expect(rules(spelled(writes, reads, compact: false))).to eq(always)
    end
  end

  describe "a def whose nesting was not recorded" do
    def unrecorded
      allow_any_instance_of(Rigor::Inference::StatementEvaluator) # rubocop:disable RSpec/AnyInstance
        .to receive(:recorded_def_nesting).and_return(nil)
    end

    it "takes the union of every spelling, flooring the compact header's B::Helper writer" do
      unrecorded
      expect(rules(spelled(reads, writes, compact: true))).to eq([])
    end
  end

  describe "a constant the innermost cref inherits" do
    def inherited(base_helper, top_helper)
      <<~RUBY
        class Base
          module Helper
            #{base_helper}
          end
        end
        module Helper
          #{top_helper}
        end
        class Opts < Base
          def self.a(parser, options) = Helper.c(parser, options)
        end
        #{caller_of('Opts.a(opts, options)')}
      RUBY
    end

    it "follows Base::Helper ahead of the top level, flooring when it writes" do
      expect(rules(inherited(writes, reads))).to eq([])
    end

    it "keeps the literal when Base::Helper reads and the top-level Helper writes (control)" do
      expect(rules(inherited(reads, writes))).to eq(always)
    end
  end

  # Issue #2521 — a def reached through an inherited lookup is not walked: every content parameter reads as
  # mutated. Walking it would expose the own-def census's blind spots (#2336), which the floor masks, so these pin
  # floors until the census covers them; flip the "only reads" rows when #2521 is lifted.
  describe "an inherited def floors without walking it (#2521, #2336)" do
    def inherited_program(base_body, sub_body = "", call: "Sub.new.run_it(opts, options)")
      "class Base\n#{base_body}\nend\nclass Sub < Base\n#{sub_body}\nend\n#{caller_of(call)}"
    end

    it "floors an inherited singleton method that only reads (flip when #2521 is lifted)" do
      base = "  def self.run_it(parser, options) = puts(options.to_s)"
      expect(rules(inherited_program(base, call: "Sub.run_it(opts, options)"))).to eq([])
    end

    it "floors an inherited instance method that only reads (flip when #2521 is lifted)" do
      expect(rules(inherited_program("  def run_it(parser, options) = puts(options.to_s)"))).to eq([])
    end

    it "keeps the literal when the receiver's own method only reads (control)" do
      sub = "  def run_it(parser, options) = puts(options.to_s)"
      expect(rules(inherited_program("  def other = nil", sub))).to eq(always)
    end

    it "floors an inherited def that writes through Hash#merge!, which the census does not count" do
      expect(rules(inherited_program('  def run_it(parser, options) = options.merge!(format: "json")'))).to eq([])
    end

    it "floors an inherited def whose override writes through a local alias" do
      base = "  def run_it(parser, options) = helper(parser, options)\n  " \
             "def helper(parser, options) = puts(options.to_s)"
      sub = "  def helper(parser, options)\n    other = options\n    other[:format] = \"json\"\n  end"
      expect(rules(inherited_program(base, sub))).to eq([])
    end

    it "floors an inherited def when the base's inherited hook defines the self-callee on the subclass" do
      base = "  def self.inherited(k)\n    super\n    " \
             "k.define_method(:helper) { |parser, options| options[:format] = \"json\" }\n  end\n  " \
             "def run_it(parser, options) = helper(parser, options)\n  def helper(parser, options) = puts(options.to_s)"
      expect(rules(inherited_program(base))).to eq([])
    end

    it "floors a self-call to an inherited mutator from the receiver's own method" do
      base = '  def helper(parser, options) = parser.on("--f") { |v| options[:format] = v }'
      sub = "  def run_it(parser, options) = helper(parser, options)"
      expect(rules(inherited_program(base, sub))).to eq([])
    end

    # Both round-3 probes of #2516: an override in `Y::Sub` reached from `X::Base.leaf`, and one base def reached
    # through two subclasses. Each floors, so neither can answer in the wrong owner.
    it "floors X::Base.leaf reached through Y::Sub whatever the helpers do" do
      program = <<~RUBY
        module X
          class Base
            def self.leaf(parser, options) = helper(parser, options)
            def self.helper(parser, options) = nil
          end
        end
        module Y
          module Helper
            #{reads}
          end
          class Sub < X::Base
            def self.helper(parser, options) = Helper.c(parser, options)
          end
        end
        #{caller_of('Y::Sub.leaf(opts, options)')}
      RUBY
      expect(rules(program)).to eq([])
    end

    it "floors Base.leaf for both subclass callers, in either order" do
      defs = "class Base\n  def self.leaf(parser, options) = helper(parser, options)\nend\n" \
             "class Sub1 < Base\n  def self.helper(parser, options) = puts(options.to_s)\nend\n" \
             "class Sub2 < Base\n  def self.helper(parser, options) = options[:format] = \"json\"\nend\n"
      one = caller_of("Sub1.leaf(opts, options)", name: "One", tag: "one")
      two = caller_of("Sub2.leaf(opts, options)", name: "Two", tag: "two")
      answers = [[one, two], [two, one]].map { |callers| rules([defs, *callers].join("\n")) }
      expect(answers).to eq([[], []])
    end
  end

  describe "a `class << self` def, whose cref is the singleton class (#2570 review)" do
    # `P::Helper` reads and the top-level `Helper` writes. `B < P`'s class-side defs reach `P::Helper` from a
    # `def self.` body (cref `B`) but the top-level `Helper` from a `class << self` body (cref `#<Class:B>`).
    def class_side(body, receiver: "B")
      "class P\n  module Helper\n    #{reads}\n  end\nend\nmodule Helper\n  #{writes}\nend\n" \
        "class B < P\n#{body}\nend\nclass Sub < B; end\n#{caller_of("#{receiver}.run_it(opts, options)")}"
    end

    let(:sclass) { "  class << self\n    def run_it(parser, options) = Helper.c(parser, options)\n  end" }

    it "keeps the prefix union, flooring through the top-level writer" do
      expect(rules(class_side(sclass))).to eq([])
    end

    it "floors an inherited `class << self` def without walking it" do
      expect(rules(class_side(sclass, receiver: "Sub"))).to eq([])
    end

    it "reads P::Helper from a `def self.` body and keeps the literal (control)" do
      expect(rules(class_side("  def self.run_it(parser, options) = Helper.c(parser, options)"))).to eq(always)
    end
  end

  describe "an own def that hands its parameter to super or method_missing (#2570 review)" do
    def direct(sub_body, base: '  def go(options) = options[:format] = "json"', call: "Sub.new.go(options)")
      <<~RUBY
        class Base
        #{base}
        end
        class Sub < Base
        #{sub_body}
        end
        class Caller
          def run
            options = { format: "text" }
            #{call}
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    end

    {
      "a named parameter to super(...)" => "  def go(options) = super(options)",
      "a named parameter to super inside a block" => "  def go(options)\n    [1].each { super(options) }\n  end",
      "a rest parameter to a zsuper" => "  def go(*args) = super",
      "a rest parameter to super(*args)" => "  def go(*args) = super(*args)",
      "an anonymous rest to super(*)" => "  def go(*) = super(*)",
      "every argument to super(...)" => "  def go(...) = super(...)"
    }.each do |shape, body|
      it "floors #{shape}" do
        expect(rules(direct(body))).to eq([])
      end
    end

    it "floors a self-call hop to an own override that hands its rest parameter to super" do
      sub = "  def run_it(options) = go(options)\n  def go(*args) = super"
      expect(rules(direct(sub, call: "Sub.new.run_it(options)"))).to eq([])
    end

    it "floors a keyword rest parameter handed to a zsuper" do
      base = '  def go(h:) = h[:format] = "json"'
      expect(rules(direct("  def go(**kw) = super", base: base, call: "Sub.new.go(h: options)"))).to eq([])
    end

    it "keeps the literal when the override hands super nothing (control)" do
      expect(rules(direct("  def go(*args) = super()"))).to eq(always)
    end

    it "floors a self-call no def answers when the class defines method_missing" do
      sub = "  def go(options) = helper(options)\n  " \
            "def method_missing(name, options) = (options[:format] = \"json\")\n  def respond_to_missing?(*) = true"
      expect(rules(direct(sub, base: "  def other = nil"))).to eq([])
    end

    it "floors an explicit-receiver call no def answers when the receiver class defines method_missing" do
      sub = "  def method_missing(name, options) = (options[:format] = \"json\")\n  def respond_to_missing?(*) = true"
      expect(rules(direct(sub, base: "  def other = nil", call: "Sub.new.helper(options)"))).to eq([])
    end

    it "keeps the literal for that self-call without method_missing (control)" do
      expect(rules(direct("  def go(options) = helper(options)", base: "  def other = nil"))).to eq(always)
    end
  end

  describe "a project split across files" do
    around do |example|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end

    def check(*flags)
      out = StringIO.new
      argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--format", "json", *flags]
      Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: StringIO.new).run
      JSON.parse(out.string).fetch("diagnostics").map do |d|
        "#{File.basename(d.fetch('path'))}:#{d.fetch('line')} #{d.fetch('rule')}"
      end.sort
    end

    it "answers as one file does, with workers and on a warm incremental recheck after an edit" do
      File.write(".rigor.yml", "paths:\n  - lib\n")
      FileUtils.mkdir_p("lib")
      File.write("lib/helpers.rb",
                 "module Helper\n  #{reads}\nend\nmodule B\n  module Helper\n    #{writes}\n  end\nend\n")
      hand_off = "def self.a(parser, options) = Helper.c(parser, options)"
      File.write("lib/opts.rb", "class B::Opts\n  #{hand_off}\nend\n" \
                                "module B\n  class Nested\n    #{hand_off}\n  end\nend\n")
      File.write("lib/callers.rb", caller_of("B::Opts.a(opts, options)", name: "One") +
                                   caller_of("B::Nested.a(opts, options)", name: "Two"))
      cold = check("--no-cache")
      expect(cold).to eq(["callers.rb:5 flow.always-truthy-condition"])
      expect(check("--no-cache", "--workers=2")).to eq(cold)
      2.times { check("--incremental") }
      File.write("lib/callers.rb", "#{File.read('lib/callers.rb')}# edited\n")
      expect(check("--incremental")).to eq(cold)
      expect(check).to eq(cold)
    end
  end
end
