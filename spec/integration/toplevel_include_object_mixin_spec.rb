# frozen_string_literal: true

# Issue #1697 — a top-level `include M` is `main.include`, which mixes M into `Object`: M's instance methods
# answer bare top-level calls and calls on any object, so they must not report `call.unresolved-toplevel` /
# `call.undefined-method` when M declares them, in source or in RBS. A name no included module declares
# still reports. Typing is issue #1715's, for one narrow shape (`toplevel_include_typing_spec.rb`): a bare call in
# a top-level statement to a name one RBS module declares and nothing else in the program defines. Every other
# example here asserts the call stays `Dynamic[top]`.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a top-level include mixes into Object (#1697)" do
  def run_project(files, sig = {}, config = {})
    files.each do |path, source|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end
    sig.each do |path, source|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0).merge(config)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
  end

  def rules(result) = result.diagnostics.map { |d| [d.path.delete_prefix("#{Dir.pwd}/"), d.line, d.qualified_rule] }

  around do |example|
    Dir.mktmpdir("rigor-toplevel-include-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:helpers_sig) { <<~RBS }
    module Helpers
      def helper: () -> Integer
      private
      def secret: () -> Integer
    end
    class Widget
      def initialize: () -> void
    end
    class Bare < BasicObject
      def initialize: () -> void
    end
    module Closer
      def helper: () -> Symbol
    end
    module CloserP
      def helper: () -> Symbol
    end
  RBS

  # A call with a receiver is never typed through the mixin, whatever the project does to the receiver's class;
  # each spelling below would otherwise let `Helpers#helper` stand in for a method Ruby reaches first. The refined
  # `Float#helper` is typed from its refine body (#1664), which Ruby reaches ahead of every mixin.
  let(:explicit_receiver_source) { <<~RUBY }
    require "rigor/testing"

    include Helpers

    class String
      include Closer
    end

    class Symbol
      prepend CloserP
    end

    class Widget
      def helper = :sym
    end

    class Range
      attr_reader :helper
    end

    module Refiner
      refine Float do
        def helper = "refined"
      end
    end
    using Refiner

    Rigor.assert_type("Dynamic[top]", "a".helper)
    Rigor.assert_type("Dynamic[top]", :s.helper)
    Rigor.assert_type(":sym", Widget.new.helper)
    Rigor.assert_type("Dynamic[top]", (1..2).helper)
    Rigor.assert_type('"refined"', 1.5.helper)
    Rigor.assert_type("Dynamic[top]", 1.helper)
    Rigor.assert_type("Dynamic[top]", Object.new.helper)
  RUBY

  # Each name below is also answered by something the project writes, so a bare call to it declines.
  let(:bare_call_files) do
    {
      "lib/setup.rb" => "include Helpers\n",
      "lib/object.rb" => <<~RUBY,
        class Object
          def h_obj = "o"
          attr_reader :h_attr
          define_method(:h_dm) { :dm }
        end
      RUBY
      "lib/defs.rb" => "def h_top = \"t\"\n",
      "lib/nearer.rb" => "module Near\n  def h_near = :near\nend\ninclude Near\n",
      "lib/rbs_twice.rb" => "include Twice\n",
      "pre/patch.rb" => "class Object\n  def h_pp = \"patched\"\nend\ndef h_ptop = \"toplevel-def\"\n",
      "lib/main.rb" => <<~RUBY
        require "rigor/testing"

        Rigor.assert_type("\\"o\\"", h_obj)
        Rigor.assert_type("Dynamic[top]", h_attr)
        Rigor.assert_type("Dynamic[top]", h_dm)
        Rigor.assert_type("\\"t\\"", h_top)
        Rigor.assert_type("Dynamic[top]", h_near)
        Rigor.assert_type("Dynamic[top]", h_twice)
        Rigor.assert_type("Dynamic[String]", h_pp)
        Rigor.assert_type("Dynamic[top]", h_ptop)
        Rigor.assert_type("Integer", h_ok)
        some_dsl do
          Rigor.assert_type("Dynamic[top]", h_top)
        end
      RUBY
    }
  end

  let(:bare_call_sig) { <<~RBS }
    module Helpers
      def h_obj: () -> Integer
      def h_attr: () -> Integer
      def h_dm: () -> Integer
      def h_top: () -> Integer
      def h_near: () -> Integer
      def h_twice: () -> Integer
      def h_pp: () -> Integer
      def h_ptop: () -> Integer
      def h_ok: () -> Integer
    end
    module Twice
      def h_twice: () -> String
    end
  RBS

  it "silences a source module's methods at the top level and on any object" do
    result = run_project("lib/main.rb" => <<~RUBY)
      require "rigor/testing"

      module Helpers
        def helper = 1
      end

      include Helpers
      Rigor.assert_type("Dynamic[top]", helper)
      "text".helper
      Integer.helper
      frobnicate
      "text".frobnicate
    RUBY

    expect(rules(result)).to eq([["lib/main.rb", 11, "call.unresolved-toplevel"],
                                 ["lib/main.rb", 12, "call.undefined-method"]])
  end

  it "reaches a module declared in another file, from a third" do
    result = run_project(
      "lib/helpers.rb" => "module Helpers\n  def helper = 1\nend\n",
      "lib/setup.rb" => "include Helpers\n",
      "lib/main.rb" => "helper\n\"text\".helper\nfrobnicate\n"
    )

    expect(rules(result)).to eq([["lib/main.rb", 3, "call.unresolved-toplevel"]])
  end

  it "silences the call to a module declared only in sig/, and types the bare top-level one (#1715)" do
    result = run_project(
      { "lib/main.rb" => <<~RUBY },
        require "rigor/testing"

        include Helpers
        Rigor.assert_type("Integer", helper)
        Rigor.assert_type("Dynamic[top]", "text".helper)
        frobnicate
      RUBY
      { "sig/helpers.rbs" => "module Helpers\n  def helper: () -> Integer\nend\n" }
    )

    expect(rules(result)).to eq([["lib/main.rb", 6, "call.unresolved-toplevel"]])
  end

  it "reads `include M` inside `class Object` the same way" do
    result = run_project(
      { "lib/main.rb" => <<~RUBY },
        require "rigor/testing"

        class Object
          include Helpers
        end
        Rigor.assert_type("Dynamic[top]", helper)
        frobnicate
      RUBY
      { "sig/helpers.rbs" => "module Helpers\n  def helper: () -> Integer\nend\n" }
    )

    expect(rules(result)).to eq([["lib/main.rb", 7, "call.unresolved-toplevel"]])
  end

  it "types no call with a receiver through the mixin, and stays silent on it" do
    result = run_project({ "lib/main.rb" => explicit_receiver_source }, { "sig/helpers.rbs" => helpers_sig })

    expect(rules(result)).to eq([])
  end

  it "leaves a bare call untyped beside what else the project writes for the name" do
    result = run_project(bare_call_files, { "sig/helpers.rbs" => bare_call_sig }, "pre_eval" => %w[pre/patch.rb])

    # `some_dsl` is the unknown call that makes its block's `self` opaque.
    expect(rules(result)).to eq([["lib/main.rb", 12, "call.unresolved-toplevel"]])
  end

  it "leaves bare calls untyped in blocks and bodies whose self may not be main" do
    result = run_project(
      { "lib/main.rb" => <<~RUBY },
        require "rigor/testing"

        include Helpers
        Rigor.assert_type("Dynamic[top]", helper)

        class Box
          def helper = :box
        end
        Box.new.instance_eval { Rigor.assert_type("Dynamic[top]", helper) }
        Box.new.instance_exec { Rigor.assert_type("Dynamic[top]", helper) }
        Box.class_eval { Rigor.assert_type("Dynamic[top]", helper) }

        class Object
          def check = Rigor.assert_type("Dynamic[top]", helper)
        end
      RUBY
      { "sig/helpers.rbs" => helpers_sig }
    )

    expect(rules(result)).to eq([])
  end

  it "leaves bare calls untyped beside main's own singleton methods" do
    result = run_project(
      { "lib/setup.rb" => "include Helpers\n", "lib/main.rb" => <<~RUBY },
        require "rigor/testing"

        module Ext
          def helper = "ext"
        end
        extend Ext
        def self.secret = :main
        Rigor.assert_type("Dynamic[top]", helper)
        Rigor.assert_type("Dynamic[top]", secret)
      RUBY
      { "sig/helpers.rbs" => helpers_sig }
    )

    expect(rules(result)).to eq([])
  end

  it "silences a private mixed-in method for a bare call only" do
    result = run_project(
      { "lib/main.rb" => <<~RUBY },
        require "rigor/testing"

        include Helpers
        Rigor.assert_type("Dynamic[top]", secret)
        "a".secret
      RUBY
      { "sig/helpers.rbs" => helpers_sig }
    )

    expect(rules(result)).to eq([["lib/main.rb", 5, "call.undefined-method"]])
  end

  it "keeps a BasicObject descendant out of reach and a module object in reach" do
    result = run_project(
      { "lib/main.rb" => "include Helpers
Bare.new.helper
Comparable.helper
" },
      { "sig/helpers.rbs" => helpers_sig }
    )

    expect(rules(result)).to eq([["lib/main.rb", 2, "call.undefined-method"]])
  end

  it "silences a bare call to a core module function after include Math, without typing it" do
    result = run_project("lib/main.rb" => <<~RUBY)
      require "rigor/testing"

      include Math
      Rigor.assert_type("Dynamic[top]", sqrt(2.0))
      2.0.sqrt
      frobnicate
    RUBY

    expect(rules(result)).to eq([["lib/main.rb", 5, "call.undefined-method"],
                                 ["lib/main.rb", 6, "call.unresolved-toplevel"]])
  end

  it "reads the receiver rule as a union, whichever mixin is nearer" do
    %w[Helpers Undeclared::Thing].permutation.each do |first, second|
      result = run_project(
        { "lib/main.rb" => "include #{first}\ninclude #{second}\n\"s\".helper\n\"s\".nope\n" },
        { "sig/helpers.rbs" => helpers_sig }
      )

      expect(rules(result)).to eq([["lib/main.rb", 4, "call.undefined-method"]])
    end
  end

  it "silences a bare call through an undeclared module, but not a receiver's undefined method" do
    result = run_project("lib/main.rb" => <<~RUBY)
      include Undeclared::Helpers
      anything_at_all
      "text".anything_at_all
    RUBY

    expect(rules(result)).to eq([["lib/main.rb", 3, "call.undefined-method"]])
  end

  it "does not record an include written inside a top-level block, whose self may not be main" do
    result = run_project("lib/main.rb" => <<~RUBY)
      module Helpers
        def helper = 1
      end

      [1].each do
        include Helpers
      end
      helper
    RUBY

    expect(rules(result)).to eq([["lib/main.rb", 8, "call.unresolved-toplevel"]])
  end
end
