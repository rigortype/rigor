# frozen_string_literal: true

# Issue #2510 — the callee mutation floor followed a self-call only, so a hash literal handed to a module function that
# captures it in a block (`Opts.add_format(opts, options)`, `parser.on(...) { |v| options[:format] = v }`) kept its
# `format: "text"` entry and `options[:format] == "json"` reported `flow.always-truthy-condition`.
require "spec_helper"

RSpec.describe "a Const.method call floors the local argument its singleton callee mutates (#2510)", type: :runner do
  def errors(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map { |d| [d.line, d.qualified_rule] }
  end

  #
  def program(callee_body, call)
    <<~RUBY
      module Opts
        module_function

        def add_format(parser, options)
          #{callee_body}
        end
      end

      class Help
        def run(argv)
          options = { format: "text" }
          parser = OptionParser.new { |opts| #{call} }
          parser.parse!(argv)
          if options[:format] == "json"
            puts "{}"
          else
            puts "text"
          end
        end
      end
    RUBY
  end

  let(:capturing) { 'parser.on("--format=FORMAT") { |value| options[:format] = value }' }
  let(:pure) { "parser.on(\"--format=FORMAT\") { |value| puts value + options.to_s }" }

  it "is silent when the callee stores into the hash from a block" do
    expect(errors(program(capturing, "Opts.add_format(opts, options)"))).to eq([])
  end

  it "is silent through a nested constant path" do
    source = program(capturing, "::Opts.add_format(opts, options)")
    expect(errors(source)).to eq([])
  end

  it "keeps the literal when the callee never writes the hash" do
    expect(errors(program(pure, "Opts.add_format(opts, options)")).map(&:last))
      .to eq(["flow.always-truthy-condition"])
  end

  it "keeps the literal when the hash is not passed" do
    expect(errors(program(capturing, "Opts.add_format(opts, {})")).map(&:last))
      .to eq(["flow.always-truthy-condition"])
  end
end
