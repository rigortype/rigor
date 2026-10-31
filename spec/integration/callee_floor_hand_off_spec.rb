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
end
