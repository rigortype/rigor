# frozen_string_literal: true

# Issue #1715 — a bare call in a top-level statement position takes the signature of the one RBS module a top-level
# `include` mixes into `main` that declares the name, and only when nothing else in the program may answer it. Each
# must-stay-`Dynamic` example below is one of the shapes the #1706 review rounds found a precise type wrong on, and
# each is held by one guard: removing that guard makes its example fail.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "typing a bare top-level call through a top-level include (#1715)" do
  def run_project(files, config = {})
    files.each do |path, source|
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
    Dir.mktmpdir("rigor-toplevel-include-typing-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:sig) { <<~RBS }
    module Helpers
      def helper: () -> Integer
      def other: () -> Symbol
      private
      def secret: () -> Integer
    end
    module Twice
      def helper: () -> String
    end
    module Ext
      def helper: () -> String
    end
    class Box
      def initialize: () -> void
    end
  RBS

  # `main` with `include Helpers`, a sig for it, and whatever else `files` adds.
  def run_with(main, files = {}, config = {})
    run_project({ "sig/helpers.rbs" => sig, "lib/main.rb" => "require \"rigor/testing\"\n#{main}" }.merge(files),
                config)
  end

  it "types a bare call in a top-level statement, argument or branch" do
    result = run_with(<<~RUBY)
      include Helpers
      Rigor.assert_type("Integer", helper)
      x = helper
      Rigor.assert_type("Integer", x)
      Rigor.assert_type("Symbol", other)
      if x > 1
        Rigor.assert_type("Integer", helper)
      end
      Rigor.assert_type("String", "\#{helper}")
    RUBY

    expect(rules(result)).to eq([])
  end

  it "types a call in a file other than the one that writes the include" do
    result = run_with(%(Rigor.assert_type("Integer", helper)\n), "lib/setup.rb" => "include Helpers\n")

    expect(rules(result)).to eq([])
  end

  it "leaves a bare call in a block, lambda, method, class body or BEGIN/END untyped" do
    result = run_with(<<~RUBY)
      include Helpers
      [1].each { Rigor.assert_type("Dynamic[top]", helper) }
      Object.new.instance_eval { Rigor.assert_type("Dynamic[top]", helper) }
      Box.new.instance_exec { Rigor.assert_type("Dynamic[top]", helper) }
      Box.class_eval { Rigor.assert_type("Dynamic[top]", helper) }
      -> { Rigor.assert_type("Dynamic[top]", helper) }
      def run = Rigor.assert_type("Dynamic[top]", helper)
      class Box
        Rigor.assert_type("Dynamic[top]", helper)
      end
      class << self
        Rigor.assert_type("Dynamic[top]", helper)
      end
      BEGIN { Rigor.assert_type("Dynamic[top]", helper) }
      END { Rigor.assert_type("Dynamic[top]", helper) }
    RUBY

    expect(rules(result)).to eq([])
  end

  it "never types a call with an explicit receiver" do
    result = run_with(<<~RUBY)
      include Helpers
      Rigor.assert_type("Dynamic[top]", self.helper)
      Rigor.assert_type("Dynamic[top]", "a".helper)
      Rigor.assert_type("Dynamic[top]", Object.new.helper)
    RUBY

    expect(rules(result)).to eq([])
  end

  # Each spelling defines `helper` somewhere Ruby may reach before, or instead of, `Helpers#helper`. `other`, which
  # nothing defines, is still typed beside it.
  {
    "def self. on main" => "def self.helper = :main\n",
    "class << self on main" => "class << self\n  def helper = :main\nend\n",
    "define_method at the top level" => "define_method(:helper) { :main }\n",
    "alias on main" => "alias helper puts\n",
    "alias_method on Object" => "Object.alias_method(:helper, :puts)\n",
    "Object.define_method" => "Object.define_method(:helper) { :object }\n",
    "a def on an unrelated class" => "class Widget\n  def helper = :widget\nend\n",
    "attr_reader on a class" => "class Widget\n  attr_reader :helper\nend\n",
    "a refine block" => "module Refiner\n  refine Integer do\n    def helper = 1\n  end\nend\n"
  }.each do |shape, definer|
    it "leaves a bare call untyped beside #{shape}" do
      result = run_with(
        "include Helpers\nRigor.assert_type(\"Dynamic[top]\", helper)\nRigor.assert_type(\"Symbol\", other)\n",
        "lib/definer.rb" => definer
      )

      expect(rules(result)).to eq([])
    end
  end

  # A definition whose name no literal spells may define any name, `other` included, and so may a mixin into `Object`
  # or `main`'s singleton that no include table orders: Ruby may reach the mixed-in module's method first.
  {
    "a computed define_method name" => "class Widget\n  define_method(name) { 1 }\nend\n",
    "a string class_eval" => "class Widget; end\nWidget.class_eval \"def x; end\"\n",
    "a computed define_method name in a refine block" =>
      "module Refiner\n  refine Integer do\n    define_method(name) { 1 }\n  end\nend\n",
    "Object.include" => "Object.include(Twice)\n",
    "::Object.prepend" => "::Object.prepend(Twice)\n",
    "Object.send(:include)" => "Object.send(:include, Twice)\n",
    "Object.public_send(:prepend)" => "Object.public_send(:prepend, Twice)\n",
    "Object.include of a computed module" => "Object.include(Kernel.const_get(:Twice))\n",
    "an include on a computed Object" => "Object.const_get(:Object).include(Twice)\n",
    "Object.include in a class body" => "class Foo\n  Object.include(Twice)\nend\n",
    "a prepend in a class Object body" => "class Object\n  prepend Twice\nend\n",
    "singleton_class.include" => "singleton_class.include(Ext)\n",
    "self.singleton_class.prepend" => "self.singleton_class.prepend(Ext)\n",
    "TOPLEVEL_BINDING.receiver.extend" => "TOPLEVEL_BINDING.receiver.extend(Ext)\n"
  }.each do |shape, definer|
    it "leaves every bare call untyped beside #{shape}" do
      result = run_with("include Helpers\nRigor.assert_type(\"Dynamic[top]\", other)\n", "lib/definer.rb" => definer)

      expect(rules(result)).to eq([])
    end
  end

  # A top-level `def` answers first, from the user-method tier, as it always did.
  it "keeps a top-level def's own answer for the name" do
    result = run_with("include Helpers\nRigor.assert_type(\":top\", helper)\nRigor.assert_type(\"Symbol\", other)\n",
                      "lib/definer.rb" => "def helper = :top\n")

    expect(rules(result)).to eq([])
  end

  # An `extend` on main is nearer than every `include`, and an RBS module extended there declares names no census
  # records, so every bare call declines beside a top-level `extend`.
  it "leaves every bare call untyped beside a source module extended on main" do
    result = run_with(<<~RUBY)
      include Helpers
      module Mine
        def helper = :mine
      end
      extend Mine
      Rigor.assert_type("Dynamic[top]", helper)
      Rigor.assert_type("Dynamic[top]", other)
    RUBY

    expect(rules(result)).to eq([])
  end

  it "leaves a bare call untyped beside an RBS module extended on main" do
    result = run_with("include Helpers\nextend Ext\nRigor.assert_type(\"Dynamic[top]\", helper)\n")

    expect(rules(result)).to eq([])
  end

  # The `pre_eval:` registry answers a reopening of `Object` with its own `Dynamic` reading, as it always did.
  it "keeps a pre_eval reopening's own answer for the name" do
    result = run_with("include Helpers\nRigor.assert_type(\"Dynamic[1]\", helper)\n",
                      { "pre/patch.rb" => "class Object\n  def helper = 1\nend\n" }, "pre_eval" => %w[pre/patch.rb])

    expect(rules(result)).to eq([])
  end

  it "leaves a bare call untyped beside a pre_eval file inside paths" do
    result = run_with("include Helpers\nRigor.assert_type(\"Dynamic[top]\", helper)\n",
                      { "lib/patch.rb" => "Object.define_method(:helper) { 1 }\n" }, "pre_eval" => %w[lib/patch.rb])

    expect(rules(result)).to eq([])
  end

  # A `pre_eval:` file is loaded ahead of the project, but no load order is assumed: its mixins into `Object` or `main`
  # decline as a project file's do.
  {
    "class Object; include" => "class Object\n  include Twice\nend\n",
    "Object.include" => "Object.include(Twice)\n",
    "a top-level extend" => "extend Ext\n"
  }.each do |shape, patch|
    it "leaves every bare call untyped beside a pre_eval file's #{shape}" do
      result = run_with("include Helpers\nRigor.assert_type(\"Dynamic[top]\", helper)\n" \
                        "Rigor.assert_type(\"Dynamic[top]\", other)\n",
                        { "pre/mix.rb" => patch }, "pre_eval" => %w[pre/mix.rb])

      expect(rules(result)).to eq([])
    end
  end

  it "leaves a bare call untyped when a pre_eval file outside paths defines the name at the top level only" do
    result = run_with("include Helpers\nRigor.assert_type(\"Dynamic[top]\", helper)\n",
                      { "pre/top.rb" => "def helper = 1\n" }, "pre_eval" => %w[pre/top.rb])

    expect(rules(result)).to eq([])
  end

  it "leaves a bare call untyped when two included modules declare it, in either order" do
    %w[Helpers Twice].permutation.each do |first, second|
      result = run_with("include #{first}\ninclude #{second}\nRigor.assert_type(\"Dynamic[top]\", helper)\n")

      expect(rules(result)).to eq([])
    end
  end

  it "leaves a bare call untyped beside an undeclared module included, in either order" do
    %w[Helpers Undeclared::Thing].permutation.each do |first, second|
      result = run_with("include #{first}\ninclude #{second}\nRigor.assert_type(\"Dynamic[top]\", helper)\n")

      expect(rules(result)).to eq([])
    end
  end

  # The chain is cut at its budget: a declaration past the cut may answer the name too.
  it "leaves a bare call untyped when the include chain is cut" do
    # A project module counts toward the budget only when it defines something.
    fillers = (1..110).map { |i| "module Filler#{i}\n  def filler#{i} = #{i}\nend\ninclude Filler#{i}\n" }.join
    result = run_with("include Twice\n#{fillers}include Helpers\nRigor.assert_type(\"Dynamic[top]\", helper)\n")

    expect(rules(result)).to eq([])
  end

  it "leaves a bare call untyped when Object's own chain answers the name" do
    result = run_with(<<~RUBY)
      include Helpers
      class Object
        include Twice
      end
      Rigor.assert_type("Dynamic[top]", helper)
    RUBY

    expect(rules(result)).to eq([])
  end

  it "leaves a private declaration untyped" do
    result = run_with("include Helpers\nRigor.assert_type(\"Dynamic[top]\", secret)\n")

    expect(rules(result)).to eq([])
  end
end
