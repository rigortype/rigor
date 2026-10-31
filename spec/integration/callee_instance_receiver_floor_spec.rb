# frozen_string_literal: true

# Issue #2515 — the callee floor of #2510 followed `Const.name(local)` to a singleton callee only. It now also follows
# an instance method on a project-class receiver, a hand-off inside the callee to a constant / `Const.new` receiver,
# and a singleton method inherited from a project superclass.
require "spec_helper"

RSpec.describe "the callee floor follows instance receivers, chained hand-offs and inherited singletons (#2515)",
               type: :runner do
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
      defs = "class Opts\n  def add_format(parser, options) = really(parser, options)\n  " \
             "def really(parser, options) = #{writer}\nend"
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
      defs = "class Opts\n  def add_format(parser, options) = #{reader}\n  " \
             "def self.add_format(parser, options) = #{writer}\nend"
      expect(rules(program(defs, in_block("Opts.new.add_format(opts, options)")))).to eq(always)
    end
  end

  describe "a chained hand-off inside the callee" do
    let(:help) { "module HelpC\n  def self.c(parser, options) = #{writer}\nend" }

    it "to a constant receiver" do
      defs = "class Opts\n  def self.a(parser, options) = b(parser, options)\n  " \
             "def self.b(parser, options) = HelpC.c(parser, options)\nend"
      expect(rules(program(defs, in_block("Opts.a(opts, options)"), extra: help))).to eq([])
    end

    it "to a callee that writes through its own self-call helper" do
      defs = "class Opts\n  def self.a(parser, options) = HelpC.c(parser, options)\nend"
      extra = "module HelpC\n  def self.c(parser, options) = really(parser, options)\n  " \
              "def self.really(parser, options) = #{writer}\nend"
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

# Issue #2515 review — a hand-off's constants resolve where the callee is written, not where it was called from.
RSpec.describe "a hand-off inside a callee resolves its constants in the callee's own nesting (#2515)", type: :runner do
  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }
  let(:writes) { 'def self.c(parser, options) = parser.on("--f") { |v| options[:format] = v }' }
  let(:reads) { "def self.c(parser, options) = puts(options.to_s)" }

  # `A::Helper` and `B::Helper` each define `c`; `B::Opts.a` hands to the bare `Helper` of its own nesting. The caller
  # classes sit in `callers`' namespaces, each calling `B::Opts.a` with a hash literal.
  def program(a_helper, b_helper, callers)
    <<~RUBY
      module A
        module Helper
          #{a_helper}
        end
      end
      module B
        module Helper
          #{b_helper}
        end
        class Opts
          def self.a(parser, options) = Helper.c(parser, options)
        end
      end
      #{callers.map { |ns, name| caller_class(ns, name) }.join("\n")}
    RUBY
  end

  def caller_class(namespace, name)
    <<~RUBY
      module #{namespace}
        class #{name}
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| B::Opts.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            else
              puts "text"
            end
          end
        end
      end
    RUBY
  end

  it "follows B::Helper when the caller sits in A and only B::Helper writes" do
    expect(rules(program(reads, writes, [%w[A HelpA]]))).to eq([])
  end

  it "keeps the literal when the caller sits in A and only A::Helper writes" do
    expect(rules(program(writes, reads, [%w[A HelpA]]))).to eq(always)
  end

  it "answers the same for callers in A and in B, whichever is analysed first" do
    ab = rules(program(reads, writes, [%w[A HelpA], %w[B HelpB]]))
    ba = rules(program(reads, writes, [%w[B HelpB], %w[A HelpA]]))
    expect([ab, ba]).to eq([[], []])
  end

  it "answers the swapped helpers the same for callers in either order" do
    ab = rules(program(writes, reads, [%w[A HelpA], %w[B HelpB]]))
    ba = rules(program(writes, reads, [%w[B HelpB], %w[A HelpA]]))
    expect([ab, ba]).to eq([always * 2, always * 2])
  end
end

# Issue #2515 review — the hand-off budget is per parameter, and a self-call under an inherited singleton walks ancestors.
RSpec.describe "callee floor budget, inherited self-calls and overridden constructors (#2515)", type: :runner do
  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }

  it "keeps a self-call writer when sixteen constant-receiver hand-offs of another parameter precede it" do
    utils = (0..15).map { |i| "def self.h#{i}(parser, options) = puts(parser, options)" }.join("\n  ")
    calls = (0..15).map { |i| "Util.h#{i}(parser, options)" }.join("\n    ")
    source = <<~RUBY
      module Util
        #{utils}
      end
      class K
        def run(parser)
          options = { format: "text" }
          walk(parser, options)
          if options[:format] == "json"
            puts 1
          end
        end
        def walk(parser, options)
          #{calls}
          store(parser, options)
        end
        def store(parser, options) = options[:format] = "json"
      end
    RUBY
    expect(rules(source)).to eq([])
  end

  it "follows an inherited singleton method that hands to a singleton helper of the base" do
    source = <<~RUBY
      class Base
        def self.leaf(parser, options) = helper(parser, options)
        def self.helper(parser, options) = parser.on("--f") { |v| options[:format] = v }
      end
      class Sub < Base; end
      class Help
        def run(argv)
          options = { format: "text" }
          OptionParser.new { |opts| Sub.leaf(opts, options) }.parse!(argv)
          if options[:format] == "json"
            puts "{}"
          else
            puts "text"
          end
        end
      end
    RUBY
    expect(rules(source)).to eq([])
  end

  it "resolves nothing for Const.new when the class defines its own self.new" do
    source = <<~RUBY
      class Opts
        def self.new = Other.allocate
        def add(parser, options) = parser.on("--f") { |v| options[:format] = v }
      end
      class Other
        def add(parser, options) = puts(options.to_s)
      end
      class Help
        def run(argv)
          options = { format: "text" }
          OptionParser.new { |opts| Opts.new.add(opts, options) }.parse!(argv)
          if options[:format] == "json"
            puts "{}"
          else
            puts "text"
          end
        end
      end
    RUBY
    expect(rules(source)).to eq(always)
  end

  it "terminates and floors through a ring of classes that hand off to each other" do
    size = 12
    ring = (0...size).map do |i|
      nxt = (i + 1) % size
      body = i.zero? ? "C#{nxt}.new.x(parser, options)\n    parser.on('--f') { |v| options[:format] = v }" : "C#{nxt}.new.x(parser, options)"
      "class C#{i}\n  def x(parser, options)\n    #{body}\n  end\nend"
    end
    source = <<~RUBY
      #{ring.join("\n")}
      class Help
        def run(argv)
          options = { format: "text" }
          OptionParser.new { |opts| C3.new.x(opts, options) }.parse!(argv)
          if options[:format] == "json"
            puts "{}"
          else
            puts "text"
          end
        end
      end
    RUBY
    expect(rules(source)).to eq([])
  end
end
