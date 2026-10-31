# frozen_string_literal: true

# Issue #2515 — the callee floor of #2510 followed `Const.name(local)` to a singleton callee only. It now also follows
# an instance method on a project-class receiver, a hand-off inside the callee to a constant / `Const.new` receiver,
# and a singleton method inherited from a project superclass.
require "spec_helper"

RSpec.describe "the callee floor follows instance receivers, chained hand-offs and inherited singletons (#2515)", type: :runner do
  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }
  let(:writer) { 'parser.on("--format=FORMAT") { |value| options[:format] = value }' }
  let(:reader) { "puts(options.to_s)" }

  # `defs` is the callee class body; `call` is the statement in `Help#run`, with `options` a hash literal.
  def program(defs, call, extra: "")
    <<~RUBY
      #{extra}
      #{defs}
      class Help
        def run(argv)
          options = { format: "text" }
          #{call}
          if options[:format] == "json"
            puts "{}"
          else
            puts "text"
          end
        end
      end
    RUBY
  end

  def in_block(call) = "OptionParser.new { |opts| #{call} }.parse!(argv)"

  describe "instance method on a receiver" do
    let(:klass) { "class Opts\n  def add_format(parser, options) = #{writer}\nend" }

    it "called on Const.new" do
      expect(rules(program(klass, in_block("Opts.new.add_format(opts, options)")))).to eq([])
    end

    it "called on a local holding an instance" do
      call = "helper = Opts.new\n    #{in_block('helper.add_format(opts, options)')}"
      expect(rules(program(klass, call))).to eq([])
    end

    it "when the instance method delegates to a helper that writes" do
      defs = "class Opts\n  def add_format(parser, options) = really(parser, options)\n" \
             "  def really(parser, options) = #{writer}\nend"
      expect(rules(program(defs, in_block("Opts.new.add_format(opts, options)")))).to eq([])
    end

    it "keeps the literal when the instance callee only reads" do
      defs = "class Opts\n  def add_format(parser, options) = #{reader}\nend"
      expect(rules(program(defs, in_block("Opts.new.add_format(opts, options)")))).to eq(always)
    end

    it "keeps the literal when the receiver type is unknown" do
      call = in_block("opts.add_format(opts, options)")
      expect(rules(program(klass, call))).to eq(always)
    end

    it "reads the instance def, not a same-named singleton that writes" do
      defs = "class Opts\n  def add_format(parser, options) = #{reader}\n" \
             "  def self.add_format(parser, options) = #{writer}\nend"
      expect(rules(program(defs, in_block("Opts.new.add_format(opts, options)")))).to eq(always)
    end
  end

  describe "a chained hand-off inside the callee" do
    let(:help) { "module HelpC\n  def self.c(parser, options) = #{writer}\nend" }

    it "to a constant receiver" do
      defs = "class Opts\n  def self.a(parser, options) = b(parser, options)\n" \
             "  def self.b(parser, options) = HelpC.c(parser, options)\nend"
      expect(rules(program(defs, in_block("Opts.a(opts, options)"), extra: help))).to eq([])
    end

    it "to a callee that writes through its own self-call helper" do
      defs = "class Opts\n  def self.a(parser, options) = HelpC.c(parser, options)\nend"
      extra = "module HelpC\n  def self.c(parser, options) = really(parser, options)\n" \
              "  def self.really(parser, options) = #{writer}\nend"
      expect(rules(program(defs, in_block("Opts.a(opts, options)"), extra: extra))).to eq([])
    end

    it "to an instance receiver built with Const.new" do
      defs = "class Opts\n  def self.a(parser, options) = HelpI.new.c(parser, options)\nend"
      extra = "class HelpI\n  def c(parser, options) = #{writer}\nend"
      expect(rules(program(defs, in_block("Opts.a(opts, options)"), extra: extra))).to eq([])
    end

    it "terminates across classes that hand off to each other" do
      defs = "class Opts\n  def self.a(parser, options) = Other.a(parser, options)\nend"
      extra = "class Other\n  def self.a(parser, options) = Opts.a(parser, options)\nend"
      expect(rules(program(defs, in_block("Opts.a(opts, options)"), extra: extra))).to eq(always)
    end

    it "keeps the literal when the far callee only reads" do
      defs = "class Opts\n  def self.a(parser, options) = HelpC.c(parser, options)\nend"
      extra = "module HelpC\n  def self.c(parser, options) = #{reader}\nend"
      expect(rules(program(defs, in_block("Opts.a(opts, options)"), extra: extra))).to eq(always)
    end
  end

  describe "a singleton method inherited from a project superclass" do
    let(:base) { "class Base\n  def self.add_format(parser, options) = #{writer}\nend\nclass Opts < Base\nend" }

    it "is followed" do
      expect(rules(program(base, in_block("Opts.add_format(opts, options)")))).to eq([])
    end

    it "keeps the literal when the inherited method only reads" do
      defs = "class Base\n  def self.add_format(parser, options) = #{reader}\nend\nclass Opts < Base\nend"
      expect(rules(program(defs, in_block("Opts.add_format(opts, options)")))).to eq(always)
    end
  end
end
