# frozen_string_literal: true

# Issue #2515 review of #2516 — the hand-off budget is per parameter, an inherited singleton walks its ancestors, and
# `Const.new` of an overridden constructor resolves nothing.
require "spec_helper"
RSpec.describe "callee floor budget, inherited self-calls and overridden constructors (#2515)", type: :runner do
  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }

  def fan_out_program(store_body)
    utils = (0..15).map { |i| "def self.h#{i}(parser, options) = puts(parser, options)" }.join("\n  ")
    calls = (0..15).map { |i| "Util.h#{i}(parser, options)" }.join("\n    ")
    <<~RUBY
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
        def store(parser, options) = #{store_body}
      end
    RUBY
  end

  it "keeps a self-call writer when sixteen constant-receiver hand-offs of another parameter precede it" do
    expect(rules(fan_out_program('options[:format] = "json"'))).to eq([])
  end

  it "keeps the literal of a second parameter when the first one's hand-off nodes used up a shared budget" do
    expect(rules(fan_out_program("puts(options.to_s)"))).to eq(always)
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
      body = "C#{nxt}.new.x(parser, options)"
      body += "\n    parser.on('--f') { |v| options[:format] = v }" if i.zero?
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
