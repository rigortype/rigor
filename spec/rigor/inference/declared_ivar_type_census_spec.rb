# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "fileutils"

require "rigor/analysis/runner"
require "rigor/configuration"

# Issue #1406 — the class-ivar census ignored an RBS declaration of the ivar, whether `@x: T` or an `attr_*`
# member, so `attr_accessor cb: Proc?` beside `@cb = nil` read `Dynamic[top] | nil` (#541's untyped writer joined
# with the constructor's nil) and a `@x = "s"` write read `"s"` against a declared `@x: Integer`.
# A declared, non-`untyped`, variable-free type now replaces the census entry (`ScopeIndexer::DeclaredIvarTypes`).
RSpec.describe "the ADR-58 ivar census takes an RBS-declared ivar type (#1406)" do
  around do |example|
    Dir.mktmpdir("rigor-declared-ivar-type-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def census(source, rbs, ivar, class_name = "K")
    FileUtils.mkdir_p("sig")
    File.write("sig/k.rbs", rbs)
    environment = Rigor::Environment.for_project(signature_paths: ["sig"])
    program = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty(environment: environment))
    index[program].class_ivars_for(class_name)[ivar]&.describe
  end

  let(:ctor) { "class K\n  def initialize = @x = \"s\"\nend\n" }

  it "lets an @x declaration win over the writes" do
    expect(census(ctor, "class K\n  @x: Integer\nend\n", :@x)).to eq("Integer")
  end

  it "keeps the writes without an @x declaration (control)" do
    expect(census(ctor, "class K\nend\n", :@x)).to eq(%("s"))
  end

  describe "an attr declaration" do
    let(:source) { "class K\n  attr_accessor :cb\n  def initialize = @cb = nil\nend\n" }

    it "types the ivar an attr_accessor declares" do
      expect(census(source, "class K\n  attr_accessor cb: Proc?\nend\n", :@cb)).to eq("Proc?")
    end

    it "types the ivar an attr_reader declares" do
      expect(census(source, "class K\n  attr_reader cb: Proc?\nend\n", :@cb)).to eq("Proc?")
    end

    it "keeps #541's untyped writer without a declaration" do
      expect(census(source, "class K\nend\n", :@cb)).to eq("Dynamic[top]?")
    end

    it "keeps the census entry under an untyped declaration" do
      expect(census(source, "class K\n  attr_accessor cb: untyped\nend\n", :@cb)).to eq("Dynamic[top]?")
    end
  end

  it "keeps the census entry under a declaration with a type variable" do
    rbs = "class K[T]\n  @x: Array[T]\nend\n"

    expect(census(ctor, rbs, :@x)).to eq(%("s"))
  end

  it "takes a declaration a superclass makes" do
    source = "class P\nend\nclass K < P\n  def initialize = @x = nil\nend\n"
    rbs = "class P\n  @x: String?\nend\nclass K < P\nend\n"

    expect(census(source, rbs, :@x)).to eq("String?")
  end

  it "adds no entry for an ivar the file does not write" do
    source = "class K\n  def initialize = @y = 1\nend\n"

    expect(census(source, "class K\n  @x: String\nend\n", :@x)).to be_nil
  end

  it "keeps the entry of the ivar the file writes beside it (control)" do
    source = "class K\n  def initialize = @y = 1\nend\n"

    expect(census(source, "class K\n  @x: String\n  @y: Integer\nend\n", :@y)).to eq("Integer")
  end

  it "translates a self declaration to the class" do
    source = "class K\n  def initialize = @s = nil\nend\n"

    expect(census(source, "class K\n  @s: self?\nend\n", :@s)).to eq("K?")
  end

  it "translates an instance declaration to the class" do
    source = "class K\n  def initialize = @s = nil\nend\n"

    expect(census(source, "class K\n  @s: instance?\nend\n", :@s)).to eq("K?")
  end

  it "expands a type alias declaration" do
    source = "class K\n  def initialize = @x = nil\nend\n"

    expect(census(source, "class K\n  type t = Integer\n  @x: t\nend\n", :@x)).to eq("Integer")
  end

  describe "through rigor check with rbs-inline" do
    def dumps(source)
      FileUtils.mkdir_p("lib")
      File.write("lib/k.rb", source)
      plugin_lib = File.expand_path("../../../plugins/rigor-rbs-inline/lib", __dir__)
      $LOAD_PATH.unshift(plugin_lib) unless $LOAD_PATH.include?(plugin_lib)
      require "rigor-rbs-inline"
      Rigor::Plugin.unregister!
      requirer = lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::RbsInline)
        true
      end
      plugin = { "gem" => "rigor-rbs-inline", "id" => "rbs-inline", "config" => { "require_magic_comment" => false } }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0, "plugins" => [plugin])
      )
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, plugin_requirer: requirer)
      guarded_run(runner, %w[lib]).diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
    ensure
      Rigor::Plugin.unregister!
    end

    it "types the ivar an inline attr annotation declares" do
      source = "class K\n  attr_accessor :cb #: Proc?\n  def initialize = @cb = nil\n  " \
               "def r = Rigor.dump_type(@cb)\nend\n"

      expect(dumps(source)).to eq(["dump_type: Proc?"])
    end

    it "keeps the writes under the untyped placeholder of a bare attr_reader" do
      source = "class K\n  attr_reader :x\n\n  #: () -> void\n  def initialize = @x = \"s\"\n  " \
               "def r = Rigor.dump_type(@x)\nend\n"

      expect(dumps(source)).to eq([%(dump_type: "s")])
    end
  end

  it "reads the declaration in check over a write it rules out (sig-gen keeps the write, see generator_spec)" do
    source = "class K\n  attr_reader :x\n  def initialize = @x = \"zero\"\nend\n"

    expect(census(source, "class K\n  attr_reader x: Integer\nend\n", :@x)).to eq("Integer")
  end
end
