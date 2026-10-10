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
    module SigInner
      class Box
        def initialize: () -> void
        def inner_only: () -> Integer
      end
    end
    module SigNear
      class Box
        def initialize: () -> void
      end
    end
    module SigOuter
      include SigInner
    end
    module SigReopened
      include SigInner
    end
    module SigRestated
      include SigInner
    end
  RBS

  # A project file that reopens an RBS module without restating its `include` makes it a project entry whose
  # chain lists only what the project writes; Ruby still searches `SigInner` right after it.
  let(:reopened_source) { <<~RUBY }
    require "rigor/testing"
    module SigReopened
      def extra = 1
    end
    class Reopen
      include SigNear
      include SigReopened
      def run = Rigor.assert_type("Dynamic[top]", Box)
    end
    module SigRestated
      include SigInner
    end
    class Restated
      include SigNear
      include SigRestated
      def run = Rigor.assert_type("singleton(SigInner::Box)", Box)
    end
    module PlainProject
      def extra = 1
    end
    class Plain
      include SigNear
      include PlainProject
      def run = Rigor.assert_type("singleton(SigNear::Box)", Box)
    end
  RUBY

  # Ruby searches a mixin's own ancestry right after it, and the chain does not expand an RBS-only mixin's: in
  # each class below `SigOuter`'s `include SigInner` puts `SigInner::Box` ahead of `SigNear::Box`.
  let(:mixin_ancestry_source) { <<~RUBY }
    require "rigor/testing"
    class Included
      include SigNear
      include SigOuter
      def run = Rigor.assert_type("Dynamic[top]", Box)
    end
    class Prepended
      include SigNear
      prepend SigOuter
      def run = Rigor.assert_type("Dynamic[top]", Box)
    end
    module Wrap
      include SigNear
    end
    class Wrapped
      include Wrap
      include SigOuter
      def run = Rigor.assert_type("Dynamic[top]", Box)
    end
    class Base
      KIND = 1
    end
    class Continues < Base
      include SigOuter
      def run = Rigor.assert_type("1", KIND)
    end
  RUBY

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

  it "stops at an RBS-only mixin whose own ancestry may hold the name" do
    expect(run_project(mixin_ancestry_source)).to eq([])
  end

  it "stops at a reopened RBS module whose RBS ancestry the project does not restate" do
    expect(run_project(reopened_source)).to eq([])
  end

  # A declaration whose definition fails to build (here an undeclared mixin) still yields what it declares, and
  # where an ancestry cannot be read whole only a LATER RBS-only mixin is kept out: project entries, the
  # superclass chain and the top level answer as they did before #1698.
  context "with an RBS declaration whose ancestry cannot be read whole" do
    let(:signatures) { <<~RBS }
      class RSuper
      end
      class RBase < RSuper
        include MissingMod
      end
      module Hidden
        include MissingMod
      end
      module SigHelpers
        class Box
          def initialize: () -> void
        end
      end
    RBS

    it "keeps the top level, project constants and a later true positive, and keeps later mixins out" do
      rows = run_project(<<~RUBY).reject { |_, rule, _| rule.start_with?("rbs.coverage.") }
        require "rigor/testing"
        class Thing; end
        class RBase
          def x = 1
        end
        class Sub < RBase
          def thing = Rigor.assert_type("singleton(Thing)", Thing)
          def string = Rigor.assert_type("singleton(String)", String)
          def call = String.new.bogus_call
        end
        class KBase
          KIND = 1
        end
        class Kept < KBase
          include SigHelpers
          include Hidden
          def box = Rigor.assert_type("Dynamic[top]", Box)
          def kind = Rigor.assert_type("1", KIND)
        end
      RUBY
      expect(rows).to eq([[9, "call.undefined-method", "undefined method `bogus_call' for String"]])
    end
  end

  # Issue #1305 — a `class << self` body and a `def` in it run under the singleton class's cref, whose ancestors
  # are not the class's, so the included module's `Box` is not Ruby's answer there: the top-level `Box` is.
  it "does not read an RBS-only mixin's constant where self is the class object" do
    expect(run_project(<<~RUBY)).to eq([])
      require "rigor/testing"
      class Box
        def top_only = 1
      end
      class Meta
        include SigHelpers
        class << self
          def run = Rigor.assert_type("Box", Box.new)
        end
        def control = Rigor.assert_type("SigHelpers::Box", Box.new)
      end
    RUBY
  end

  it "declines when a nearer spelling of the included name is a constant the project writes" do
    expect(run_project(nearer_spelling_source)).to eq([])
  end
end
