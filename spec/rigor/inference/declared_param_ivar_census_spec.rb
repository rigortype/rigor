# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "fileutils"

require "rigor/analysis/runner"
require "rigor/configuration"

# Issue #1154 — the ADR-58 class-ivar census typed `@x = x` with no local bindings, so an ivar a constructor assigns
# from a parameter read `Dynamic[top]` in every sibling method even where `sig/` declared `initialize: (String x)`.
# A write whose value is a bare read of a parameter of the enclosing instance `def` now records the parameter's
# declared type, under the gates `ScopeIndexer::DeclaredParamWrites` lists; a declined write records what it did.
RSpec.describe "the ADR-58 ivar census types a write from a declared parameter (#1154)" do
  around do |example|
    Dir.mktmpdir("rigor-declared-param-ivar-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def census(source, rbs, class_name, ivar)
    FileUtils.mkdir_p("sig")
    File.write("sig/k.rbs", rbs)
    environment = Rigor::Environment.for_project(signature_paths: ["sig"])
    program = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty(environment: environment))
    index[program].class_ivars_for(class_name)[ivar]&.describe
  end

  def k_census(body, signature, ivar = :@x)
    census("class K\n#{body}\nend\n", "class K\n#{signature}\nend\n", "K", ivar)
  end

  describe "a credited write" do
    it "takes a positional parameter's declared type" do
      expect(k_census("def initialize(x) = @x = x", "def initialize: (String x) -> void")).to eq("String")
    end

    it "takes a keyword parameter's declared type" do
      expect(k_census("def initialize(x:) = @x = x", "def initialize: (x: String) -> void")).to eq("String")
    end

    it "takes an optional parameter's declared type, not its default's" do
      expect(k_census("def initialize(x = nil) = @x = x", "def initialize: (?Integer x) -> void")).to eq("Integer")
    end

    it "credits any declared instance method, not only initialize" do
      body = "def initialize = @x = nil\ndef record(path) = @x = path"

      expect(k_census(body, "def record: (String path) -> void")).to eq("String?")
    end

    it "joins every other write the census records" do
      body = "def initialize(x) = @x = x\ndef reset = @x = nil"

      expect(k_census(body, "def initialize: (String x) -> void")).to eq("String?")
    end

    it "keeps an untyped write in the join" do
      body = "def initialize(x) = @x = x\ndef set(v) = @x = v"

      expect(k_census(body, "def initialize: (String x) -> void")).to eq("Dynamic[top] | String")
    end

    it "does not count a local a nested def writes" do
      body = "def initialize(x)\n@x = x\ndef helper = (x = 1)\nend"

      expect(k_census(body, "def initialize: (String x) -> void")).to eq("String")
    end

    it "gives a write in a conditional or a while loop the census's ordinary treatment" do
      body = "def initialize(x, flag)\n@x = x if flag\nwhile flag\n@y = x\nflag = false\nend\nend"
      signature = "def initialize: (String x, bool flag) -> void"

      expect([k_census(body, signature), k_census(body, signature, :@y)]).to eq(%w[String String])
    end
  end

  describe "a declined write records what it did before" do
    {
      "a parameter the body reassigns" => ["def initialize(x)\nx = Integer(x)\n@x = x\nend",
                                           "def initialize: (String x) -> void"],
      "a parameter a block writes" => ["def initialize(x)\n[1].each { x ||= 1 }\n@x = x\nend",
                                       "def initialize: (String x) -> void"],
      "an overloaded signature" => ["def initialize(x) = @x = x",
                                    "def initialize: (String x) -> void\n| (Integer x) -> void"],
      "an untyped parameter (a guard: the write records untyped either way)" =>
        ["def initialize(x) = @x = x", "def initialize: (untyped x) -> void"],
      "an untyped parameter list (a guard: the binder already leaves every slot untyped)" =>
        ["def initialize(x) = @x = x", "def initialize: (?) -> void"],
      "a method type variable" => ["def initialize(x) = @x = x", "def initialize: [U] (Array[U] x) -> void"],
      "a block parameter of the same name" => ["def initialize(x)\n[1].each { |x| @x = x }\nend",
                                               "def initialize: (String x) -> void"],
      "a write in a block under another self" => ["def initialize(x)\ninstance_eval { @x = x }\nend",
                                                  "def initialize: (String x) -> void"],
      "an expression over the parameter (a guard: only a bare read is ever credited)" =>
        ["def initialize(x) = @x = (x)", "def initialize: (String x) -> void"],
      "an undeclared method" => ["def initialize(x) = @x = x", "def other: () -> void"]
    }.each do |shape, (body, signature)|
      it "for #{shape}" do
        expect(k_census(body, signature)).to eq("Dynamic[top]")
      end
    end

    it "for a class type variable" do
      rbs = "class K[T]\ndef initialize: (Array[T] x) -> void\nend\n"

      expect(census("class K\ndef initialize(x) = @x = x\nend\n", rbs, "K", :@x)).to eq("Dynamic[top]")
    end

    it "for a signature the class inherits" do
      source = "class P\nend\nclass K < P\ndef initialize(x) = @x = x\nend\n"
      rbs = "class P\ndef initialize: (String x) -> void\nend\nclass K < P\nend\n"

      expect(census(source, rbs, "K", :@x)).to eq("Dynamic[top]")
    end

    it "for a module owner" do
      rbs = "module K\ndef initialize: (String x) -> void\nend\n"

      expect(census("module K\ndef initialize(x) = @x = x\nend\n", rbs, "K", :@x)).to eq("Dynamic[top]")
    end

    it "for a singleton method" do
      signature = "def self.make: (String x) -> void\ndef make: (String x) -> void"

      expect(k_census("def self.make(x) = @x = x", signature)).to eq("Dynamic[top]")
    end
  end

  describe "through rigor check" do
    def write_project(files)
      files.each do |path, source|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
    end

    def dumps(plugins: [], plugin_requirer: nil)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0,
                                             "plugins" => plugins)
      )
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil,
                                           plugin_requirer: plugin_requirer)
      guarded_run(runner, %w[lib]).diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
    end

    # The registration `spec/integration/arity_declared_source_method_spec.rb` does: `Configuration.new`, unlike
    # `.load`, never auto-wires the bundled rbs-inline plugin.
    def rbs_inline_requirer
      plugin_lib = File.expand_path("../../../plugins/rigor-rbs-inline/lib", __dir__)
      $LOAD_PATH.unshift(plugin_lib) unless $LOAD_PATH.include?(plugin_lib)
      require "rigor-rbs-inline"
      Rigor::Plugin.unregister!
      lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::RbsInline)
        true
      end
    end

    let(:reader) { "class K\n  def r = Rigor.dump_type(@x)\nend\n" }

    it "reads the declared type in a sibling method" do
      write_project("lib/k.rb" => "class K\n  def initialize(x) = @x = x\nend\n#{reader}",
                    "sig/k.rbs" => "class K\n  def initialize: (String x) -> void\nend\n")

      expect(dumps).to eq(["dump_type: String"])
    end

    it "reads an rbs-inline parameter declaration" do
      requirer = rbs_inline_requirer
      write_project("lib/k.rb" => "class K\n  # @rbs x: String\n  def initialize(x) = @x = x\n\n  " \
                                  "#: (Symbol y) -> void\n  def note(y) = @y = y\n  " \
                                  "def r = Rigor.dump_type([@x, @y])\nend\n")
      plugin = { "gem" => "rigor-rbs-inline", "id" => "rbs-inline", "config" => { "require_magic_comment" => false } }

      expect(dumps(plugins: [plugin], plugin_requirer: requirer)).to eq(["dump_type: [String, Symbol?]"])
    ensure
      Rigor::Plugin.unregister!
    end

    it "declines a class another file reopens" do
      write_project("lib/k.rb" => "class K\n  def initialize(x) = @x = x\nend\n#{reader}",
                    "lib/k2.rb" => "class K\n  def other = 1\nend\n",
                    "sig/k.rbs" => "class K\n  def initialize: (String x) -> void\nend\n")

      expect(dumps).to eq(["dump_type: Dynamic[top]"])
    end
  end
end
