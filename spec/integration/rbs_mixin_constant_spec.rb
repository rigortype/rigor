# frozen_string_literal: true

# Issue #1698 — a constant a class reaches through a module it `include`s or `prepend`s resolves when only RBS
# declares the module, as it does for a module the project declares: Ruby searches the cref's ancestors after
# the lexical scopes and before the top level. Each example carries a must-still-fire control or a
# must-not-resolve read, so a run that analysed nothing cannot pass by reporting nothing.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a constant reached through an RBS-only mixin (#1698)" do
  def run_project(source)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write("sig/helpers.rbs", signatures)
    File.write("lib/demo.rb", source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
      .diagnostics.reject { |diagnostic| diagnostic.severity == :info }
      .map { |diagnostic| [diagnostic.line, diagnostic.qualified_rule, diagnostic.message] }
  end

  around do |example|
    Dir.mktmpdir("rigor-rbs-mixin-constant-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:signatures) { <<~RBS }
    module SigHelpers
      class Box
        def initialize: () -> void
        def size: () -> Integer
      end
      LIMIT: Integer
    end
    module SigOther
      class Box
        def initialize: () -> void
        def other: () -> String
      end
    end
    module SigWrap
    end
    class SigBase
      KIND: Symbol
    end
  RBS

  let(:nearer_spelling_source) { <<~RUBY }
    require "rigor/testing"
    module Outer
      SigHelpers = Comparable
      class Inner
        include SigHelpers
        def run = Rigor.assert_type("Dynamic[top]", LIMIT)
      end
    end
    class Own
      SigHelpers = Comparable
      include SigHelpers
      def run = Rigor.assert_type("Dynamic[top]", LIMIT)
    end
    class OwnModule
      module SigHelpers
      end
      include SigHelpers
      def run = Rigor.assert_type("Dynamic[top]", LIMIT)
    end
    module Untyped
      SigHelpers = build_helpers
      class Inner
        include SigHelpers
        def run = Rigor.assert_type("Dynamic[top]", LIMIT)
      end
    end
  RUBY
  let(:ancestor_order_source) { <<~RUBY }
    require "rigor/testing"
    module Proj
      Box = :proj
    end
    class Base
      Box = 1
    end
    class Two
      include SigHelpers
      include SigOther
      def run = Rigor.assert_type("SigOther::Box", Box.new)
    end
    class Pre
      include Proj
      prepend SigOther
      def run = Rigor.assert_type("SigOther::Box", Box.new)
    end
    class Near
      include SigHelpers
      include Proj
      def run = Rigor.assert_type(":proj", Box)
    end
    class Sub < Base
      include SigHelpers
      def run = Rigor.assert_type("SigHelpers::Box", Box.new)
    end
    module Wrapper
      include SigHelpers
    end
    class Deep < Base
      include Wrapper
      def run = Rigor.assert_type("SigHelpers::Box", Box.new)
    end
  RUBY

  it "reads a class and a value constant the included module declares" do
    expect(run_project(<<~RUBY)).to eq([[8, "call.undefined-method", "undefined method `other' for SigHelpers::Box"]])
      require "rigor/testing"
      class User
        include SigHelpers
        def run
          Rigor.assert_type("SigHelpers::Box", Box.new)
          Rigor.assert_type("Integer", LIMIT)
          Rigor.assert_type("Dynamic[top]", Missing)
          Box.new.other
        end
      end
    RUBY
  end

  it "lets a lexical constant of the same name win" do
    expect(run_project(<<~RUBY)).to eq([])
      require "rigor/testing"
      class Shadowed
        Box = 1
        include SigHelpers
        def run = Rigor.assert_type("1", Box)
      end
      module Outer
        Box = "s"
        class Inner
          include SigHelpers
          def run = Rigor.assert_type("\\"s\\"", Box)
        end
      end
    RUBY
  end

  it "follows Ruby's ancestor order across RBS and project modules (#1571)" do
    expect(run_project(ancestor_order_source)).to eq([])
  end

  # A top-level `include` is filed apart from `Object` (#1706) and reaches no class chain, so a constant reached
  # only through it stays unresolved, at the top level and in a class.
  it "does not read a constant the module does not declare, through an RBS superclass, or a top-level include" do
    expect(run_project(<<~RUBY)).to eq([])
      require "rigor/testing"
      include SigOther
      Rigor.assert_type("Dynamic[top]", Box)
      class Elsewhere
        def run = Rigor.assert_type("Dynamic[top]", Box)
      end
      class Plain
        include SigWrap
        def run = Rigor.assert_type("Dynamic[top]", Box)
      end
      class Child < SigBase
        def run = Rigor.assert_type("Dynamic[top]", KIND)
      end
    RUBY
  end

  it "declines when a nearer spelling of the included name is a constant the project writes" do
    expect(run_project(nearer_spelling_source)).to eq([])
  end
end
