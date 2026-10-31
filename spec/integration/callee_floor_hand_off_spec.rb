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

    it "records the floor as a callee-chain-cap trace hit" do
      Rigor::Inference::BudgetTrace.enable!
      Rigor::Inference::BudgetTrace.reset
      rules("#{library}\n#{sub(true)}\n#{caller_of('CallsLeaf', 'Sub.leaf(opts, options)')}")
      expect(Rigor::Inference::BudgetTrace.snapshot[Rigor::Inference::BudgetTrace::CALLEE_CHAIN_CAP]).to be >= 1
    ensure
      Rigor::Inference::BudgetTrace.disable!
    end

    it "floors without walking when neither Helper writes (the inherited def is not read)" do
      pure = library.sub('parser.on("--f") { |v| options[:format] = v }', "puts(options.to_s)")
      source = "#{pure}\n#{sub(true)}\n#{caller_of('CallsLeaf', 'Sub.leaf(opts, options)')}"
      expect(rules(source)).to eq([])
    end

    it "does not walk back from the inherited def into the subclass (the subclass's helper writes)" do
      source = <<~RUBY
        module X
          module Helper
            def self.c(parser, options) = puts(options.to_s)
          end
          class Base
            def self.leaf(parser, options) = helper(parser, options)
            def self.helper(parser, options) = nil
          end
        end
        module Y
          module Helper
            def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
          end
          class Sub < X::Base
            def self.helper(parser, options) = Helper.c(parser, options)
          end
        end
        #{caller_of('Caller', 'Y::Sub.leaf(opts, options)')}
      RUBY
      expect(rules(source)).to eq([])
    end

    it "answers the same when two subclasses reach the inherited def, in either order" do
      def_set = <<~RUBY
        class Base
          def self.leaf(parser, options) = helper(parser, options)
        end
        class Sub1 < Base
          def self.helper(parser, options) = puts(options.to_s)
        end
        class Sub2 < Base
          def self.helper(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
      RUBY
      drivers = [%w[Sub1 Sub2], %w[Sub2 Sub1]].map do |first, second|
        "#{def_set}\nclass Driver\n  def self.go(parser, options)\n    #{first}.leaf(parser, options)\n    " \
          "#{second}.leaf(parser, options)\n  end\nend\n" \
          "#{caller_of('Caller', 'Driver.go(opts, options)')}"
      end
      expect(drivers.map { |source| rules(source) }).to eq([[], []])
    end
  end

  describe "a mixed spelling of the defining class" do
    it "finds the outer module's constant under `module A; class B::C`" do
      source = <<~RUBY
        module A
          module Helper; def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }; end
          module B
            module Helper; def self.c(parser, options) = puts(options.to_s); end
          end
        end
        module A
          class B::C
            def self.a(parser, options) = Helper.c(parser, options)
          end
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| A::B::C.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    it "keeps the literal when no candidate Helper writes" do
      source = <<~RUBY
        module A
          module Helper; def self.c(parser, options) = puts(options.to_s); end
          module B
            module Helper; def self.c(parser, options) = puts(options.to_s); end
          end
        end
        module A
          class B::C
            def self.a(parser, options) = Helper.c(parser, options)
          end
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| A::B::C.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
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
