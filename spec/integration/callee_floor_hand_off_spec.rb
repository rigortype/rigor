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

    it "floors a callee's hand-off to an inherited def instead of reading its constants in the subclass's nesting" do
      source = <<~RUBY
        module X
          module Helper
            def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
          end
          class Base
            def self.leaf(parser, options) = Helper.c(parser, options)
          end
        end
        module Y
          module Helper
            def self.c(parser, options) = puts(options.to_s)
          end
          class Sub < X::Base; end
        end
        class Driver
          def self.go(parser, options) = Y::Sub.leaf(parser, options)
        end
        #{caller_of('Caller', 'Driver.go(opts, options)')}
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

  describe "a receiver the name lookup cannot reach is typed in the def's nesting" do
    it "follows a top-level alias (H = Helper)" do
      source = <<~RUBY
        module Helper
          def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        H = Helper
        class Wrap
          def self.a(parser, options) = H.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    it "follows an alias inside the class" do
      source = <<~RUBY
        module Helper
          def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        class Wrap
          H = Helper
          def self.a(parser, options) = H.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    it "follows a constant inherited from the superclass" do
      source = <<~RUBY
        class Base
          module Helper
            def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
          end
        end
        class Sub < Base
          def self.a(parser, options) = Helper.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Sub.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    it "follows a constant from an included module" do
      source = <<~RUBY
        module Mix
          module Helper
            def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
          end
        end
        class Sub
          include Mix
          def a(parser, options) = Helper.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Sub.new.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    it "follows a constant holding an instance" do
      source = <<~RUBY
        class Helper
          def c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        INST = Helper.new
        class Wrap
          def self.a(parser, options) = INST.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    it "keeps the literal when the aliased helper only reads" do
      source = <<~RUBY
        module Helper
          def self.c(parser, options) = puts(options.to_s)
        end
        H = Helper
        class Wrap
          def self.a(parser, options) = H.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq(always)
    end
  end

  describe "the by-name and the typed resolution are always unioned" do
    it "follows an alias that shadows a class of the same name" do
      source = <<~RUBY
        module Helper
          def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        module H
          def self.c(parser, options) = parser.on("--f F") { |v| puts options[:format] }
        end
        class Wrap
          H = Helper
          def self.a(parser, options) = H.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    it "follows an inherited constant that a top-level class of the same name shadows by name" do
      source = <<~RUBY
        class Helper
          def self.c(parser, options) = parser.on("--f F") { |v| puts options[:format] }
        end
        class Base
          class Helper
            def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
          end
        end
        class Wrap < Base
          def self.a(parser, options) = Helper.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    it "follows an alias, called through new, that shadows a class of the same name" do
      source = <<~RUBY
        class Helper
          def c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        class H
          def c(parser, options) = parser.on("--f F") { |v| puts options[:format] }
        end
        class Wrap
          H = Helper
          def self.a(parser, options) = H.new.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    it "follows a constant from an included module that a top-level class shadows by name" do
      source = <<~RUBY
        class Helper
          def self.c(parser, options) = parser.on("--f F") { |v| puts options[:format] }
        end
        module Mixin
          class Helper
            def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
          end
        end
        class Wrap
          include Mixin
          def self.a(parser, options) = Helper.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq([])
    end

    def compact_ancestor_source
      <<~RUBY
        module Helper
          def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        module Pure
          def self.c(parser, options) = parser.on("--f F") { |v| puts options[:format] }
        end
        class Base
          H = Helper
        end
        module A
          H = Pure
        end
        class A::Wrap < Base
          def self.a(parser, options) = H.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| A::Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    end

    it "follows a compact class name whose inherited constant differs from the lexical one" do
      expect(rules(compact_ancestor_source)).to eq([])
    end

    it "keeps the literal for an aliased helper that only reads" do
      source = <<~RUBY
        module Helper
          def self.c(parser, options) = parser.on("--f F") { |v| puts options[:format] }
        end
        H = Helper
        class Wrap
          def self.a(parser, options) = H.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq(always)
    end

    it "keeps the literal for a constant holding an instance whose method only reads" do
      source = <<~RUBY
        class Helper
          def c(parser, options) = parser.on("--f F") { |v| puts options[:format] }
        end
        class Wrap
          INST = Helper.new
          def self.a(parser, options) = INST.c(parser, options)
        end
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
      expect(rules(source)).to eq(always)
    end

    def odd_constants_source
      <<~RUBY
        module Helper
          def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        class Wrap
          K1 = 1
          K2 = [Helper].first
          K3 = nil
          K4 = Helper.new rescue nil
          K5 = Struct.new(:x)
          K6 = Class.new
          R = R rescue nil
          def self.a(parser, options)
            K1.c(parser, options)
            K2.c(parser, options)
            K3.c(parser, options)
            K4.c(parser, options)
            K5.c(parser, options)
            K5.new.c(parser, options)
            K6.new.c(parser, options)
            R.c(parser, options)
            Undefined::Deep.c(parser, options)
            K1::X.c(parser, options)
          end
        end
        def top_a(parser, options) = HH.c(parser, options)
        HH = Helper
        class Caller
          def run(argv)
            options = { format: "text" }
            OptionParser.new { |opts| Wrap.a(opts, options); top_a(opts, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    end

    it "does not crash on odd constants (numbers, nil, Class.new, self-referencing, undefined)" do
      expect(rules(odd_constants_source).grep(/internal/)).to eq([])
    end
  end

  describe "the typed hand-off memo does not leak between sides or under narrowings" do
    def m2c_class_self_source
      <<~RUBY
        require "optparse"
        class Helper
          def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        Status = Helper
        class Foo
          include Process
          class << self
            def s(parser, options) = Status.c(parser, options)
          end
          def i(parser, options) = Status.c(parser, options)
        end
        class Caller
          def first(argv)
            o = { format: "text" }
            OptionParser.new { |p| Foo.new.i(p, o) }.parse!(argv) if argv.empty? && false
            o
          end

          def second(argv)
            options = { format: "text" }
            OptionParser.new { |p| Foo.s(p, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    end

    it "follows a class-side and an instance-side use of the same constant" do
      # `Status` also names Process::Status here, a genuine call.undefined-method; only the floor is under test.
      expect(rules(m2c_class_self_source)).not_to include(*always)
    end

    def m2d_class_self_no_first_source
      <<~RUBY
        require "optparse"
        class Helper
          def self.c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        Status = Helper
        class Foo
          include Process
          class << self
            def s(parser, options) = Status.c(parser, options)
          end
          def i(parser, options) = Status.c(parser, options)
        end
        class Caller

          def second(argv)
            options = { format: "text" }
            OptionParser.new { |p| Foo.s(p, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    end

    it "follows the class-side use of the constant alone (control)" do
      # `Status` also names Process::Status here, a genuine call.undefined-method; only the floor is under test.
      expect(rules(m2d_class_self_no_first_source)).not_to include(*always)
    end

    def m3_narrow_leak_source
      <<~RUBY
        require "optparse"
        class Helper
          def c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        class SubHelper < Helper; end
        INST = Helper.new
        class Wrap
          def self.a(parser, options) = INST.c(parser, options)
          def self.b(parser, options) = INST.c(parser, options)
        end
        class Caller
          def first(argv)
            o = { format: "text" }
            if INST.is_a?(SubHelper)
              OptionParser.new { |p| Wrap.a(p, o) }.parse!(argv)
            end
            o
          end

          def second(argv)
            options = { format: "text" }
            OptionParser.new { |p| Wrap.b(p, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    end

    it "follows a constant narrowed by a guard in an earlier method" do
      expect(rules(m3_narrow_leak_source)).to eq([])
    end

    def m3b_no_first_source
      <<~RUBY
        require "optparse"
        class Helper
          def c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        class SubHelper < Helper; end
        INST = Helper.new
        class Wrap
          def self.a(parser, options) = INST.c(parser, options)
          def self.b(parser, options) = INST.c(parser, options)
        end
        class Caller

          def second(argv)
            options = { format: "text" }
            OptionParser.new { |p| Wrap.b(p, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    end

    it "follows the same constant without the earlier guard (control)" do
      expect(rules(m3b_no_first_source)).to eq([])
    end
  end

  describe "an instance receiver whose method is inherited floors the argument (#2515)" do
    let(:header) do
      <<~RUBY
        require "optparse"
        class Helper
          def c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        class SubHelper < Helper; end
      RUBY
    end

    def guarded(body)
      <<~RUBY
        class Caller
          def run(argv)
            o = { format: "text" }
            #{body}
            if o[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    end

    it "floors a direct call on an inherited instance method (n4)" do
      expect(rules("#{header}\n#{guarded('OptionParser.new { |p| SubHelper.new.c(p, o) }.parse!(argv)')}")).to eq([])
    end

    it "floors a callee's hand-off to an inherited instance method (n2)" do
      source = <<~RUBY
        #{header}
        class Wrap
          def self.a(parser, options) = SubHelper.new.c(parser, options)
        end
        #{guarded('OptionParser.new { |p| Wrap.a(p, o) }.parse!(argv)')}
      RUBY
      expect(rules(source)).to eq([])
    end

    it "floors an instance method that an included module defines" do
      source = <<~RUBY
        require "optparse"
        module Writes
          def c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        class Mixed
          include Writes
        end
        #{guarded('OptionParser.new { |p| Mixed.new.c(p, o) }.parse!(argv)')}
      RUBY
      expect(rules(source)).to eq([])
    end

    it "still reports when the inherited method is never called (control)" do
      expect(rules("#{header}\n#{guarded('SubHelper.new')}")).to eq(always)
    end

    it "still reports when the instance method is the class's own and only reads (control)" do
      source = <<~RUBY
        class Reader
          def c(parser, options) = puts(options.to_s)
        end
        #{guarded('Reader.new.c(nil, o)')}
      RUBY
      expect(rules(source)).to eq(always)
    end
  end

  describe "a census computed under a constant narrowing is not memoised for other callers (#2524)" do
    def narrowed_source(first_guard:, sub_body:)
      <<~RUBY
        require "optparse"
        class Helper
          def c(parser, options) = parser.on("--f F") { |v| options[:format] = v }
        end
        class SubHelper < Helper
          #{sub_body}
        end
        INST = Helper.new
        class Wrap
          def self.a(parser, options) = INST.c(parser, options)
        end
        class Caller
          #{first_guard}
          def second(argv)
            options = { format: "text" }
            OptionParser.new { |p| Wrap.a(p, options) }.parse!(argv)
            if options[:format] == "json"
              puts "{}"
            end
          end
        end
      RUBY
    end

    let(:first) do
      <<~RUBY
        def first(argv)
          o = { format: "text" }
          if INST.is_a?(SubHelper)
            OptionParser.new { |p| Wrap.a(p, o) }.parse!(argv)
          end
          o
        end
      RUBY
    end

    it "stays silent for the inherited narrowed subclass (m3c)" do
      expect(rules(narrowed_source(first_guard: first, sub_body: ""))).to eq([])
    end

    it "stays silent when the narrowed subclass overrides the method with a read-only one" do
      source = narrowed_source(first_guard: first, sub_body: "def c(parser, options) = puts(options.to_s)")
      expect(rules(source)).to eq([])
    end

    it "stays silent without the guarded caller (control)" do
      expect(rules(narrowed_source(first_guard: "", sub_body: "def c(parser, options) = puts(options.to_s)"))).to eq([])
    end
  end
end
