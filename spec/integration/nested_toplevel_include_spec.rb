# frozen_string_literal: true

# Issue #3007 — a top-level `include M1` that is not itself a program statement is still `main.include` when only
# control flow wraps it (`if`, `begin`, `unless`, `case`) or it sits in a top-level `def` body: it mixes M1 into
# `Object`, as a program-statement `include M1` does (#1697), in every spelling #2995 records (bare, `self.`, `send`).
# Such an include may not run, so it is recorded in the set with no position, as ADR-119 WD7 records one in a method
# body. A call on a class, or on a module's class object, to M1's method must not report `call.undefined-method`; a
# name M1 lacks still does. `sig/` declares every class, empty, so RBS answers no call.
#
# Every row's Ruby behaviour was witnessed on Ruby 4.0.5 (with each `def setup` called after it): each quiet call
# returns 1, and each reported call raises `NoMethodError`.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "a top-level include under control flow mixes into Object (#3007)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-nested-toplevel-include-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:mods) { "module M1\n  def m1 = 1\nend\n" }
  let(:sig) { "class W\nend\nmodule N\nend\n" }
  let(:users) { "class W\n  def t = self.m1\nend\nmodule N\n  def self.s = self.m1\nend\n" }

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
  end

  def messages(diagnostics)
    diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  def undefined_messages(files)
    write("sig/types.rbs", sig)
    files.each { |name, source| write(File.join("lib", name), source) }
    messages(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
               .diagnostics)
  end

  def unfixed = ["undefined method `m1' for W", "undefined method `m1' for singleton(N)"]

  {
    "if" => ->(call) { "if ENV[\"PATH\"]\n  #{call}\nend\n" },
    "begin" => ->(call) { "begin\n  #{call}\nend\n" },
    "unless" => ->(call) { "unless ENV[\"NO_SUCH_VARIABLE\"]\n  #{call}\nend\n" },
    "case" => ->(call) { "case ENV[\"PATH\"]\nwhen String\n  #{call}\nend\n" },
    "a modifier if" => ->(call) { "#{call} if ENV[\"PATH\"]\n" },
    "a top-level def" => ->(call) { "def setup\n  #{call}\nend\nsetup\n" },
    "a top-level def self." => ->(call) { "def self.setup\n  #{call}\nend\nsetup\n" }
  }.each do |wrapper, wrap|
    ["include M1", "self.include M1", "send(:include, M1)"].each do |call|
      it "does not fire after `#{call}` in #{wrapper}, in one file" do
        expect(undefined_messages({ "a.rb" => mods + wrap.call(call) + users })).to be_empty
      end

      it "does not fire after `#{call}` in #{wrapper}, with the users in another file" do
        expect(undefined_messages({ "m.rb" => mods + wrap.call(call), "w.rb" => users })).to be_empty
      end
    end
  end

  ["include M1", "self.include M1", "send(:include, M1)"].each do |call|
    it "fires after `#{call}` in `if` for a method M1 does not define" do
      files = { "m.rb" => "#{mods}if ENV[\"PATH\"]\n  #{call}\nend\n",
                "w.rb" => "class W\n  def w = self.m2\nend\nmodule N\n  def self.x = self.m2\nend\n" }
      expect(undefined_messages(files)).to eq(["undefined method `m2' for W", "undefined method `m2' for singleton(N)"])
    end
  end

  # Guards: each keeps reporting. `public_send` raises (`main`'s `include` is private), `self.extend` /
  # `send(:extend)` reach `main`'s singleton alone, `main` has no `prepend`, `class << self` includes into `main`'s
  # singleton, and `def OBJ.setup` runs with `OBJ` as `self`; Ruby 4.0.5 raises `NoMethodError` for `W.new.t` after
  # each. The two block rows are a known limit, not Ruby's answer: `[1].each` keeps `main` as `self`, so Ruby returns
  # 1, but the walk cannot tell such a block from one that rebinds `self` (`describe do … end`), and recording every
  # top-level block's `include` would mix its module into `Object` for every spec file's example group (#1697).
  {
    "public_send in if" => "if ENV[\"PATH\"]\n  public_send(:include, M1)\nend\n",
    "self.extend in if" => "if ENV[\"PATH\"]\n  self.extend M1\nend\n",
    "send(:extend) in begin" => "begin\n  send(:extend, M1)\nend\n",
    "self.prepend in begin" => "begin\n  self.prepend M1\nend\n",
    "a block" => "[1].each do\n  include M1\nend\n",
    "a block under if" => "if ENV[\"PATH\"]\n  [1].each { include M1 }\nend\n",
    "class << self in if" => "if ENV[\"PATH\"]\n  class << self\n    include M1\n  end\nend\n",
    "def on another receiver" => "OBJ = Object.new\ndef OBJ.setup\n  include M1\nend\n"
  }.each do |label, source|
    it "fires after #{label}, which mixes nothing into Object" do
      expect(undefined_messages({ "m.rb" => mods + source, "w.rb" => users })).to eq(unfixed)
    end
  end

  describe "--incremental" do
    def cold_messages
      messages(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
                 .diagnostics)
    end

    def incremental_messages(paths)
      root = File.join(Dir.pwd, ".rigor", "cache")
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths,
                                                        cache_store: Rigor::Cache::Store.new(root: root))
      diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
      [messages(diagnostics), warm]
    end

    it "serves what a cold run reports as a conditional include is added and then removed" do
      write("sig/types.rbs", sig)
      write("lib/m.rb", mods)
      write("lib/w.rb", users)
      paths = %w[lib/m.rb lib/w.rb]
      expect(incremental_messages(paths)).to eq([unfixed, false])
      expect(cold_messages).to eq(unfixed)

      write("lib/m.rb", "#{mods}if ENV[\"PATH\"]\n  include M1\nend\n")
      expect(incremental_messages(paths)).to eq([[], true])
      expect(cold_messages).to eq([])

      write("lib/m.rb", mods)
      expect(incremental_messages(paths)).to eq([unfixed, true])
      expect(cold_messages).to eq(unfixed)
    end
  end
end
