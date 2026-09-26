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

  # A literal is rejected by its class's RBS surface, which a program can widen in many spellings. Each example is
  # one Ruby 4.0.5 accepts, and each would report were its guard removed.
  describe "program code that gives a literal the method its setter asks for" do
    def expect_quiet(patch, write, sig: {})
      expect(fired("#{patch}#{write}\n", sig: sig)).to be_empty
    end

    it "declines on a definition in a reopened class or ancestor, in any spelling" do
      {
        "class Integer\n  def write(*) = 0\nend\n" => "$stdout = 1",
        "class Numeric\n  def to_str = \"n\"\nend\n" => "$0 = 1",
        "module Comparable\n  def to_int = 1\nend\n" => "$. = \"3\"",
        "class Integer\n  define_method(:write) { |*| 0 }\nend\n" => "$stdout = 1",
        "class Integer\n  alias write to_s\nend\n" => "$stdout = 1",
        "class Integer\n  alias_method :write, :to_s\nend\n" => "$stdout = 1",
        "class Object\n  def method_missing(*) = 0\nend\n" => "$0 = 1",
        "module Kernel\n  def respond_to?(*) = true\nend\n" => "$stdout = 1",
        "def to_str = \"top\"\n" => "$0 = 1"
      }.each { |patch, write| expect_quiet(patch, write) }
    end

    it "declines on a receiver-form rewrite of an ancestor" do
      expect_quiet("Integer.define_method(:write) { |*| 0 }\n", "$stdout = 1")
      expect_quiet("Object.include(Writable)\n", "$stdout = 1",
                   sig: { "writable.rbs" => "module Writable\n  def write: (*untyped) -> Integer\nend\n" })
    end

    it "declines on a project module that defines the method, which any `include` can mix in" do
      expect_quiet("module Out\n  def write(*) = 0\nend\ninclude Out\n", "$stdout = 1")
    end

    it "declines on a module an ancestor mixes in that RBS declares with the method, or does not know" do
      expect_quiet("class Integer\n  include Writable\nend\n", "$stdout = 1",
                   sig: { "writable.rbs" => "module Writable\n  def write: (*untyped) -> Integer\nend\n" })
      expect_quiet("class Integer\n  include Nowhere\nend\n", "$stdout = 1")
      expect_quiet("class Integer\n  include Lenient\nend\n", "$0 = 1",
                   sig: { "lenient.rbs" => "module Lenient\n  def method_missing: (Symbol, *untyped) -> untyped\nend\n" })
    end

    it "follows a project module an ancestor mixes in to the modules it mixes in" do
      expect_quiet("module Outer\n  include Writable\nend\nclass Integer\n  include Outer\nend\n", "$stdout = 1",
                   sig: { "writable.rbs" => "module Writable\n  def write: (*untyped) -> Integer\nend\n" })
    end

    it "declines on a project module an ancestor mixes in whose surface is rewritten" do
      expect_quiet("module Dyn\n  %i[write].each { |name| define_method(name) { |*| 0 } }\nend\n" \
                   "class Integer\n  include Dyn\nend\n", "$stdout = 1")
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

    it "still reports when the program defines the method only where it cannot reach the literal" do
      source = <<~RUBY
        class Recorder
          def write(*) = 0
        end

        module Unmixed
          %i[write].each { |name| define_method(name) { |*| 0 } }
        end

        $stdout = 1
      RUBY
      expect(fired(source)).to eq([[9, "global.write-type-mismatch"]])
    end
  end

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

    # A `using` of a non-constant counts every refinement as in effect in its file, but none of these refines `write`.
    it "still reports under an unresolved `using` when no refinement defines `write`" do
      expect(fired("using Module.new { refine(String) { def shout = upcase } }\n$stdout = 1\n"))
        .to eq([[2, "global.write-type-mismatch"]])
    end

    # `fixtures/special_global_writes/refined_literals.rb` pins where the refinement is and is not in effect; this
    # pins the answer a direct caller that builds no lexical sites gets.
    it "declines for a caller that passes no lexical sites" do
      tree = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: Rigor::Scope.empty)
      write = tree.statements.body.last
      expect(Rigor::Analysis::CheckRules.main_pass_node_diagnostics("mem.rb", write, index)).to be_empty
    end
  end

  # An alias in one file exempts the special in every file, so an edit to the aliasing file must reach the writing
  # file on a warm run: nothing in the writing file changed, and no method or class moved.
  describe "an alias edited between runs" do
    around do |example|
      Dir.mktmpdir("rigor-global-alias-") { |dir| Dir.chdir(dir) { example.run } }
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

    it "re-checks the writing file under --incremental when another file aliases the special, and when it stops" do
      write("lib/a.rb", "x = 1\n")
      write("lib/w.rb", "$stdout = 1\n")
      expect(incremental_rows).to eq([fires, false])

      write("lib/a.rb", "alias $captured $stdout\n")
      expect(incremental_rows).to eq([[], true])

      write("lib/a.rb", "x = 1\n")
      expect(incremental_rows).to eq([fires, true])
    end

    # The aliasing file is unchanged, so the warm run restores its names from its seed bundle.
    it "serves an unchanged aliasing file's names from its seed bundle" do
      write("lib/a.rb", "alias $stdout $captured\n")
      write("lib/w.rb", "$stdout = 1\n")
      expect(incremental_rows).to eq([[], false])

      write("lib/w.rb", "$stdout = 1\n$stdout = 2\n")
      expect(incremental_rows).to eq([[], true])
    end

    it "re-checks the writing file when another file reopens the literal's class with the method" do
      write("lib/a.rb", "x = 1\n")
      write("lib/w.rb", "$stdout = 1\n")
      expect(incremental_rows).to eq([fires, false])

      write("lib/a.rb", "class Integer\n  def write(*) = 0\nend\n")
      expect(incremental_rows).to eq([[], true])
    end

    it "re-checks the writing file when a refinement it uses gains `write`" do
      write("lib/a.rb", "module Writer\n  refine(Array) { def shout = 1 }\nend\n")
      write("lib/w.rb", "using Writer\n$stdout = []\n")
      expect(incremental_rows).to eq([[["w.rb", 2, "global.write-type-mismatch"]], false])

      write("lib/a.rb", "module Writer\n  refine(Array) { def write(*) = 0 }\nend\n")
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
