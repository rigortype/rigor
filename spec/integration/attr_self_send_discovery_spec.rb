# frozen_string_literal: true

# Issue #2097 — source-method discovery records the members an `attr_reader` / `attr_writer` / `attr_accessor`
# declares when the call is written as `self.attr_accessor :x` or as `send` / `public_send` / `__send__` with the
# macro's literal name (`send(:attr_accessor, :x)`), as it does for the implicit-self `attr_accessor :x`. Without
# it a `sig/` that declares the class but not the accessor (what `rigor sig-gen --write` produces) made every call
# to one a `call.undefined-method`. Ruby 4.0.5 runs every call these examples expect quiet, and raises
# NoMethodError on every one they expect reported.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "attr members declared through self. or send (#2097)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-attr-self-send-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # What `rigor sig-gen --write` writes for these classes: `initialize` and nothing else.
  let(:sig) { "class Box\n  def initialize: () -> void\nend\n" }

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration(workers: 0)
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => workers)
    )
  end

  def rows(diagnostics, rule: "call.undefined-method")
    diagnostics.select { |d| d.rule == rule }.map { |d| [d.path, d.line, d.message[/`[^']+'/]] }.sort
  end

  def cold_rows(workers: 0, rule: "call.undefined-method")
    runner = Rigor::Analysis::Runner.new(configuration: configuration(workers: workers), cache_store: nil)
    rows(guarded_run(runner, %w[lib]).diagnostics, rule: rule)
  end

  def box(*body) = "class Box\n  def initialize = nil\n#{body.map { |line| "  #{line}\n" }.join}end\n"

  {
    "self." => ->(macro, name) { "self.#{macro} :#{name}" },
    "send" => ->(macro, name) { "send(:#{macro}, :#{name})" },
    "public_send" => ->(macro, name) { "public_send(:#{macro}, \"#{name}\")" },
    "__send__" => ->(macro, name) { "__send__(\"#{macro}\", :#{name})" },
    "self.send" => ->(macro, name) { "self.send(:#{macro}, :#{name})" }
  }.each do |spelling, declare|
    it "records each attr macro written with #{spelling}, and still reports a name none declares" do
      write("sig/box.rbs", sig)
      write("lib/box.rb", box(declare.call(:attr_reader, :r), declare.call(:attr_writer, :w),
                              declare.call(:attr_accessor, :a)))
      write("lib/use.rb", "b = Box.new\nb.r\nb.w = 1\nb.a = 2\nb.a\nb.nope\n")
      expect(cold_rows).to eq([["lib/use.rb", 6, "`nope'"]])
    end
  end

  # `send`'s first argument is the macro, not a member: Ruby defines no `attr_writer=` on the instance.
  it "records the writer half only for attr_writer and the reader half only for attr_reader" do
    write("sig/box.rbs", sig)
    write("lib/box.rb", box("self.attr_reader :r", "send(:attr_writer, :w)"))
    write("lib/use.rb", "b = Box.new\nb.r = 1\nb.w\nb.attr_writer = 1\n")
    expect(cold_rows).to eq([["lib/use.rb", 2, "`r='"], ["lib/use.rb", 3, "`w'"], ["lib/use.rb", 4, "`attr_writer='"]])
  end

  # Guard: without a sig the rule does not speak about a source-only class, before #2097 or after.
  it "is quiet without a sig" do
    write("lib/box.rb", box("self.attr_accessor :a", "send(:attr_reader, :r)"))
    write("lib/use.rb", "b = Box.new\nb.a = 1\nb.a\nb.r\n")
    FileUtils.mkdir_p("sig")
    expect(cold_rows).to eq([])
  end

  # The placement the implicit-self form has: a call under a conditional or in a block on the class body records,
  # one in a `def` body does not (Ruby raises there: an instance has no `attr_reader`).
  it "records a call under a conditional or in a block on the body, and not one in a def body" do
    write("sig/box.rbs", sig)
    write("lib/box.rb", box("if ENV[\"X\"].nil?", "  self.attr_reader :c", "end", "[1].each { send(:attr_reader, :b) }",
                            "def m = self.attr_reader(:d)"))
    write("lib/use.rb", "b = Box.new\nb.c\nb.b\nb.d\n")
    expect(cold_rows).to eq([["lib/box.rb", 7, "`attr_reader'"], ["lib/use.rb", 4, "`d'"]])
  end

  it "records the singleton members a class << self body declares with self. or send" do
    write("sig/box.rbs", sig)
    write("lib/box.rb", box("class << self", "  self.attr_accessor :conf", "  send(:attr_reader, :level)", "end"))
    write("lib/use.rb", "Box.conf = 1\nBox.conf\nBox.level\nBox.nope\nBox.new.conf\n")
    expect(cold_rows).to eq([["lib/use.rb", 4, "`nope'"], ["lib/use.rb", 5, "`conf'"]])
  end

  # Ruby 4.0.5 makes `count` and `count=` private under a bare `private` in every spelling, and makes
  # `wrapped` private when `private` wraps the macro call.
  it "gives each spelling the running default visibility, and the wrapping call's" do
    write("lib/box.rb", box("private", "self.attr_accessor :count", "send(:attr_reader, :sent)", "public",
                            "private self.attr_reader(:wrapped)", "self.attr_reader :open"))
    write("lib/use.rb", "b = Box.new\nb.count = 1\nb.sent\nb.wrapped\nb.open\n")
    FileUtils.mkdir_p("sig")

    expect(cold_rows(rule: "def.method-visibility-mismatch").map { |path, line, _| [path, line] })
      .to eq([["lib/use.rb", 2], ["lib/use.rb", 3], ["lib/use.rb", 4]])
  end

  # Guard: a name `send` passes as a variable is not one discovery can read, and with a sig the call reports
  # before and after #2097 alike.
  it "records nothing for a non-literal name passed through send" do
    write("sig/box.rbs", sig)
    write("lib/box.rb", box("name = :foo", "send(:attr_accessor, name)"))
    write("lib/use.rb", "Box.new.foo\n")
    expect(cold_rows).to eq([["lib/use.rb", 1, "`foo'"]])
  end

  it "reads the declaration across files with two workers" do
    write("sig/box.rbs", sig)
    write("lib/box.rb", box("self.attr_accessor :a", "send(:attr_reader, :r)"))
    write("lib/use.rb", "b = Box.new\nb.a = 1\nb.a\nb.r\nb.nope\n")
    expect(cold_rows(workers: 2)).to eq([["lib/use.rb", 5, "`nope'"]])
  end

  # Issue #1989's supersession: Ruby 4.0.5 answers "s" from the reader the macro installs over `def x = 1`.
  it "types the reader from a self. or send attr_reader that follows the def" do
    write("lib/k.rb", <<~RUBY)
      class K
        def x = 1
        self.attr_reader :x
        def initialize = (@x = "s")
      end
      K.new.x.upcase
      class J
        def x = 1
        send(:attr_reader, :x)
        def initialize = (@x = "s")
      end
      J.new.x.upcase
    RUBY
    FileUtils.mkdir_p("sig")
    expect(cold_rows).to eq([])
  end

  # Issue #541's ivar seed: the writer the macro installs may set `@cb` from outside, so `if c` is not always
  # falsey (Ruby 4.0.5 runs the callback after `radio.cb = ->(v) { v }`).
  it "counts a self. or send attr_writer as a write to its ivar" do
    radio = lambda do |name, declaration|
      "class #{name}\n  #{declaration}\n  def initialize = @cb = nil\n  " \
        "def deliver(v)\n    c = @cb\n    c.call(v) if c\n  end\nend\n"
    end
    write("lib/radio.rb",
          radio.call("Radio", "self.attr_accessor :cb") + radio.call("Radio2", "send(:attr_writer, :cb)"))
    FileUtils.mkdir_p("sig")
    expect(cold_rows(rule: "flow.always-truthy-condition")).to eq([])
  end

  # `:fresh_rbs_env` (#2121): the spec-only `RbsEnvMemo` keys a build on the relative `sig/box.rbs` and its
  # bytes, so an earlier example's environment answers this one's; under it the warm run reuses `lib/use.rb`
  # after the removal, with the implicit-self `attr_*` as with these spellings. `RIGOR_SPEC_NO_ENV_MEMO=1`
  # gives the rows below either way.
  describe "an incremental recheck", :fresh_rbs_env do
    let(:paths) { %w[lib/box.rb lib/use.rb] }

    def incremental_rows
      root = File.join(Dir.pwd, ".rigor", "cache")
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths,
                                                        cache_store: Rigor::Cache::Store.new(root: root))
      diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
      [rows(diagnostics), warm]
    end

    def expect_transition(before:, after:, expected:)
      write("sig/box.rbs", sig)
      write("lib/box.rb", before)
      write("lib/use.rb", "b = Box.new\nb.a = 1\nb.r\n")
      _, warm = incremental_rows
      expect(warm).to be(false)

      write("lib/box.rb", after)
      expect(incremental_rows).to eq([expected, true])
      expect(cold_rows).to eq(expected)
    end

    it "drops the report when the declaration is added" do
      expect_transition(before: box, after: box("self.attr_accessor :a", "send(:attr_reader, :r)"), expected: [])
    end

    # Guard: the rows after the removal are master's, so this passes without #2097's fix too.
    it "reports again when the declaration is removed" do
      expect_transition(before: box("self.attr_accessor :a", "send(:attr_reader, :r)"), after: box,
                        expected: [["lib/use.rb", 2, "`a='"], ["lib/use.rb", 3, "`r'"]])
    end
  end
end
