# frozen_string_literal: true

# Issue #2515 — a splat argument. The hash literal travels inside the array (`args = [parser, options];
# Opts.add_format(*args)`), so the per-parameter floor never saw it and `options[:format] == "json"` reported
# `flow.always-truthy-condition` although the callee writes the hash.
require "spec_helper"

RSpec.describe "a *args call floors the array elements its callee writes (#2515)", type: :runner do
  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }
  let(:writer) { "def self.add_format(parser, options) = parser.on('--format') { |v| options[:format] = v }" }
  let(:reader) { "def self.add_format(parser, options) = puts(options.to_s)" }

  # `defs` in `module Opts`; `body` runs in a method with `parser` and a hash literal `options` in scope and ends with
  # a condition on `options[:format]`.
  def program(defs, body)
    <<~RUBY
      module Opts
      #{defs}
      end
      class Help
        def run(parser)
          options = { format: "text" }
          #{body}
          if options[:format] == "json"
            puts "{}"
          else
            puts "text"
          end
        end
      end
    RUBY
  end

  describe "the callee writes the element" do
    it "floors the issue's shape" do
      source = program(writer, "args = [parser, options]\nOpts.add_format(*args)")
      expect(rules(source)).to eq([])
    end

    it "floors inside the block of OptionParser.new" do
      source = program(writer, "args = [parser, options]\nOptionParser.new { |o| Opts.add_format(*args) }.parse!([])")
      expect(rules(source)).to eq([])
    end

    it "floors after leading positional arguments" do
      defs = "def self.add_format(extra, parser, options) = parser.on('--f') { |v| options[:format] = v }"
      expect(rules(program(defs, "args = [parser, options]\nOpts.add_format(1, *args)"))).to eq([])
    end

    it "floors through a direct write" do
      defs = "def self.add_format(parser, options) = (options[:format] = 'x')"
      expect(rules(program(defs, "args = [parser, options]\nOpts.add_format(*args)"))).to eq([])
    end
  end

  describe "after the call" do
    it "floors the element inside the array too" do
      source = program(writer, "args = [parser, options]\nOpts.add_format(*args)\nputs 1 if args.last[:format] == 'x'")
      expect(rules(source)).to eq([])
    end

    it "floors an element bound to the rest parameter of an inherited def" do
      source = <<~SRC
        class Base
          def self.add(parser, *) = parser
        end
        class Sub < Base
        end
        def run(parser)
          options = { format: "text" }
          args = [parser, options]
          Sub.add(*args)
          options[:format] == "json" ? 1 : 2
        end
      SRC
      expect(rules(source)).to eq([])
    end
  end

  describe "the callee only reads" do
    it "keeps the literal (a read-only control)" do
      expect(rules(program(reader, "args = [parser, options]\nOpts.add_format(*args)"))).to eq(always)
    end
  end

  describe "the positional mapping" do
    it "keeps an element bound to a parameter the callee does not write" do
      source = <<~RUBY
        module Opts
          def self.touch(first, second) = (second[:k] = 1)
        end
        def run
          first = { a: 1 }
          second = { b: 2 }
          args = [first, second]
          Opts.touch(*args)
          x = first[:a] == 2 ? 1 : 2
          y = second[:b] == 2 ? 1 : 2
        end
      RUBY
      expect(analyze(source).diagnostics.select { |d| d.qualified_rule == always.first }.map(&:line)).to eq([9])
    end
  end

  describe "an array that is no longer a known tuple" do
    it "floors every element when the array was pushed to" do
      source = program(writer, "args = [parser, options]\nargs << 1\nOpts.add_format(*args)")
      expect(rules(source)).to eq([])
    end

    it "floors every element for a splat after another splat" do
      source = program(writer, "args = [parser, options]\nOpts.add_format(*[], *args)")
      expect(rules(source)).to eq([])
    end

    it "keeps the literal when the callee only reads, even then" do
      source = program(reader, "args = [parser, options]\nargs << 1\nOpts.add_format(*args)")
      expect(rules(source)).to eq(always)
    end
  end

  describe "a rest parameter" do
    it "floors an element the callee reads through its rest parameter" do
      defs = "def self.add_format(parser, *rest) = rest.first[:format] = 'x'"
      expect(rules(program(defs, "args = [parser, options]\nOpts.add_format(*args)"))).to eq([])
    end

    it "keeps the literal when the callee never touches the rest parameter" do
      defs = "def self.add_format(parser, *) = parser"
      expect(rules(program(defs, "args = [parser, options]\nOpts.add_format(*args)"))).to eq(always)
    end
  end

  describe "an array whose element type differs from the source local's" do
    it "floors a hash pushed after the literal (args << options)" do
      source = program(writer, "args = [parser]\nargs << options\nOpts.add_format(*args)")
      expect(rules(source)).to eq([])
    end

    it "floors a hash stored by index (args[1] = options)" do
      source = program(writer, "args = [parser, nil]\nargs[1] = options\nOpts.add_format(*args)")
      expect(rules(source)).to eq([])
    end

    it "floors through an array bound under a condition (a nilable tuple)" do
      source = program(writer, "args = [parser, options] if parser\nOpts.add_format(*args)")
      expect(rules(source)).to eq([])
    end

    it "floors member by member through a union of tuples" do
      body = "other = { format: 'x' }\nargs = parser ? [parser, options] : [parser, other]\nOpts.add_format(*args)"
      expect(rules(program(writer, body))).to eq([])
    end

    it "takes the any-slot rule for a union of tuples, not each tuple's own positions" do
      body = "other = { format: 'x' }\nargs = parser ? [parser, other] : [options]\nOpts.add_format(*args)"
      expect(rules(program(writer, body))).to eq([])
    end

    it "floors every element holding the floored type when the array repeats it" do
      defs = "def self.add_format(a, b) = (b[:format] = 'x')"
      body = "args = [options, options]\nOpts.add_format(*args)\nputs 1 if args.first[:format] == 'y'"
      expect(rules(program(defs, body))).to eq([])
    end

    it "rebinds an alias of the array" do
      body = "args = [parser, options]\nalias_args = args\nOpts.add_format(*args)\n" \
             "puts 1 if alias_args.last[:format] == 'y'"
      expect(rules(program(writer, body))).to eq([])
    end
  end

  describe "a name with more defs than the hand-off cap" do
    def many(name) = (1..9).map { |i| "class Z#{i}\n  def #{name}(*a) = nil\nend" }.join("\n")

    it "floors a rest handed to a call whose name has nine user defs, without crashing" do
      defs = "def self.add_format(q, *args) = q.zap(*args)"
      source = "#{many('zap')}\n#{program(defs, "args = [Z1.new, options]\nOpts.add_format(*args)")}"
      expect(rules(source)).to eq([])
    end

    it "floors a rest handed to blk.call(*args)" do
      defs = "def self.add_format(parser, *args, &blk) = blk.call(*args)"
      source = "#{many('call')}\n#{program(defs, "args = [parser, options]\nOpts.add_format(*args) { |*a| a }")}"
      expect(rules(source)).to eq([])
    end
  end

  describe "a callee of another class" do
    it "resolves the forwarded hop in the callee's class, not the caller's" do
      source = <<~SRC
        class Opts
          def w(parser, options) = (options[:format] = "json")
          def f1(*a) = f2(*a)
          def f2(x, y) = w(x, y)
        end
        def run(parser)
          options = { format: "text" }
          args = [parser, options]
          Opts.new.f1(*args)
          options[:format] == "json" ? 1 : 2
        end
      SRC
      expect(rules(source)).to eq([])
    end
  end

  describe "a rest forwarded through two rest forwarders" do
    it "floors when the last one writes" do
      defs = "def self.f1(*a) = f2(*a)\ndef self.f2(*b) = w(*b)\ndef self.w(parser, options) = (options[:format] = 'x')"
      expect(rules(program(defs, "args = [parser, options]\nOpts.f1(*args)"))).to eq([])
    end
  end

  describe "a callee that writes only a keyword" do
    it "keeps the literal of a pushed array" do
      defs = "def self.add_format(parser, *rest, kw: {}) = (kw[:x] = 1)"
      body = "args = [parser, options]\nargs << 1\nOpts.add_format(*args)"
      expect(rules(program(defs, body))).to eq(always)
    end
  end

  describe "a splat forwarded inside the callee" do
    let(:forward) { "def self.forward(*args) = add_format(*args)" }

    it "floors when the forwarded call resolves to a writer" do
      source = program("#{writer}\n#{forward}", "args = [parser, options]\nOpts.forward(*args)")
      expect(rules(source)).to eq([])
    end

    it "keeps the literal when the forwarded call only reads" do
      source = program("#{reader}\n#{forward}", "args = [parser, options]\nOpts.forward(*args)")
      expect(rules(source)).to eq(always)
    end

    it "keeps the literal when the rest parameter is handed to a call that resolves to no user def" do
      defs = "def self.forward(*args) = puts(*args)"
      expect(rules(program(defs, "args = [parser, options]\nOpts.forward(*args)"))).to eq(always)
    end
  end

  # The rest-parameter census is a property of one def node, memoised per node: two defs spelt alike that resolve
  # their forwarded call to different callees keep their own answers.
  describe "the rest-parameter memo is keyed by the def" do
    it "answers each of two same-named forwarders from its own callee" do
      source = <<~SRC
        module Writes
          def self.add(parser, options) = (options[:format] = "x")
          def self.forward(*args) = add(*args)
        end
        module Reads
          def self.add(parser, options) = puts(options.to_s)
          def self.forward(*args) = add(*args)
        end
        def run(parser)
          written = { format: "text" }
          kept = { shown: "text" }
          first = [:p, written]
          second = [:p, kept]
          Writes.forward(*first)
          Reads.forward(*second)
          written[:format] == "json" ? 1 : 2
          kept[:shown] == "json" ? 1 : 2
        end
      SRC
      expect(analyze(source).diagnostics.select { |d| d.qualified_rule == always.first }.map(&:line)).to eq([17])
    end
  end

  # A local matched by type is only a guess at the element's source, so its floor must never add a finding.
  describe "a local matched by type but never written" do
    let(:sink) do
      <<~SRC
        class Sink
          def lit(s) = s
        end
        module Opts
          def self.add(parser, buffer) = (buffer << "!")
          def self.touch(parser, buffer) = (parser << "!")
        end
      SRC
    end

    def mismatches(source)
      signature = { "sink.rbs" => "class Sink\n  def lit: (\"text\") -> String\nend\n" }
      analyze(source, sig: signature).diagnostics.map(&:qualified_rule).grep(/argument-type-mismatch/)
    end

    it "keeps an unrelated string literal usable where a literal type is expected (equal type)" do
      source = "#{sink}def run(parser)\n  label = 'text'\n  buf = 'text'\n  args = [parser, buf]\n  " \
               "Opts.add(*args)\n  Sink.new.lit(label)\nend\n"
      expect(mismatches(source)).to eq([])
    end

    it "keeps it through the subtype path (a pushed Array[String] accepts every string)" do
      source = "#{sink}def run(parser)\n  label = 'text'\n  buf = 'other'\n  args = [parser]\n  args << buf\n  " \
               "Opts.add(*args)\n  Sink.new.lit(label)\nend\n"
      expect(mismatches(source)).to eq([])
    end

    it "keeps a nilable string literal usable where a literal type is expected (a union floor)" do
      source = "#{sink}def run(parser)\n  label = parser ? 'text' : nil\n  args = [Object.new]\n  " \
               "Opts.touch(*args)\n  Sink.new.lit(label)\nend\n"
      signature = { "sink.rbs" => "class Sink\n  def lit: (\"text\"?) -> untyped\nend\n" }
      found = analyze(source, sig: signature).diagnostics.map(&:qualified_rule).grep(/argument-type-mismatch/)
      expect(found).to eq([])
    end

    it "does not floor an unrelated hash when the written element is Dynamic" do
      source = "#{sink}def run(parser)\n  other = { k: 1 }\n  args = [parser, 'x']\n  Opts.touch(*args)\n  " \
               "other[:k] == 2 ? 1 : 2\nend\n"
      expect(rules(source)).to eq(always)
    end
  end

  # An element of the rebuilt array that the callee does not write is floored by over-approximation; its floor is
  # gradual too, or reading it back fails against a literal parameter type that the unmutated array satisfied.
  describe "a rebuilt array element the callee does not write" do
    let(:signature) { { "sink.rbs" => "class Sink\n  def lit: (\"text\") -> void\nend\n" } }
    let(:defs) do
      <<~SRC
        class Sink
          def lit(s) = nil
        end
        module Opts
          def self.add(parser, buffer, extra) = (buffer << "!")
          def self.rest2(buffer, *rest) = rest.size
        end
      SRC
    end

    def mismatches(source)
      analyze(source, sig: signature).diagnostics.map(&:qualified_rule).grep(/argument-type-mismatch/)
    end

    it "stays usable when its type repeats a written one (read by index)" do
      source = "#{defs}def run(parser)\n  a = 'text'\n  args = [parser, a, 'text']\n  Opts.add(*args)\n  " \
               "Sink.new.lit(args[2])\nend\n"
      expect(mismatches(source)).to eq([])
    end

    it "stays usable when destructured" do
      source = "#{defs}def run(parser)\n  a = 'text'\n  args = [parser, a, 'text']\n  Opts.add(*args)\n  " \
               "_b, _c, d = args\n  Sink.new.lit(d)\nend\n"
      expect(mismatches(source)).to eq([])
    end

    it "stays usable under an unknown splat position" do
      source = "#{defs}def run(parser)\n  pre = [parser]\n  args = [+'x', 'text']\n  Opts.add(*pre, *args)\n  " \
               "Sink.new.lit(args[1])\nend\n"
      expect(mismatches(source)).to eq([])
    end

    it "stays usable when the callee's rest is read as written" do
      source = "#{defs}def run\n  args2 = [+'y', 'text']\n  Opts.rest2(*args2)\n  Sink.new.lit(args2[1])\nend\n"
      expect(mismatches(source)).to eq([])
    end
  end

  describe "the documented limit" do
    it "floors an equal literal held by another local too (only the type says which local an element is)" do
      body = "other = { format: 'text' }\nargs = [parser, options]\nOpts.add_format(*args)\n" \
             "puts 1 if other[:format] == 'x'"
      source = program(writer, body)
      expect(rules(source)).to eq([])
    end

    it "does not follow a splat of anything but a local" do
      source = program(writer, "Opts.add_format(*[parser, options])")
      expect(rules(source)).to eq(always)
    end
  end
end
