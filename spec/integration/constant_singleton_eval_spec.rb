# frozen_string_literal: true

# Issue #3018 — three gaps #3016 left in singleton methods defined on a constant's object.
#
# 1. `OBJ.singleton_class.class_eval { def sc = 1 }` defines `sc` on `OBJ`, and is filed under the constant as
#    `def OBJ.sc` is.
# 2. A body def typed through the constant (`class << OBJ; def each = 1; end`) is not the answer once another definer
#    of the same name on the constant may replace it (`OBJ.define_singleton_method(:each) { "s" }`, `def OBJ.each`).
# 3. A class constant's object reads the same envelope: `Foo.define_singleton_method(:x)` and `def Foo.y` define
#    singleton methods a subclass inherits.
#
# Ruby 4.0.5 runs every call these examples expect quiet, and raises NoMethodError on every one they expect reported.
# Two-file rows are witnessed with the defining file loaded before the calls.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "singleton methods on a constant's object, eval and replacing definers (#3018)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-constant-singleton-eval-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
  end

  def rows(diagnostics)
    diagnostics.select do |d|
      d.rule == "call.undefined-method"
    end.map { |d| [d.path, d.line, d.message[/`[^']+' for \S+/]] }
  end

  def cold_rows
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    rows(guarded_run(runner, %w[lib]).diagnostics).sort
  end

  describe "a def in a singleton_class eval block on a constant" do
    %i[class_eval module_eval class_exec].each do |eval_call|
      it "stays silent on a #{eval_call} def in the same file, and reports a name it does not define" do
        write("lib/obj.rb", "OBJ = Object.new\nOBJ.singleton_class.#{eval_call} { def sc = 1 }\nOBJ.sc\nOBJ.nope\n")
        expect(cold_rows).to eq([["lib/obj.rb", 4, "`nope' for Object"]])
      end
    end

    it "stays silent on a nested def in the block" do
      write("lib/obj.rb", "OBJ = Object.new\nOBJ.singleton_class.class_eval do\n  if true\n    def sc = 1\n  end\nend\n" \
                          "OBJ.sc\n")
      expect(cold_rows).to eq([])
    end

    it "stays silent on a class_eval def written in another file" do
      write("lib/use.rb", "OBJ = Object.new\nOBJ.sc\nOBJ.nope\n")
      write("lib/def.rb", "OBJ.singleton_class.class_eval { def sc = 1 }\n")
      expect(cold_rows).to eq([["lib/use.rb", 3, "`nope' for Object"]])
    end

    # `instance_eval` on the singleton class defines on that class's own singleton, so `OBJ.si` raises.
    it "still reports a def in an instance_eval block on the singleton class" do
      write("lib/obj.rb", "OBJ = Object.new\nOBJ.singleton_class.instance_eval { def si = 1 }\nOBJ.si\n")
      expect(cold_rows).to eq([["lib/obj.rb", 3, "`si' for Object"]])
    end

    # A `class` body inside the block opens another definee: its def is `Inner#inner`, not `OBJ.inner`.
    it "still reports a def inside a class body in the block" do
      write("lib/obj.rb", "OBJ = Object.new\nOBJ.singleton_class.class_eval do\n  class Inner\n    def inner = 1\n  " \
                          "end\nend\nOBJ.inner\n")
      expect(cold_rows).to eq([["lib/obj.rb", 7, "`inner' for Object"]])
    end
  end

  describe "a later definer replacing a body def on a constant" do
    {
      "define_singleton_method" => "OBJ.define_singleton_method(:each) { \"s\" }\n",
      "def OBJ.x" => "def OBJ.each = \"s\"\n"
    }.each do |spelling, replacer|
      it "does not type the call from the body def beside a #{spelling} in the same file" do
        write("lib/obj.rb", "OBJ = Object.new\nclass << OBJ\n  def each = 1\nend\n#{replacer}OBJ.each.upcase\n" \
                            "OBJ.nope\n")
        expect(cold_rows).to eq([["lib/obj.rb", 7, "`nope' for Object"]])
      end

      it "does not type the call from the body def beside a #{spelling} in another file" do
        write("lib/use.rb", "OBJ = Object.new\nclass << OBJ\n  def each = 1\nend\nOBJ.each.upcase\n")
        write("lib/def.rb", replacer)
        expect(cold_rows).to eq([])
      end
    end

    it "does not type the call beside a computed define_singleton_method" do
      write("lib/obj.rb", "OBJ = Object.new\nclass << OBJ\n  def each = 1\nend\nname = :each\n" \
                          "OBJ.define_singleton_method(name) { \"s\" }\nOBJ.each.upcase\n")
      expect(cold_rows).to eq([])
    end

    # The control: the body def alone, and beside a definer of another name, still types the call, so `upcase` on
    # its `1` reports (Ruby raises NoMethodError on `1.upcase`).
    it "keeps typing the call from a lone body def" do
      write("lib/obj.rb", "OBJ = Object.new\nclass << OBJ\n  def each = 1\nend\n" \
                          "OBJ.define_singleton_method(:other) { \"s\" }\nOBJ.each.upcase\n")
      expect(cold_rows).to eq([["lib/obj.rb", 6, "`upcase' for 1"]])
    end
  end

  describe "a class constant's singleton method defined outside its body" do
    before { write("sig/foo.rbs", "class Foo\nend\nclass Bar < Foo\nend\n") }

    it "stays silent on define_singleton_method and def Foo.y in the same file, and reports a name nothing defines" do
      write("lib/foo.rb", "class Foo; end\nFoo.define_singleton_method(:x) { 1 }\ndef Foo.y = 1\nFoo.x\nFoo.y\n" \
                          "Foo.nope\n")
      expect(cold_rows).to eq([["lib/foo.rb", 6, "`nope' for singleton(Foo)"]])
    end

    it "stays silent on the definers written in another file" do
      write("lib/foo.rb", "class Foo; end\nFoo.x\nFoo.y\nFoo.nope\n")
      write("lib/def.rb", "Foo.define_singleton_method(:x) { 1 }\ndef Foo.y = 1\n")
      expect(cold_rows).to eq([["lib/foo.rb", 4, "`nope' for singleton(Foo)"]])
    end

    it "stays silent on a subclass call, and reports a name nothing defines" do
      write("lib/foo.rb", "class Foo; end\nclass Bar < Foo; end\nFoo.define_singleton_method(:x) { 1 }\n" \
                          "def Foo.y = 1\nBar.x\nBar.y\nBar.nope\n")
      expect(cold_rows).to eq([["lib/foo.rb", 7, "`nope' for singleton(Bar)"]])
    end

    # The envelope is on the superclass's name: a definer on the subclass does not reach the superclass.
    it "still reports on the superclass a name only the subclass defines" do
      write("lib/foo.rb", "class Foo; end\nclass Bar < Foo; end\ndef Bar.y = 1\nBar.y\nFoo.y\n")
      expect(cold_rows).to eq([["lib/foo.rb", 5, "`y' for singleton(Foo)"]])
    end
  end

  describe "an incremental recheck" do
    # `paths: nil` with the configured roots is the CLI's shape, under which an added or deleted file keeps the run
    # warm.
    def incremental_rows
      root = File.join(Dir.pwd, ".rigor", "cache")
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: %w[lib])
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: nil,
                                                        cache_store: Rigor::Cache::Store.new(root: root))
      diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
      [rows(diagnostics).sort, warm]
    end

    {
      "singleton_class.class_eval def" => [
        "OBJ = Object.new\nOBJ.each\n", "OBJ.singleton_class.class_eval { def each = 1 }\n",
        [["lib/use.rb", 2, "`each' for Object"]]
      ],
      "replacing define_singleton_method" => [
        "OBJ = Object.new\nclass << OBJ\n  def each = 1\nend\nOBJ.each.upcase\n",
        "OBJ.define_singleton_method(:each) { \"s\" }\n", [["lib/use.rb", 5, "`upcase' for 1"]]
      ],
      "class-object def Foo.y" => [
        "class Foo; end\nFoo.y\n", "def Foo.y = 1\n", [["lib/use.rb", 2, "`y' for singleton(Foo)"]]
      ]
    }.each do |spelling, (use, definition, reported)|
      it "agrees with a cold run when a file with a #{spelling} is added and removed" do
        write("sig/foo.rbs", "class Foo\nend\n")
        write("lib/use.rb", use)
        expect(incremental_rows).to eq([reported, false])

        write("lib/def.rb", definition)
        expect(incremental_rows).to eq([[], true])
        expect(cold_rows).to eq([])

        File.delete("lib/def.rb")
        expect(incremental_rows).to eq([reported, true])
        expect(cold_rows).to eq(reported)
      end
    end
  end
end
