# frozen_string_literal: true

# Issue #2510 — the callee mutation floor followed a self-call only, so a hash literal handed to a module function that
# captures it in a block (`Opts.add_format(opts, options)`, `parser.on(...) { |v| options[:format] = v }`) kept its
# `format: "text"` entry and `options[:format] == "json"` reported `flow.always-truthy-condition`.
require "spec_helper"

RSpec.describe "a Const.method call floors the local argument its singleton callee mutates (#2510)", type: :runner do
  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }
  let(:writer) { 'parser.on("--format=FORMAT") { |value| options[:format] = value }' }
  let(:reader) { "puts(options.to_s)" }

  # `module_function` defs, the call inside the block of `OptionParser.new` (the issue's shape) unless `call` says so.
  def module_program(defs, call, namespace: nil)
    wrap = ->(body) { namespace ? "module #{namespace}\n#{body}\nend" : body }
    <<~RUBY
      #{wrap.call("module Opts\n  module_function\n#{defs}\nend")}
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

  describe "silent where the singleton callee writes the hash" do
    it "inside the block of OptionParser.new (the issue)" do
      defs = "def add_format(parser, options) = #{writer}"
      expect(rules(module_program(defs, in_block("Opts.add_format(opts, options)")))).to eq([])
    end

    it "as a plain statement" do
      defs = "def add_format(options) = (options[:format] = 'x')"
      expect(rules(module_program(defs, "Opts.add_format(options)"))).to eq([])
    end

    it "through a ::-rooted constant" do
      defs = "def add_format(parser, options) = #{writer}"
      expect(rules(module_program(defs, in_block("::Opts.add_format(opts, options)")))).to eq([])
    end

    it "through a nested constant path" do
      defs = "  def add_format(options) = (options[:format] = 'x')"
      expect(rules(module_program(defs, "A::Opts.add_format(options)", namespace: "A"))).to eq([])
    end

    it "through a keyword argument" do
      defs = "def add_format(options:) = (options[:format] = 'x')"
      expect(rules(module_program(defs, "Opts.add_format(options: options)"))).to eq([])
    end

    it "for a def self. method" do
      source = <<~RUBY
        module Opts
          def self.add_format(options) = (options[:format] = "x")
        end
        options = { format: "text" }
        Opts.add_format(options)
        options[:format] == "json" ? 1 : 2
      RUBY
      expect(rules(source)).to eq([])
    end

    it "for a method of class << self" do
      source = <<~RUBY
        module Opts
          class << self
            def add_format(options) = (options[:format] = "x")
          end
        end
        options = { format: "text" }
        Opts.add_format(options)
        options[:format] == "json" ? 1 : 2
      RUBY
      expect(rules(source)).to eq([])
    end

    it "when the module function delegates to an internal helper that writes it" do
      defs = "def add_format(parser, options) = really(parser, options)\n" \
             "def really(parser, options) = #{writer}"
      expect(rules(module_program(defs, in_block("Opts.add_format(opts, options)")))).to eq([])
    end

    it "when the caller's same-named method is pure" do
      defs = "def add_format(parser, options) = really(parser, options)\n" \
             "def really(parser, options) = #{writer}"
      source = module_program(defs, in_block("Opts.add_format(opts, options)"))
               .sub("class Help\n", "class Help\n  def really(parser, options) = nil\n")
      expect(rules(source)).to eq([])
    end
  end

  describe "keeps the literal where the callee does not write it" do
    it "when the callee only reads the hash" do
      defs = "def add_format(parser, options) = #{reader}"
      expect(rules(module_program(defs, in_block("Opts.add_format(opts, options)")))).to eq(always)
    end

    it "when the hash is not passed" do
      defs = "def add_format(parser, options) = #{writer}"
      expect(rules(module_program(defs, in_block("Opts.add_format(opts, {})")))).to eq(always)
    end

    it "when only an instance def (no module_function) has the name" do
      source = <<~RUBY
        module Opts
          def add_format(options) = (options[:format] = "x")
        end
        options = { format: "text" }
        Opts.add_format(options)
        options[:format] == "json" ? 1 : 2
      RUBY
      expect(rules(source)).to eq(always)
    end

    it "when the helper is pure in the callee's own module but writes in the caller's class" do
      defs = "def add_format(parser, options) = really(parser, options)\n" \
             "def really(parser, options) = #{reader}"
      source = module_program(defs, in_block("Opts.add_format(opts, options)"))
               .sub("class Help\n", "class Help\n  def really(parser, options) = #{writer}\n")
      expect(rules(source)).to eq(always)
    end
  end
end
