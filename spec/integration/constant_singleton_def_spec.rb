# frozen_string_literal: true

# Issue #3016 — a constant that holds a plain object (`OBJ = Object.new`) types as `Object`, so a call through it to a
# singleton method `def OBJ.x` or `OBJ.define_singleton_method(:x)` defines was judged against `Object` and reported
# `call.undefined-method`. The #320 recovery reads the receiver's constant name from the syntax, and now accepts the
# singleton envelope those two spellings file on the constant. A name nothing defines on the constant still reports.
# Ruby 4.0.5 runs every call these examples expect quiet, and raises NoMethodError on every one they expect reported.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "singleton methods defined on a constant's object (#3016)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-constant-singleton-def-") { |dir| Dir.chdir(dir) { example.run } }
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
    diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [d.path, d.line, d.message[/`[^']+'/]] }
  end

  def cold_rows
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    rows(guarded_run(runner, %w[lib]).diagnostics).sort
  end

  {
    "def OBJ.x" => "def OBJ.each(&b) = b.call(1)\n",
    "define_singleton_method" => "OBJ.define_singleton_method(:each) { |&b| b.call(1) }\n",
    "class << OBJ" => "class << OBJ\n  def each(&b) = b.call(1)\nend\n"
  }.each do |spelling, definition|
    it "stays silent on a #{spelling} in the same file, and reports a name it does not define" do
      write("lib/obj.rb", "OBJ = Object.new\n#{definition}OBJ.each { |x| x }\nOBJ.nope\n")
      expect(cold_rows).to eq([["lib/obj.rb", 3 + definition.count("\n"), "`nope'"]])
    end

    # The calls sit in the constant's own file: a read of a constant another file assigns does not type as `Object`.
    it "stays silent on a #{spelling} written in another file" do
      write("lib/use.rb", "OBJ = Object.new\nOBJ.each { |x| x }\nOBJ.nope\n")
      write("lib/def.rb", definition)
      expect(cold_rows).to eq([["lib/use.rb", 3, "`nope'"]])
    end
  end

  # The recovery is keyed on the constant: another plain object reports the name `OBJ` defines.
  it "still reports the name on a sibling constant with no such def" do
    write("lib/obj.rb", "OBJ = Object.new\ndef OBJ.each = 1\nOther = Object.new\nOther.each\n")
    expect(cold_rows).to eq([["lib/obj.rb", 4, "`each'"]])
  end

  it "stays silent on a def through a namespaced constant" do
    write("lib/obj.rb", "module NS\n  OBJ = Object.new\n  def OBJ.x = 6\nend\nNS::OBJ.x\nNS::OBJ.nope\n")
    expect(cold_rows).to eq([["lib/obj.rb", 6, "`nope'"]])
  end

  # A computed name may define any name on the object, so every call through the constant is quiet, `OBJ.nope`
  # included: Ruby runs `OBJ.each` here, and which names exist depends on the value of `name`.
  it "stays silent on every call through a define_singleton_method with a computed name" do
    write("lib/obj.rb", "OBJ = Object.new\nname = :each\nOBJ.define_singleton_method(name) { 1 }\nOBJ.each\nOBJ.nope\n")
    expect(cold_rows).to eq([])
  end

  # The open set is the computed definer's alone: a literal one, a `def OBJ.x` and a non-defining rewrite such as
  # `OBJ.send(:frozen?)` leave an undefined name reporting.
  it "still reports a name beside a literal definer, a def and a send" do
    write("lib/obj.rb", "OBJ = Object.new\ndef OBJ.each = 1\nOBJ.define_singleton_method(:other) { 2 }\n" \
                        "OBJ.send(:frozen?)\nOBJ.each\nOBJ.other\nOBJ.nope\n")
    expect(cold_rows).to eq([["lib/obj.rb", 7, "`nope'"]])
  end

  it "stays silent on a def OBJ.x whose object's class the sig declares without it" do
    write("sig/bar.rbs", "class Bar\nend\n")
    write("lib/obj.rb", "class Bar\nend\nOBJ = Bar.new\ndef OBJ.extra = 4\nOBJ.extra\nOBJ.nope\n")
    expect(cold_rows).to eq([["lib/obj.rb", 6, "`nope'"]])
  end

  # Guard: a module's own `def self.x` is a recorded singleton method, before #3016 or after.
  it "stays silent on def self.x of a module constant" do
    write("lib/obj.rb", "module M\n  def self.x = 5\nend\nM.x\n")
    expect(cold_rows).to eq([])
  end

  describe "an incremental recheck" do
    let(:reported) { [["lib/use.rb", 2, "`each'"]] }

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
      "def OBJ.x" => "def OBJ.each = 1\n",
      "define_singleton_method" => "OBJ.define_singleton_method(:each) { 1 }\n",
      "computed define_singleton_method" => "name = :each\nOBJ.define_singleton_method(name) { 1 }\n"
    }.each do |spelling, definition|
      it "silences the call when a file with a #{spelling} is added, and reports it again when it is removed" do
        write("lib/use.rb", "OBJ = Object.new\nOBJ.each\n")
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
