# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tempfile"
require "tmpdir"
require "fileutils"

require "rigor/analysis/incremental_session"
require "rigor/cache/incremental_snapshot"
require "rigor/cache/store"

# Issue #1367 (ADR-117 WD2) — `global.write-type-mismatch` and `global.readonly-write`: a write to a special global that
# the interpreter's setter rejects, so the write raises every time it runs. The envelope is the setter
# (`CheckRules::SpecialGlobalSetters`), not the RBS declaration. The type check judges only a literal value, and
# declines when the program can give the literal's object the method its setter asks for.
# `spec/integration/fixtures/special_global_writes/` carries the issue's examples with the error Ruby raises for each.
RSpec.describe "special global writes", type: :runner do
  let(:setters) { Rigor::Analysis::CheckRules::SpecialGlobalSetters }

  def global_diagnostics(source = nil, **)
    analyze(source, **).diagnostics.select { |d| d.rule.to_s.start_with?("global.") }
  end

  def fired(source = nil, **)
    global_diagnostics(source, **).map { |d| [d.line, d.rule.to_s] }
  end

  # Runs `script` in a child Ruby, so a write Ruby accepts cannot disturb this process.
  def child_ruby(script, stdin_data: "")
    output, status = Open3.capture2({ "RUBYOPT" => nil }, RbConfig.ruby, "--disable-gems", "-W0", "-e", script,
                                    stdin_data: stdin_data)
    expect(status).to be_success
    output.lines(chomp: true)
  end

  # The setter table against the running interpreter, both ways, over literal values (whose class is exact).
  describe "the setter table" do
    let(:samples) do
      ["1", "1.5", "1r", "1i", '"s"', "\"s\#{1}\"", ":sym", ":\"s\#{1}\"", "nil", "true", "false", "[1]", "%w[a]",
       "{ a: 1 }", "/re/", "/r\#{1}/", "(1)"]
    end

    # The class name of the error each write raises, or "ok".
    def runtime_errors(writes)
      child_ruby(<<~RUBY, stdin_data: writes.join("\n"))
        out = STDOUT
        STDIN.read.each_line(chomp: true) do |write|
          error = begin
            eval(write)
            "ok"
          rescue Exception => e
            e.class.name
          ensure
            $stdout = out
            $stderr = STDERR
            $/ = "\\n"
            $, = $\\ = $; = nil
          end
          out.write("\#{error}\\n")
        end
      RUBY
    end

    it "reports a literal write exactly when Ruby raises TypeError for it" do
      writes = setters::CONTRACTS.keys.product(samples).map { |name, sample| "#{name} = #{sample}" }
      raised = runtime_errors(writes)
      expected = writes.each_index.filter_map { |i| [i + 1, "global.write-type-mismatch"] if raised[i] == "TypeError" }

      expect(raised.size).to eq(writes.size)
      # `$. = 1i` raises RangeError from `Complex#to_int`: the setter took the conversion, so it is no rejection.
      expect(raised - %w[ok TypeError RangeError]).to be_empty
      expect(fired(writes.join("\n"))).to eq(expected)
    end

    it "reports every read-only special, which Ruby refuses with NameError" do
      writes = setters::READ_ONLY.map { |name| "#{name} = nil" }

      expect(runtime_errors(writes)).to all(eq("NameError"))
      expect(fired(writes.join("\n"))).to eq(writes.each_index.map { |i| [i + 1, "global.readonly-write"] })
    end

    # The completeness direction: every global a fresh interpreter defines is written with each sample, so a special
    # a later Ruby adds, or whose setter starts checking, fails here until the table covers it.
    it "covers every startup global whose setter refuses a value" do
      rows = child_ruby(<<~RUBY)
        out = STDOUT
        global_variables.each do |name|
          errors = [1, nil, :sym, "s", [1], true].map do |sample|
            saved = (eval(name.to_s) rescue nil)
            begin
              eval("\#{name} = sample")
              eval("\#{name} = saved")
              "ok"
            rescue Exception => e
              e.class.name
            ensure
              $stdout = out
              $stderr = STDERR
              $stdin = STDIN
            end
          end
          out.write("\#{name}\\t\#{errors.uniq.join(',')}\\n")
        end
      RUBY
      table = rows.to_h { |row| row.split("\t", 2) }.transform_keys(&:to_sym)
      refused = ->(error) { table.filter_map { |name, errors| name if errors.split(",").include?(error) } }

      expect(table.size).to be > 30
      expect(refused.call("NameError") - setters::READ_ONLY.to_a).to be_empty
      expect(refused.call("TypeError") - setters::CONTRACTS.keys).to be_empty
    end
  end

  describe "write forms" do
    it "reports a read-only special under `op=` and as a multiple-assignment target, nested and splatted" do
      source = <<~RUBY
        $$ += 1
        a, $? = 1, 2
        b, (c, $!) = 1, [2, 3]
        d, *$: = 1, 2
      RUBY
      expect(fired(source)).to eq((1..4).map { |line| [line, "global.readonly-write"] })
    end

    it "does not report `||=` / `&&=`, which write only on a falsy (truthy) current value" do
      source = <<~RUBY
        $LOAD_PATH ||= []
        $? &&= nil
        $stdout ||= 1
        $/ &&= 1
      RUBY
      expect(fired(source)).to be_empty
    end

    it "does not type-check the value of `op=` or of a multiple-assignment target" do
      expect(fired(%($/ += 1\n$stdout, x = 1, 2\n))).to be_empty
    end

    it "does not report a write under `defined?`, which never runs it" do
      expect(fired("defined?($stdout = 1)\ndefined?($! = nil)\n")).to be_empty
    end

    it "points at the variable name" do
      diagnostic = global_diagnostics("x = ($stdout = 1)\n").first
      expect([diagnostic.line, diagnostic.column]).to eq([1, 6])
    end
  end

  describe "the value" do
    it "is judged only when it is a literal, whatever a non-literal's inferred type" do
      source = <<~RUBY
        def local = (x = 1; $stdout = x)
        def ivar = (@x = 1; $stdout = @x)
        def global = ($x = 1; $stdout = $x)
        def call = ($stdout = 1.itself)
        def constant = ($stdout = Math::PI)
        def conditional(c) = ($/ = c ? 1 : :x)
        def source_line = ($/ = __LINE__)
      RUBY
      expect(fired(source)).to be_empty
    end

    it "sees through parentheses and interpolation" do
      expect(fired(%($stdout = ((1))\n$~ = "a\#{1}"\n$0 = :"a\#{1}"\n))).to eq(
        (1..3).map { |line| [line, "global.write-type-mismatch"] }
      )
    end
  end

  # A literal's verdict rests on its class's RBS surface, which a program can widen in more spellings than any census
  # of where a definition lands could follow. So a definition of the method a setter asks for, or of a hatch, anywhere
  # in the program declines every literal; the loss of recall is accepted. Each example declines, and each would
  # report were its guard removed.
  describe "program code that may give a literal the method its setter asks for" do
    def expect_quiet(patch, write, sig: {})
      expect(fired("#{patch}#{write}\n", sig: sig)).to be_empty
    end

    it "declines on a definition of the method or a hatch anywhere, in any spelling and on any receiver" do
      {
        "class Integer\n  def write(*) = 0\nend\n" => "$stdout = 1",
        "class Numeric\n  def to_str = \"n\"\nend\n" => "$0 = 1",
        "module Comparable\n  def to_int = 1\nend\n" => "$. = \"3\"",
        "class Object\n  def method_missing(*) = 0\nend\n" => "$0 = 1",
        "module Kernel\n  def respond_to?(*) = true\nend\n" => "$stdout = 1",
        "class Symbol\n  def respond_to_missing?(*) = true\nend\n" => "$0 = :name",
        "def to_str = \"top\"\n" => "$0 = 1",
        "class << nil\n  def write(*) = 0\nend\n" => "$stdout = nil",
        "def nil.write(*) = 0\n" => "$stdout = nil",
        "K = Integer\nclass K\n  def write(*) = 0\nend\n" => "$stdout = 1",
        "class Integer\n  define_method(:write) { |*| 0 }\nend\n" => "$stdout = 1",
        "nil.define_singleton_method(:write) { |*| 0 }\n" => "$stdout = nil",
        "[Integer, Float].each { |k| k.define_method(:write) { |*| 0 } }\n" => "$stdout = 1",
        "class Integer\n  alias write to_s\nend\n" => "$stdout = 1",
        "Integer.alias_method(:write, :to_s)\n" => "$stdout = 1",
        "class Integer\n  attr_accessor :write\nend\n" => "$stdout = 1",
        "class Integer\n  extend Forwardable\n  def_delegator :to_s, :to_str\nend\n" => "$0 = 1",
        "class Integer\n  delegate_missing_to :to_s\nend\n" => "$0 = 1",
        "k = Integer\nk.send(:define_method, :write) { |*| 0 }\n" => "$stdout = 1",
        "k = Integer\nk.module_eval(\"def write(*) = 0\")\n" => "$stdout = 1",
        "class Recorder\n  def write(*) = 0\nend\n" => "$stdout = 1"
      }.each { |patch, write| expect_quiet(patch, write) }
    end

    # A non-constant receiver keeps each out of the ancestor's rewritten-surface mark, so the census alone declines.
    it "declines on a definition whose name no literal spells" do
      expect_quiet("name = :write\nk = Integer\nk.define_method(name) { |*| 0 }\n", "$stdout = 1")
      expect_quiet("m = :define_method\nk = Integer\nk.send(m, :write) { |*| 0 }\n", "$stdout = 1")
      expect_quiet("name = :write\nk = Integer\nk.class_eval(\"def \#{name}(*) = 0\")\n", "$stdout = 1")
      expect_quiet("class Integer\n  attr_reader(*%i[write])\nend\n", "$stdout = 1")
      expect_quiet("include(const_get(:Nowhere))\n", "$stdout = 1")
    end

    # Only an `eval`-family call's first argument is code: `__FILE__` and `__LINE__ + 1` name no method.
    it "still reports when the program defines only other names" do
      source = <<~RUBY
        class Integer
          def writer(*) = 0
          alias_method :to_string, :to_s
          extend Forwardable
          delegate [:size] => :to_s
        end
        k = Integer
        k.class_eval("def size_in_words = 0")
        class Widget
          class_eval <<~CODE, __FILE__, __LINE__ + 1
            def label = "w"
          CODE
          class_eval <<~CODE
            def name = "w"
          CODE
        end
        $stdout = 1
        $0 = 1
      RUBY
      expect(fired(source)).to eq([[17, "global.write-type-mismatch"], [18, "global.write-type-mismatch"]])
    end

    it "declines on a receiver-form rewrite of an ancestor" do
      expect_quiet("Object.include(Writable)\n", "$stdout = 1",
                   sig: { "writable.rbs" => "module Writable\n  def write: (*untyped) -> Integer\nend\n" })
    end

    # A top-level `include` mixes the module into `Object`, and `extend` into `main`; a module RBS does not know, or
    # declares with the method, may answer for every class. One RBS declares without it answers for none.
    it "declines on a top-level mixin of a module RBS does not rule out" do
      expect_quiet("include Nowhere\n", "$stdout = 1")
      expect_quiet("extend Nowhere\n", "$stdout = 1")
      expect_quiet("include Writable\n", "$stdout = 1",
                   sig: { "writable.rbs" => "module Writable\n  def write: (*untyped) -> Integer\nend\n" })
      expect(fired("include Comparable\n$stdout = 1\n")).to eq([[2, "global.write-type-mismatch"]])
    end

    # A class body's `include` reaches that class alone, in the analysed file or in another.
    it "still reports a mixin in the body of a class that is no ancestor of the literal's" do
      mixin = "class Widget\n  include Nowhere\nend\n"
      expect(fired("#{mixin}$stdout = 1\n")).to eq([[4, "global.write-type-mismatch"]])
      diagnostics = global_diagnostics(files: { "lib/a.rb" => mixin, "lib/w.rb" => "$stdout = 1\n" },
                                       config: { "paths" => ["lib"] })
      expect(diagnostics.map { |d| [File.basename(d.path.to_s), d.line] }).to eq([["w.rb", 1]])
    end

    it "declines on a module an ancestor mixes in that RBS declares with the method, or does not know" do
      expect_quiet("class Integer\n  include Writable\nend\n", "$stdout = 1",
                   sig: { "writable.rbs" => "module Writable\n  def write: (*untyped) -> Integer\nend\n" })
      expect_quiet("class Integer\n  include Nowhere\nend\n", "$stdout = 1")
      expect_quiet("class Integer\n  include Lenient\nend\n", "$0 = 1",
                   sig: { "lenient.rbs" => "module Lenient\n  def method_missing: (Symbol, *untyped) -> untyped\n" \
                                           "end\n" })
    end

    it "follows a project module an ancestor mixes in to the modules it mixes in" do
      expect_quiet("module Outer\n  include Writable\nend\nclass Integer\n  include Outer\nend\n", "$stdout = 1",
                   sig: { "writable.rbs" => "module Writable\n  def write: (*untyped) -> Integer\nend\n" })
    end

    it "declines on a project module an ancestor mixes in whose surface is rewritten beyond literal names" do
      expect_quiet("module Dyn\n  include const_get(:Comparable)\nend\nclass Integer\n  include Dyn\nend\n",
                   "$stdout = 1")
    end

    it "declines on a project sig/ that gives the class the method or a hatch of its own" do
      expect_quiet("", "$stdout = 1", sig: { "int.rbs" => "class Integer\n  def write: (*untyped) -> Integer\nend\n" })
      expect_quiet("", "$0 = 1",
                   sig: { "int.rbs" => "class Integer\n  def method_missing: (Symbol, *untyped) -> untyped\nend\n" })
    end

    it "declines on a `pre_eval:` patch" do
      files = { "patches/int.rb" => "class Integer\n  def write(*) = 0\nend\n", "lib/main.rb" => "$stdout = 1\n" }
      expect(fired(files: files, config: { "paths" => ["lib"], "pre_eval" => ["patches/int.rb"] })).to be_empty
    end

    it "declines when RBS cannot build the literal's class" do
      allow(Rigor::Reflection).to receive(:instance_definition).and_call_original
      allow(Rigor::Reflection).to receive(:instance_definition).with("Integer", anything).and_return(nil)
      expect(fired("$stdout = 1\n")).to be_empty
    end

    # `rb_str_setter` tests the object's built-in type and converts nothing, so a hatch cannot rescue the write.
    it "still reports a setter that converts nothing, whatever hatch the program adds" do
      expect(fired("class Object\n  def method_missing(*) = 0\nend\n$/ = 1\n"))
        .to eq([[4, "global.write-type-mismatch"]])
    end
  end

  # `fixtures/special_global_writes/refined_*.rb` pin where a refinement is and is not in effect, and that only a
  # refined `write` counts.
  describe "a refinement of `write`" do
    let(:source) do
      <<~RUBY
        module ArrayWriter
          refine(Array) { def write(*) = 0 }
        end
        using ArrayWriter
        $stdout = []
      RUBY
    end

    # Ruby 4.0.5's `respond_to?(:write)` sees the refinement; the `to_str` conversion does not.
    it "declines the stream write under a refinement of an ancestor, and not the conversion" do
      source = <<~RUBY
        module ObjectWriter
          refine(Object) { def write(*) = 0 }
        end
        using ObjectWriter
        $stdout = 1
        $0 = 1
      RUBY
      expect(fired(source)).to eq([[6, "global.write-type-mismatch"]])
    end

    # Ruby 4.0.5 accepts each: an anonymous module's refinement, and a write inside the `refine` block itself.
    it "declines where the refinement's module has no name, or the write sits inside the `refine` block" do
      expect(fired("using(Module.new { refine(Hash) { def write(*) = 0 } })\n$stdout = {}\n")).to be_empty
      source = <<~RUBY
        module ArrayWriter
          refine(Array) do
            def write(*) = 0
            def install = ($stdout = [])
          end
        end
      RUBY
      expect(fired(source)).to be_empty
    end

    it "declines on a refinement that imports a module RBS may give the method" do
      source = "module ArrayWriter\n  refine(Array) { import_methods Writable }\nend\nusing ArrayWriter\n$stdout = []\n"
      expect(fired(source, sig: { "writable.rbs" => "module Writable\n  def write: (*untyped) -> Integer\nend\n" }))
        .to be_empty
    end

    # The target may be computed or a constant alias (`fixtures/special_global_writes/refined_*_target.rb`), so which
    # class a refinement refines is not followed.
    it "declines the stream write under a refinement of `write` on any class" do
      expect(fired("module HashWriter\n  refine(Hash) { def write(*) = 0 }\nend\nusing HashWriter\n$stdout = 1\n"))
        .to be_empty
    end

    it "still reports a stream write no `using` reaches" do
      expect(fired("module HashWriter\n  refine(Hash) { def write(*) = 0 }\nend\n$stdout = 1\n"))
        .to eq([[4, "global.write-type-mismatch"]])
    end

    # A `using` of a non-constant counts every refinement as in effect in its file, but none of these refines `write`.
    it "still reports under an unresolved `using` when no refinement defines `write`" do
      expect(fired("using Module.new { refine(String) { def shout = upcase } }\n$stdout = 1\n"))
        .to eq([[2, "global.write-type-mismatch"]])
    end

    it "declines for a caller that passes no lexical sites" do
      tree = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: Rigor::Scope.empty)
      write = tree.statements.body.last
      expect(Rigor::Analysis::CheckRules.main_pass_node_diagnostics("mem.rb", write, index)).to be_empty
    end
  end

  describe "the census" do
    let(:census) { Rigor::Inference::GlobalWriteCensus }

    # Inside a `refine` block the literal's unknown name is recorded as a refinement of any name, which only the first
    # layer does; the fallback below records a definition of any name, wherever the node sits.
    it "reads a name literal whose bytes are not valid in its encoding as every name" do
      [
        'k.class_eval("\\xff def write(*) = 0 end")', 'k.define_method("\\xff") { |*| 0 }', 'k.send("\\xff", :write)',
        'k.alias_method(:"\\xff", :to_s)', 'k.attr_reader("\\xff")'
      ].each do |call|
        tree = Prism.parse("refine(Array) { #{call} }").value
        expect(census.scan(tree)).to eq(Set[census::REFINES_ANY]), call
      end
    end

    it "degrades a node it fails to read to a definition of every name, and never raises" do
      collector = census::Collector.new
      allow(collector).to receive(:visit_call).and_raise(EncodingError, "invalid symbol in encoding UTF-8")
      node = Prism.parse("k.define_method(:size) { 0 }").value.statements.body.first
      expect { collector.visit(node, top_level: true) }.not_to raise_error
      expect(collector.census).to eq(Set[census::DEFINES_ANY])
    end

    it "keeps analysing the file when it fails to read a node" do
      collector = census::Collector.new
      allow(collector).to receive(:visit_call).and_raise(ArgumentError, "invalid byte sequence in UTF-8")
      allow(census::Collector).to receive(:new).and_return(collector)
      expect(fired("k = Integer\nk.define_method(:size) { 0 }\n$stdout = 1\n$/ = 1\n"))
        .to eq([[4, "global.write-type-mismatch"]])
    end
  end

  it "declines both rules for a caller whose scope index has no scope for the write" do
    tree = Prism.parse("$stdout = 1\n$! = nil\n").value
    diagnostics = tree.statements.body.flat_map do |write|
      Rigor::Analysis::CheckRules.main_pass_node_diagnostics("mem.rb", write, {})
    end
    expect(diagnostics).to be_empty
  end

  # What exempts a write is a fact of the whole program, which no name-keyed edge can follow, so a file whose last
  # result holds a `global.*` diagnostic re-checks on every warm run. These are the round-2 review's scenarios: each
  # edit lands in a file the writing file does not depend on, and the warm answer must be the cold one.
  describe "a program fact edited between runs" do
    around do |example|
      Dir.mktmpdir("rigor-global-write-") { |dir| Dir.chdir(dir) { example.run } }
    end

    let(:fires) { [["w.rb", 1, "global.write-type-mismatch"]] }

    def write(relative, contents)
      FileUtils.mkdir_p(File.dirname(relative))
      File.write(relative, contents)
    end

    def configuration
      Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
    end

    def rows_of(diagnostics)
      diagnostics.select { |d| d.rule.to_s.start_with?("global.") }
                 .map { |d| [File.basename(d.path.to_s), d.line, d.rule.to_s] }.sort
    end

    def cache_root = File.join(Dir.pwd, ".rigor", "cache")

    def cold_rows
      rows_of(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
                .diagnostics)
    end

    def cached_rows
      runner = Rigor::Analysis::Runner.new(configuration: configuration,
                                           cache_store: Rigor::Cache::Store.new(root: cache_root))
      rows_of(guarded_run(runner, %w[lib]).diagnostics)
    end

    def incremental_rows
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: cache_root)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: %w[lib])
      session = Rigor::Analysis::IncrementalSession.new(
        configuration: configuration, paths: %w[lib], cache_store: Rigor::Cache::Store.new(root: cache_root)
      )
      found, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
      [rows_of(found), warm]
    end

    {
      "C: a receiver-form `define_method` on the literal's class" => "Integer.define_method(:write) { |*| 0 }\n",
      "D: a project module with the method, mixed in at the top level" =>
        "module Out\n  def write(*) = 0\nend\ninclude Out\n",
      "F: a class-body mixin of a module RBS does not know" => "class Integer\n  include Nowhere\nend\n",
      "J: a receiver-form mixin into Object of a module RBS does not know" => "Object.include(Nowhere)\n"
    }.each do |scenario, edit|
      it "answers a warm run as a cold one after #{scenario}" do
        write("lib/a.rb", "x = 1\n")
        write("lib/w.rb", "$stdout = 1\n")
        expect(incremental_rows).to eq([fires, false])

        write("lib/a.rb", edit)
        expect(incremental_rows).to eq([cold_rows, true])
        expect(cold_rows).to eq([])
      end
    end

    it "re-checks a read-only write under --incremental when another file aliases the special" do
      write("lib/a.rb", "x = 1\n")
      write("lib/w.rb", "$! = nil\n")
      expect(incremental_rows).to eq([[["w.rb", 1, "global.readonly-write"]], false])

      write("lib/a.rb", "alias $saved $!\n")
      expect(incremental_rows).to eq([[], true])
    end

    # The aliasing file is unchanged, so the warm run restores its census from its seed bundle.
    it "serves an unchanged aliasing file's census from its seed bundle" do
      write("lib/a.rb", "alias $saved $!\n")
      write("lib/w.rb", "$! = nil\n")
      expect(incremental_rows).to eq([[], false])

      write("lib/w.rb", "$! = nil\n$! = 1\n")
      expect(incremental_rows).to eq([[], true])
    end

    it "answers an edited alias on a cached run as a cold run does" do
      write("lib/a.rb", "x = 1\n")
      write("lib/w.rb", "$stdout = 1\n")
      expect(cached_rows).to eq(fires)

      write("lib/a.rb", "alias $stdout $captured\n")
      expect(cached_rows).to eq([])
    end
  end

  describe "severity and suppression" do
    it "reports the type check as a warning under lenient and the read-only write as an error" do
      diagnostics = global_diagnostics("$stdout = 1\n$! = nil\n", config: { "severity_profile" => "lenient" })
      expect(diagnostics.map { |d| [d.rule.to_s, d.severity] })
        .to eq([["global.write-type-mismatch", :warning], ["global.readonly-write", :error]])
    end

    it "is suppressed by rule id and by the `global` family wildcard" do
      source = <<~RUBY
        $stdout = 1 # rigor:disable global.write-type-mismatch
        $! = nil # rigor:disable global
        $$ = 1
      RUBY
      expect(fired(source)).to eq([[3, "global.readonly-write"]])
    end

    it "lets a project disable the type check without hiding read-only writes" do
      diagnostics = global_diagnostics("$stdout = 1\n$! = nil\n",
                                       config: { "disable" => ["global.write-type-mismatch"] })
      expect(diagnostics.map { |d| d.rule.to_s }).to eq(["global.readonly-write"])
    end
  end
end
