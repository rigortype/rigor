# frozen_string_literal: true

# Integration spec for `plugins/rigor-typelizer/` (issue #1704).
#
# Contract:
#
# 1. A class under the typelizer dirs that does `include Typelizer::DSL` or `extend Typelizer::DSL`, and every
#    project subclass of one, is a root for `rigor unused` (typelizer generates a TypeScript interface for each).
# 2. A class outside the dirs, a class with no DSL on its chain, and a module that includes the DSL are not.
# 3. The plugin never adds a diagnostic.
#
# Every positive example has a control that runs the same project with the plugin switched off, so none of them
# can pass for an unrelated reason.

require "spec_helper"

require "fileutils"
require "tmpdir"

require "rigor/analysis/reachability/graph"
require "rigor/analysis/reachability/plugin_roots"
require "rigor/analysis/reachability/scan"

TYPELIZER_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-typelizer/lib", __dir__)
$LOAD_PATH.unshift(TYPELIZER_PLUGIN_LIB) unless $LOAD_PATH.include?(TYPELIZER_PLUGIN_LIB)
require "rigor-typelizer"

RSpec.describe "rigor-typelizer integration" do
  let(:plugin_class) { Rigor::Plugin::Typelizer }

  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  def project(files, plugins: ["rigor-typelizer"])
    Dir.mktmpdir do |tmp|
      # macOS spells the temp root through a symlink; the read policy compares the resolved path.
      dir = File.realpath(tmp)
      files.each do |relative, contents|
        full = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => plugins)
      )
      loaded = false
      Dir.chdir(dir) do
        contribution = Rigor::Analysis::Reachability::PluginRoots.collect(
          configuration: configuration,
          plugin_requirer: lambda do |_name|
            loaded = true
            Rigor::Plugin.register(plugin_class)
            true
          end
        )
        # PluginRoots.collect is fail-soft: without this an empty answer cannot tell "declined" from "never ran".
        expect(loaded).to be(true) unless plugins.empty?
        yield(contribution, dir)
      end
    end
  end

  def roots_for(files, plugins: ["rigor-typelizer"], &)
    project(files, plugins: plugins) { |contribution, _dir| yield(contribution.roots) }
  end

  def candidates_for(files, plugins: ["rigor-typelizer"])
    project(files, plugins: plugins) do |contribution, dir|
      declarations = []
      references = []
      files.each_key do |relative|
        result = Rigor::Analysis::Reachability::Scan.call(path: relative, source: File.read(File.join(dir, relative)))
        declarations.concat(result.declarations)
        references.concat(result.references)
      end
      return Rigor::Analysis::Reachability::Graph.new(
        declarations: declarations, references: references, root_fqns: contribution.roots
      ).report.candidates.map(&:fqn)
    end
  end

  it "registers a manifest targeting typelizer that produces reachability roots and nothing else" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("typelizer")
    expect(manifest.target_gems).to eq(["typelizer"])
    expect(manifest.produces).to eq([:reachability_roots])
  end

  # Each case is a project whose one interesting class must be rooted, and is a candidate without the plugin.
  {
    "a class that includes Typelizer::DSL" => [
      { "app/serializers/user_serializer.rb" => "class UserSerializer\n  include Typelizer::DSL\nend\n" },
      "UserSerializer"
    ],
    "a class that extends Typelizer::DSL" => [
      { "app/resources/user_resource.rb" => "class UserResource\n  extend ::Typelizer::DSL\nend\n" },
      "UserResource"
    ],
    "a class that includes the DSL among other modules" => [
      { "app/serializers/a.rb" => "class A\n  include Comparable, Typelizer::DSL\nend\n" },
      "A"
    ],
    "a subclass of a DSL base" => [
      {
        "app/serializers/base.rb" => "class Base\n  include Typelizer::DSL\nend\n",
        "app/serializers/user_serializer.rb" => "class UserSerializer < Base\nend\n"
      },
      "UserSerializer"
    ],
    "a subclass two levels below the DSL base" => [
      {
        "app/serializers/base.rb" => "class Base\n  include Typelizer::DSL\nend\nclass Mid < Base\nend\n",
        "app/serializers/leaf.rb" => "class Leaf < Mid\nend\n"
      },
      "Leaf"
    ],
    "a compact-header subclass whose base resolves at the top level" => [
      {
        "app/serializers/base.rb" => "class Base\n  include Typelizer::DSL\nend\n",
        "app/serializers/admin/user_serializer.rb" => "class Admin::UserSerializer < Base\nend\n"
      },
      "Admin::UserSerializer"
    ],
    "a namespaced class that includes the DSL" => [
      { "app/serializers/a.rb" => "module Admin\n  class UserSerializer\n    include Typelizer::DSL\n  end\nend\n" },
      "Admin::UserSerializer"
    ]
  }.each do |label, (files, expected)|
    it "roots #{label}" do
      roots_for(files) { |roots| expect(roots).to include(expected) }
    end

    it "lists #{label} as an unused candidate when the plugin is off" do
      expect(candidates_for(files, plugins: [])).to include(expected)
    end

    it "does not list #{label} as an unused candidate" do
      expect(candidates_for(files)).not_to include(expected)
    end
  end

  # A negative example is only meaningful if the producer ran: every project here carries a DSL class under
  # `app/serializers`, and the assertion is that the roots are exactly it.
  describe "what is not rooted" do
    let(:sentinel) { { "app/serializers/sentinel.rb" => "class Sentinel\n  include Typelizer::DSL\nend\n" } }

    def expect_only_sentinel(files)
      roots_for(sentinel.merge(files)) { |roots| expect(roots).to eq(["Sentinel"]) }
    end

    it "leaves a plain class a candidate" do
      files = { "app/serializers/formatter.rb" => "class Formatter\n  def format(v) = v.to_s\nend\n" }
      expect_only_sentinel(files)
      expect(candidates_for(sentinel.merge(files))).to include("Formatter")
    end

    it "leaves a class outside the configured dirs alone" do
      files = {
        "app/lib/stray.rb" => "class Stray\n  include Typelizer::DSL\nend\n",
        "app/lib/stray_child.rb" => "class StrayChild < Stray\nend\n"
      }
      expect_only_sentinel(files)
      expect(candidates_for(sentinel.merge(files))).to include("StrayChild")
    end

    it "does not root a class that includes something else, nor a bare constant mention" do
      files = {
        "app/serializers/a.rb" => <<~RUBY
          class A
            include Enumerable
            extend Forwardable
            def self.dsl = Typelizer::DSL
          end
          class B
            include Typelizer::Other
          end
        RUBY
      }
      expect_only_sentinel(files)
    end

    it "ignores a DSL include inside `class << self`" do
      source = "class A\n  class << self\n    include Typelizer::DSL\n  end\nend\n"
      expect_only_sentinel("app/serializers/a.rb" => source)
    end

    # A plain module that includes the DSL makes typelizer's `target_serializers` call `.descendants` on a
    # module (NoMethodError), and a class that only includes the module is never registered by the hook.
    it "roots neither a module that includes the DSL nor a class that includes that module" do
      files = {
        "app/serializers/shared.rb" => <<~RUBY
          module Shared
            include Typelizer::DSL
          end
          class User
            include Shared
          end
        RUBY
      }
      expect_only_sentinel(files)
      expect(candidates_for(sentinel.merge(files))).to include("User")
    end

    # The call must run with the lexical class as `self`: anywhere else it registers some other class, or none.
    {
      "a Class.new constant" => "Inner = Class.new { include Typelizer::DSL }",
      "a Class.new inside a method" => "def self.build = Class.new { include Typelizer::DSL }",
      "a Struct.new block" => "Pair = Struct.new(:a) do\n    include Typelizer::DSL\n  end",
      "a class_eval on another receiver" => "Other.class_eval { include Typelizer::DSL }",
      "an instance_exec on another receiver" => "Other.instance_exec { extend Typelizer::DSL }",
      "an instance method" => "def setup\n    include Typelizer::DSL\n  end",
      "a singleton method" => "def self.enable!\n    include Typelizer::DSL\n  end",
      "a lambda" => "HOOK = -> { include Typelizer::DSL }",
      "an ordinary call's block" => "many :x do\n    include Typelizer::DSL\n  end",
      "an included hook block" => "included do\n    include Typelizer::DSL\n  end"
    }.each do |label, body|
      it "does not credit the lexical class with an include in #{label}" do
        expect_only_sentinel("app/serializers/outer.rb" => "class Outer\n  #{body}\nend\n")
      end
    end

    it "does credit a conditional include in the class body" do
      files = { "app/serializers/a.rb" => "class A\n  include Typelizer::DSL if RUBY_VERSION\nend\n" }
      roots_for(files) { |roots| expect(roots).to eq(["A"]) }
    end

    it "follows a shadowing class declared outside dirs" do
      base = {
        "app/serializers/base.rb" => "class Base\n  include Typelizer::DSL\nend\n",
        "app/serializers/admin/x.rb" => "module Admin\n  class X < Base; end\nend\n"
      }
      shadow = { "app/models/admin/base.rb" => "module Admin\n  class Base; end\nend\n" }
      # Control: with nothing shadowing it, `Base` is the top-level DSL class and `Admin::X` is rooted.
      roots_for(base) { |roots| expect(roots).to contain_exactly("Base", "Admin::X") }
      roots_for(base.merge(shadow)) { |roots| expect(roots).to eq(["Base"]) }
    end

    it "does not root a class whose same-named superclass resolves to a non-DSL class" do
      files = {
        "app/serializers/a.rb" => <<~RUBY
          class Base
            include Typelizer::DSL
          end
          module Admin
            class Base; end
          end
          class Admin::Child < Base
          end
          module Admin
            class Inner < Base
            end
          end
        RUBY
      }
      # `class Admin::Child < Base` is a compact header: `Base` is the top-level DSL class. `Inner` sits inside
      # `module Admin`, so `Base` is `Admin::Base`, which has no DSL.
      roots_for(files) { |roots| expect(roots).to contain_exactly("Base", "Admin::Child") }
    end

    # Ruby searches the innermost cref's ancestors before the top level; that is not modelled, so decline.
    it "declines a superclass that might come from the enclosing class's own ancestors" do
      files = {
        "app/serializers/a.rb" => <<~RUBY
          class Base
            include Typelizer::DSL
          end
          class Parent
            class Base; end
          end
          class Kid < Parent
            class Y < Base; end
          end
        RUBY
      }
      roots_for(files) { |roots| expect(roots).to eq(["Base"]) }
    end
  end

  describe "configuration" do
    it "honours a custom dirs list" do
      files = {
        "app/serializers/a.rb" => "class A\n  include Typelizer::DSL\nend\n",
        "app/api/b.rb" => "class B\n  include Typelizer::DSL\nend\n"
      }
      entry = { "gem" => "rigor-typelizer", "config" => { "dirs" => ["app/api"] } }
      roots_for(files, plugins: [entry]) { |roots| expect(roots).to eq(["B"]) }
    end

    it "reads app/resources by default" do
      files = { "app/resources/a.rb" => "class A\n  include Typelizer::DSL\nend\n" }
      roots_for(files) { |roots| expect(roots).to eq(["A"]) }
    end
  end

  describe "the plugin adds no diagnostic" do
    it "emits nothing of its own and no core diagnostic the plugin-less run lacks" do
      files = {
        "app/serializers/base.rb" => "class Base\n  include Typelizer::DSL\nend\n",
        "app/serializers/user_serializer.rb" => "class UserSerializer < Base\n  typelize name: :string\nend\n"
      }
      source = "UserSerializer.typelize name: :string\nUserSerializer.bogus\nTypelizer::DSL.nope\n"
      with = run_plugin(source: source, files: files, paths: %w[demo.rb app],
                        plugin_entry: { "gem" => "rigor-typelizer", "enabled" => true })
      without = run_plugin(source: source, files: files, paths: %w[demo.rb app],
                           plugin_entry: { "gem" => "rigor-typelizer", "enabled" => false })
      tally = lambda do |result|
        result.diagnostics.reject { |d| d.severity == :info }.map { |d| [d.path, d.line, d.qualified_rule] }.tally
      end
      without_tally = tally.call(without)

      expect(plugin_diagnostics(with)).to be_empty
      added = tally.call(with).select { |key, count| count > without_tally.fetch(key, 0) }
      expect(added).to be_empty
    end
  end
end
