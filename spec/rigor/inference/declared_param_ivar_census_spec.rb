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

  # Issue #2321 — a write whose value is an expression over declared parameters records that expression's type, with
  # each parameter it reads bound to its declared type, under the same gates as a bare read.
  describe "a credited write derived from declared parameters (#2321)" do
    {
      "a call chain" => ["def initialize(x) = @x = x.dup.freeze", "def initialize: (String x) -> void", "String"],
      "a conversion over a union" => ["def initialize(x) = @x = x.to_sym",
                                      "def initialize: (String | Symbol x) -> void", "Symbol"],
      "a Kernel conversion of a class no RBS class extends" =>
        ["def initialize(x) = @x = Array(x)", "def initialize: (Integer x) -> void", "Array[Integer]"],
      "an argument of a class no RBS class extends" => ["def initialize(a, b) = @x = a + b",
                                                        "def initialize: (Integer a, Integer b) -> void", "Integer"],
      "a literal argument" => ["def initialize(a, b) = @x = a + b", "def initialize: (Integer a, 1 b) -> void",
                               "Integer"],
      "a union in receiver position" => ["def initialize(a, b) = @x = b + a",
                                         "def initialize: (Integer a, Integer | Float b) -> void", "Float | Integer"],
      "a map with a symbol block" => ["def initialize(x) = @x = x.map(&:to_s)",
                                      "def initialize: (Array[Symbol] x) -> void", "Array[String]"],
      "a ternary over two parameters" => ["def initialize(f, x, y) = @x = f ? x : y",
                                          "def initialize: (bool f, Integer x, String y) -> void", "Integer | String"],
      "a parenthesised read" => ["def initialize(x) = @x = (x)", "def initialize: (String x) -> void", "String"],
      "a keyword parameter" => ["def initialize(x:) = @x = x.to_sym", "def initialize: (x: String) -> void", "Symbol"],
      "an empty Array default" => ["def initialize(x = []) = @x = x.map(&:to_s)",
                                   "def initialize: (?Array[Symbol] x) -> void", "Array[String]"],
      "an empty Hash default" => ["def initialize(x: {}) = @x = x.keys",
                                  "def initialize: (?x: Hash[Symbol, Integer]) -> void", "Array[Symbol]"],
      "an optional parameter whose default is within its declared type" =>
        ["def initialize(x = nil) = @x = x&.to_s", "def initialize: (?Symbol? x) -> void", "String?"]
    }.each do |shape, (body, signature, expected)|
      it "for #{shape}" do
        expect(k_census(body, signature)).to eq(expected)
      end
    end

    it "keeps the bare credit for a parameter whose declared type holds untyped" do
      signature = "def initialize: (Array[untyped] x) -> void"

      expect(k_census("def initialize(x) = @x = x", signature)).to eq("Array[Dynamic[top]]")
    end

    it "joins every other write the census records, as a bare read does" do
      body = "def initialize(x) = @x = x.dup.freeze\ndef reset = @x = 1"

      expect(k_census(body, "def initialize: (String x) -> void")).to eq("1 | String")
    end
  end

  describe "a derived write is declined (#2321)" do
    {
      "an untyped parameter" => ["def initialize(x) = @x = x.to_s", "def initialize: (untyped x) -> void"],
      "a parameter whose declared type holds untyped (#2325)" =>
        ["def initialize(x) = @x = x.map(&:to_s)", "def initialize: (Array[untyped] x) -> void"],
      "a second parameter that is untyped" =>
        ["def initialize(x, y) = @x = x + y", "def initialize: (String x, untyped y) -> void"],
      "an undeclared method" => ["def initialize(x) = @x = x.to_s", "def other: () -> void"],
      "a parameter the body reassigns" => ["def initialize(x)\nx = 1\n@x = x.to_s\nend",
                                           "def initialize: (String x) -> void"],
      "a local that is not a parameter" => ["def initialize(x)\ny = x\n@x = y.to_s\nend",
                                            "def initialize: (Integer x) -> void"],
      "a union argument, whose first matching overload the engine picks" =>
        ["def initialize(a, b) = @x = a + b", "def initialize: (Integer a, Integer | Float b) -> void"],
      "a union argument of another operator" =>
        ["def initialize(a, b) = @x = a * b", "def initialize: (Integer a, Integer | Float b) -> void"],
      "an argument of a class another RBS class extends" =>
        ["def initialize(a, b) = @x = a - b", "def initialize: (Integer a, Numeric b) -> void"],
      "a union index argument" =>
        ["def initialize(a, i) = @x = a[i]", "def initialize: (Array[Integer] a, Integer | Range[Integer] i) -> void"],
      "an optional parameter whose default is outside its declared type" =>
        ["def initialize(x = nil) = @x = x&.to_s", "def initialize: (?Integer x) -> void"],
      "an optional parameter whose default the census cannot type" =>
        ["def initialize(x = compute) = @x = x.to_s", "def initialize: (?Integer x) -> void"],
      "an optional whose declared type holds untyped" =>
        ["def initialize(x) = @x = x&.map(&:to_s)", "def initialize: (Array[untyped]? x) -> void"],
      "a tuple whose declared type holds untyped" =>
        ["def initialize(x) = @x = x.last", "def initialize: ([untyped, Integer] x) -> void"],
      "a record whose declared type holds untyped" =>
        ["def initialize(x) = @x = x[:b]", "def initialize: ({ a: untyped, b: Integer } x) -> void"],
      "a value holding a block, whose own parameters the scan does not bind" =>
        ["def initialize(x) = @x = x.tap { nil }", "def initialize: (String x) -> void"],
      "a value holding a nested def" => ["def initialize(x) = @x = (def m(x) = x\nx.to_s)",
                                         "def initialize: (Symbol x) -> void"]
    }.each do |shape, (body, signature)|
      it "for #{shape}" do
        expect(k_census(body, signature)).to eq("Dynamic[top]")
      end
    end
  end

  it "records a union argument of a Kernel conversion as the census did before" do
    recorded = k_census("def initialize(x) = @x = Array(x)", "def initialize: (Array[String] | String x) -> void")

    expect(recorded).to eq("Dynamic[Array[Dynamic[top]] | [Dynamic[top]]]")
  end

  it "records a lambda value as the census did before (a guard: a lambda's own type never reads the parameter)" do
    expect(k_census("def initialize(x) = @x = -> { x }", "def initialize: (Symbol x) -> void")).to eq("Proc")
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
      "an undeclared method" => ["def initialize(x) = @x = x", "def other: () -> void"],
      "a rescue reference" => ["def initialize(x)\nbegin\nrescue => x\nend\n@x = x\nend",
                               "def initialize: (String x) -> void"],
      "a for index" => ["def initialize(x)\nfor x in [1]; end\n@x = x\nend", "def initialize: (String x) -> void"],
      "a multiple-assignment target" => ["def initialize(x)\nx, = [1]\n@x = x\nend",
                                         "def initialize: (String x) -> void"],
      "a hash pattern key" => ["def initialize(x)\ncase {x: 1}\nin {x:} then nil\nend\n@x = x\nend",
                               "def initialize: (String x) -> void"],
      "a rightward pattern" => ["def initialize(x)\n1 => x\n@x = x\nend", "def initialize: (String x) -> void"],
      "a write in a lambda" => ["def initialize(x)\n->(x) { @x = x }.call(1)\nend",
                                "def initialize: (String x) -> void"],
      "a binding handed to other code" => ["def initialize(x)\nHelper.rw(binding)\n@x = x\nend",
                                           "def initialize: (String x) -> void"],
      "an eval through the binding" => ["def initialize(x)\nbinding.eval(\"x = 's'\")\n@x = x\nend",
                                        "def initialize: (String x) -> void"],
      "a string instance_eval" => ["def initialize(x)\ninstance_eval(\"x = 's'\")\n@x = x\nend",
                                   "def initialize: (String x) -> void"]
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

    it "for a library class the project reopens" do
      source = "class Thread::SizedQueue\ndef initialize(m)\n@m2 = m\nend\nend\n"

      expect(census(source, "class K\nend\n", "Thread::SizedQueue", :@m2)).to eq("Dynamic[top]")
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

    def dumps(plugins: [], plugin_requirer: nil, libraries: [])
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0,
                                             "plugins" => plugins, "libraries" => libraries)
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

    def rules
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
      diagnostics = guarded_run(runner, %w[lib]).diagnostics.select { |d| d.path.end_with?("k.rb") }
      diagnostics.map { |d| [d.line, d.qualified_rule] }
    end

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

    {
      "an included module's writer method" =>
        { "lib/setter.rb" => "module Setter\n  def set_x(v) = @x = v\nend\n", include: "include Setter" },
      "an included module's attr_writer" =>
        { "lib/setter.rb" => "module Setter\n  attr_writer :x\nend\n", include: "include Setter" },
      "a superclass reached through super" =>
        { "lib/p.rb" => "class P\n  def initialize(*) = @x = 1\nend\n", superclass: "P" },
      "another object's instance_variable_set" =>
        { "lib/o.rb" => "def poke(o) = o.instance_variable_set(:@x, 2)\n" },
      "another object's instance_eval block" =>
        { "lib/o.rb" => "def poke(o) = o.instance_eval { @x = 2 }\n" },
      "another object's instance_variable_set through send" =>
        { "lib/o.rb" => "def poke(o) = o.send(:instance_variable_set, :@x, 2)\n" },
      "an instance_eval of a block argument in the class's own def" =>
        { extra: "  def configure(&b) = instance_eval(&b)\n" },
      "a string instance_eval in the class's own def" =>
        { extra: "  def run(s) = instance_eval(s)\n" },
      "a send with a computed name in the class's own def" =>
        { extra: "  def call(m, v) = send(m, v)\n" },
      "an extend in the class's own def" =>
        { extra: "  def mix(m) = extend(m)\n" },
      "a define_singleton_method in the class's own def" =>
        { extra: "  def add(n) = define_singleton_method(n) { |v| @x = v }\n" },
      "a singleton_class class_eval in the class's own def" =>
        { extra: "  def patch = singleton_class.class_eval { attr_writer :x }\n" },
      "a class << self in the class's own def" =>
        { extra: "  def patch\n    class << self\n      attr_writer :x\n    end\n  end\n" },
      "an instance_eval of a block argument in the class's own define_method block" =>
        { extra: "  define_method(:configure) { |&b| instance_eval(&b) }\n" },
      "an instance_variable_set with a computed name in the class's own def" =>
        { extra: "  def set(n, v) = instance_variable_set(n, v)\n" },
      "an instance_eval of a block argument in an included module" =>
        { "lib/setter.rb" => "module Setter\n  def configure(&b) = instance_eval(&b)\nend\n",
          include: "include Setter" },
      "a reopening's instance_variable_set with a computed name" =>
        { "lib/k2.rb" => "class K\n  def set(n, v) = instance_variable_set(n, v)\nend\n" },
      "a reopening in another file that writes the ivar" =>
        { "lib/k2.rb" => "class K\n  def reset(v) = @x = v\nend\n" },
      "an included module's instance_variable_set on self" =>
        { "lib/setter.rb" => "module Setter\n  def set_x(v) = instance_variable_set(:@x, v)\nend\n",
          include: "include Setter" }
    }.each do |shape, files|
      it "declines a write #{shape} may replace" do
        header = files[:superclass] ? "class K < #{files[:superclass]}" : "class K"
        body = files[:include] ? "  #{files[:include]}\n" : ""
        ctor = "  def initialize(x)\n    @x = x\n    super() if defined?(super)\n  end\n#{files[:extra]}"
        write_project(files.reject { |key, _| key.is_a?(Symbol) }.merge(
                        "lib/k.rb" => "#{header}\n#{body}#{ctor}  def r = Rigor.dump_type(@x)\nend\n",
                        "sig/k.rbs" => "#{header}\n  def initialize: (String x) -> void\nend\n"
                      ))
        write_project("sig/p.rbs" => "class P\nend\n", "sig/setter.rbs" => "module Setter\nend\n")

        expect(dumps).to eq(["dump_type: Dynamic[top]"])
      end
    end

    it "declines under a superclass the project does not declare and Ruby does not ship" do
      write_project("lib/k.rb" => "class K < GemBase\n  def initialize(x) = @x = x\n  " \
                                  "def r = Rigor.dump_type(@x)\nend\n",
                    "sig/k.rbs" => "class K\n  def initialize: (String x) -> void\nend\n")

      expect(dumps).to eq(["dump_type: Dynamic[top]"])
    end

    it "declines under a stdlib superclass written in Ruby" do
      write_project("lib/k.rb" => "class K < Logger\n  def initialize(x) = @x = x\n  " \
                                  "def r = Rigor.dump_type(@x)\nend\n",
                    "sig/k.rbs" => "class K < Logger\n  def initialize: (String x) -> void\nend\n")

      expect(dumps(libraries: ["logger"])).to eq(["dump_type: Dynamic[top]"])
    end

    it "credits under a superclass Ruby ships (control)" do
      write_project("lib/k.rb" => "class K < StandardError\n  def initialize(x) = @x = x\n  " \
                                  "def r = Rigor.dump_type(@x)\nend\n",
                    "sig/k.rbs" => "class K < StandardError\n  def initialize: (String x) -> void\nend\n")

      expect(dumps).to eq(["dump_type: String"])
    end

    it "declines when the ancestor chain is cut" do
      modules = (0..100).map { |i| "module M#{i}\nend\n" }.join
      includes = (0..100).map { |i| "  include M#{i}\n" }.join
      write_project("lib/m.rb" => modules,
                    "lib/k.rb" => "class K\n#{includes}  def initialize(x) = @x = x\n  " \
                                  "def r = Rigor.dump_type(@x)\nend\n",
                    "sig/k.rbs" => "class K\n  def initialize: (String x) -> void\nend\n")

      expect(dumps).to eq(["dump_type: Dynamic[top]"])
    end

    it "credits a write no other code may replace (control)" do
      write_project("lib/setter.rb" => "module Setter\n  def set_y(v) = @y = v\nend\n",
                    "lib/o.rb" => "def poke(o) = o.instance_variable_set(:@y, 2)\n",
                    "lib/k.rb" => "class K\n  include Setter\n  def initialize(x) = @x = x\n  " \
                                  "def r = Rigor.dump_type(@x)\nend\n",
                    "sig/k.rbs" => "class K\n  include Setter\n  def initialize: (String x) -> void\nend\n",
                    "sig/setter.rbs" => "module Setter\nend\n")

      expect(dumps).to eq(["dump_type: String"])
    end

    it "credits under an open-world writer in the class body, where self is the class object" do
      write_project("lib/k.rb" => "class K\n  send(:attr_reader, :x)\n  extend Comparable\n  " \
                                  "def initialize(x) = @x = x\n  def r = Rigor.dump_type(@x)\nend\n",
                    "sig/k.rbs" => "class K\n  def initialize: (String x) -> void\nend\n")

      expect(dumps).to eq(["dump_type: String"])
    end

    {
      "a Struct.new block" => "K = Struct.new(:a) do\n  def initialize(v)\n    @iv = v\n    super(1)\n  end\n  " \
                              "def r = Rigor.dump_type(@iv)\nend\n",
      "a class_eval block" => "class K\nend\nK.class_eval do\n  def initialize(v) = @iv = v\n  " \
                              "def r = Rigor.dump_type(@iv)\nend\n"
    }.each do |shape, source|
      it "declines a write in #{shape} that a reopening in another file also writes" do
        write_project("lib/k.rb" => source, "lib/k2.rb" => "class K\n  def set(v) = @iv = v\nend\n",
                      "sig/k.rbs" => "class K\n  def initialize: (String v) -> void\nend\n")

        expect(dumps).to eq(["dump_type: Dynamic[top]"])
      end
    end

    it "reads a derived write's type in a sibling method" do
      write_project("lib/k.rb" => "class K\n  def initialize(x) = @x = x.to_sym\nend\n#{reader}",
                    "sig/k.rbs" => "class K\n  def initialize: (String | Symbol x) -> void\nend\n")

      expect(dumps).to eq(["dump_type: Symbol"])
    end

    it "declines a derived write a reopening in another file also writes" do
      write_project("lib/k.rb" => "class K\n  def initialize(x) = @x = x.to_sym\nend\n#{reader}",
                    "lib/k2.rb" => "class K\n  def reset(v) = @x = v\nend\n",
                    "sig/k.rbs" => "class K\n  def initialize: (String | Symbol x) -> void\nend\n")

      expect(dumps).to eq(["dump_type: Dynamic[top]"])
    end

    it "credits a class another file reopens without writing the ivar" do
      write_project("lib/k.rb" => "class K\n  def initialize(x) = @x = x\nend\n#{reader}",
                    "lib/k2.rb" => "class K\n  def other = 1\nend\n",
                    "sig/k.rbs" => "class K\n  def initialize: (String x) -> void\nend\n")

      expect(dumps).to eq(["dump_type: String"])
    end

    # PARITY-ACCEPTED (#1154, approval-queue.d/ivar-seed-literal-write-parity.md): a writer on an object the census
    # cannot place records nothing, as `ReflectiveIvarWrite` leaves `o.instance_variable_set` alone, so the credit
    # stands. Each row's literal-write twin (`@x = "s"` in place of `@x = x`) reports `undefined method 'even?' for
    # "s"` on master today; the second example of each row pins that the twin still reports here.
    {
      "another object's instance_variable_set with a computed name" =>
        "def poke(o, n) = o.instance_variable_set(\"@\#{n}\", 2)\n",
      "an instance_variable_set in another object's instance_eval block" =>
        "def poke(o, n) = o.instance_eval { instance_variable_set(n, 2) }\n",
      "another object's string instance_eval" => "def poke(o) = o.instance_eval(\"@x = 2\")\n",
      "a send with a computed name on another object" => "def poke(o, m) = o.send(m, 2)\n",
      "another object's instance_eval given a block constant" =>
        "SET_D = proc { @x = 2 }\ndef poke(o) = o.instance_eval(&SET_D)\n",
      "another object's extend" => "module ExtSetter\n  def set(v) = @x = v\nend\ndef poke(o) = o.extend(ExtSetter)\n",
      "another object's define_singleton_method" => "def poke(o) = o.define_singleton_method(:set_c) { |v| @x = v }\n",
      "another object's singleton_class class_eval" =>
        "def poke(o) = o.singleton_class.class_eval { def set_e(v) = @x = v }\n",
      "a class << obj on another object" => "def poke(o)\n  class << o\n    def set(v) = @x = v\n  end\nend\n",
      "an attr_writer in a reopening" => "class K\n  attr_writer :x\nend\n",
      "an instance_eval of a block argument in another class" =>
        "class Conf\n  def configure(&b) = instance_eval(&b)\nend\n"
    }.each do |shape, poke|
      it "credits a write #{shape} may replace (PARITY-ACCEPTED)" do
        write_project("lib/o.rb" => poke, "lib/k.rb" => "class K\n  def initialize(x) = @x = x\nend\n#{reader}",
                      "sig/k.rbs" => "class K\n  def initialize: (String x) -> void\nend\n")

        expect(dumps).to eq(["dump_type: String"])
      end

      it "keeps reporting its literal-write twin under #{shape} (PARITY-ACCEPTED)" do
        write_project("lib/o.rb" => poke,
                      "lib/k.rb" => "class K\n  def initialize = @x = \"s\"\n  def r = @x.even?\nend\n")

        expect(rules).to eq([[3, "call.undefined-method"]])
      end
    end
  end
end
