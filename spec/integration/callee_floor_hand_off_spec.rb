# frozen_string_literal: true

# Issue #2515 review of #2516 — a hand-off's constants resolve where the callee is written.
require "spec_helper"

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

  describe "an inherited singleton def" do
    let(:library) do
      <<~RUBY
        module X
          module Helper
            def self.c(parser, options) = parser.on("--f") { |v| options[:format] = v }
          end
          class Base
            def self.leaf(parser, options) = Helper.c(parser, options)
          end
        end
        module Helper
          def self.c(parser, options) = puts(options.to_s)
        end
      RUBY
    end

    def sub(with_go)
      go = with_go ? "  def self.go(parser, options) = leaf(parser, options)\n" : ""
      "class Sub < X::Base\n#{go}end\n"
    end

    def caller_of(name, call)
      <<~RUBY
        class #{name}
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| #{call} }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    end

    it "resolves the base's constants in the base's nesting whatever the file order and the other callers" do
      leaf = caller_of("CallsLeaf", "Sub.leaf(opts, options)")
      via_go = caller_of("CallsGo", "Sub.go(opts, options)")
      orders = [[leaf, via_go], [via_go, leaf], [leaf], [via_go]]
      results = [true, false].product(orders).filter_map do |with_go, callers|
        next if !with_go && callers.include?(via_go)

        pieces = [library, sub(with_go), *callers]
        [rules(pieces.join("\n")), rules([sub(with_go), *callers, library].join("\n"))]
      end
      expect(results.flatten(1).uniq).to eq([[]])
    end

    it "follows a self-call to the inherited def made from inside the subclass" do
      source = <<~RUBY
        #{library}
        class Sub < X::Base
          def self.run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| leaf(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    it "keeps the literal when neither Helper writes" do
      pure = library.sub('parser.on("--f") { |v| options[:format] = v }', "puts(options.to_s)")
      source = "#{pure}\n#{sub(true)}\n#{caller_of('CallsLeaf', 'Sub.leaf(opts, options)')}"
      expect(rules(source)).to eq(always)
    end
  end

  describe "a compact class name" do
    it "follows a bare constant to the top-level one, as a compact nesting reads it" do
      source = <<~RUBY
        module Helper; def self.c(parser, options) = parser.on("--f") { |v| options[:format] = v }; end
        module B
          module Helper; def self.c(parser, options) = puts(options.to_s); end
        end
        class B::Opts
          def self.a(parser, options) = Helper.c(parser, options)
        end
        class Help
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| B::Opts.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end
  end
end
