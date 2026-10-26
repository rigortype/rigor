# frozen_string_literal: true

# Issue #2314 — the statement walk kept a global's binding past any call, so `$g = nil; reset!; $g + 1`, with
# `reset!` assigning `$g`, reported `undefined method '+' for nil` where Ruby answers 2. A global's binding now ends
# at a call that may reach a project method writing it (`GlobalWriterReach`), and a global no reachable method writes
# keeps it. A `case` whose `when` test may rebind a global subject asks the same question (issue #2211). Each row's
# comment gives what Ruby 4.0.5 answers.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a global's binding past a call that may reach its writer (#2314)" do
  def configuration(paths)
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => paths, "workers" => 0))
  end

  # The `[file, line]` of each `call.undefined-method` a cold run over `files` reports.
  def undefined(files)
    files.each { |name, source| File.write(name, source) }
    paths = files.keys
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration(paths), cache_store: nil), paths)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }
  end

  around do |example|
    Dir.mktmpdir("rigor-global-after-call-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "forgets a global a called method writes" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      def reset! = ($g = 1)
      $g = nil
      reset!
      $g + 1
    RUBY
  end

  it "keeps a global no project method writes" do
    # NoMethodError
    expect(undefined("a.rb" => <<~RUBY)).to eq([["a.rb", 4]])
      def noop = 1
      $h = nil
      noop
      $h + 1
    RUBY
  end

  it "keeps a global past a project call that reaches none of its writers" do
    # NoMethodError: `noop` does not reach `reset!`
    expect(undefined("a.rb" => <<~RUBY)).to eq([["a.rb", 5]])
      def reset! = ($h = 1)
      def noop = 1
      $h = nil
      noop
      $h + 1
    RUBY
  end

  it "forgets a global a method writes through a chain of project methods" do
    # 3
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      def a1 = b1
      def b1 = ($k = 2)
      $k = nil
      a1
      $k + 1
    RUBY
  end

  it "forgets a global a method writes in a block the callee yields to" do
    # 4
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      def each_thing = yield
      def bw = ($bw = 3)
      $bw = nil
      each_thing { bw }
      $bw + 1
    RUBY
  end

  it "forgets a global a method of another class writes" do
    # 5
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      class Resetter
        def go = ($oc = 4)
      end
      $oc = nil
      Resetter.new.go
      $oc + 1
    RUBY
  end

  it "forgets a global a method sent by a literal name writes" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      def sl = ($sl = 1)
      $sl = nil
      send(:sl)
      $sl + 1
    RUBY
  end

  it "forgets a global a define_method block writes, by the name it defines" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      class Box
        define_method(:dmw) { $dm = 1 }
      end
      $dm = nil
      Box.new.dmw
      $dm + 1
    RUBY
  end

  it "forgets a global a lambda writes, past any call that may run project code" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      HOOK = -> { $lh = 1 }
      def run_hook = HOOK.call
      $lh = nil
      run_hook
      $lh + 1
    RUBY
  end

  it "forgets a global past the value of an assignment that calls its writer" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      def ar = ($ar = 1)
      $ar = nil
      x = ar
      $ar + 1
    RUBY
  end

  # #2260's policy: a call whose receiver no target resolves may run any method, so it reaches any writer.
  it "forgets a global past a call on a Dynamic receiver when a project method writes it" do
    # 2 when `o.anything` calls `dyn_writer`
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      def dyn_writer = ($dy = 1)
      def dyn(o)
        $dy = nil
        o.anything
        $dy + 1
      end
    RUBY
  end

  it "keeps a global past core and standard-library calls" do
    # NoMethodError
    expect(undefined("a.rb" => <<~RUBY)).to eq([["a.rb", 5]])
      def other_writer = ($cs = 1)
      $cs = nil
      puts "x"
      [1].map { |i| i + 1 }
      $cs + 1
    RUBY
  end

  it "keeps a global a lambda writes past core and standard-library calls" do
    # NoMethodError
    expect(undefined("a.rb" => <<~RUBY)).to eq([["a.rb", 4]])
      HOOK = -> { $cl = 1 }
      $cl = nil
      puts "x"
      $cl + 1
    RUBY
  end

  it "keeps a write in the same method past a call that reaches no writer" do
    # NoMethodError: `m_same` writes `$sm`, but `helper` does not reach it
    expect(undefined("a.rb" => <<~RUBY)).to eq([["a.rb", 4]])
      def m_same
        $sm = nil
        helper
        $sm + 1
      end
      def helper = 1
    RUBY
  end

  it "forgets a global a method in another file writes" do
    # 2
    expect(undefined("writer.rb" => <<~WRITER, "use.rb" => <<~USE)).to eq([])
      module Other
        def self.set_mf = ($mf = 1)
      end
    WRITER
      $mf = nil
      Other.set_mf
      $mf + 1
    USE
  end

  it "keeps a global past a call that reaches none of the methods a define_method block defines" do
    # NoMethodError
    expect(undefined("a.rb" => <<~RUBY)).to eq([["a.rb", 7]])
      class Box
        define_method(:dmw) { $dk = 1 }
        def other = 1
      end
      $dk = nil
      Box.new.other
      $dk + 1
    RUBY
  end

  it "follows a block argument's Symbol to the method it names" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      class W
        def touch = ($bt = 1)
      end
      $bt = nil
      [W.new].each(&:touch)
      $bt + 1
    RUBY
  end

  it "follows the operator a compound write calls" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      class Counter
        def +(other) = ($op = 1)
      end
      def bump(c) = (c += 1)
      $op = nil
      bump(Counter.new)
      $op + 1
    RUBY
  end

  it "follows the each a for loop calls" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      class Coll
        def each = ($fe = 1)
      end
      def walk(xs) = (for x in xs; end)
      $fe = nil
      walk(Coll.new)
      $fe + 1
    RUBY
  end

  it "reaches any writer from an eval" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      def w = ($ev = 1)
      def run(code) = eval(code)
      $ev = nil
      run("w")
      $ev + 1
    RUBY
  end

  it "follows a name no project def defines to method_missing" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      class MM
        def method_missing(*) = ($mm = 1)
      end
      $mm = nil
      MM.new.undefined_thing
      $mm + 1
    RUBY
  end

  it "follows new to initialize" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      class C
        def initialize = ($i = 1)
      end
      $i = nil
      C.new
      $i + 1
    RUBY
  end

  it "follows an alias_method name to the method it names" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      class D
        def reset! = ($ra = 1)
        alias_method :ra, :reset!
      end
      $ra = nil
      D.new.ra
      $ra + 1
    RUBY
  end

  it "follows an alias name to the method it names" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      class E
        def reset! = ($rb = 1)
        alias rb reset!
      end
      $rb = nil
      E.new.rb
      $rb + 1
    RUBY
  end

  it "follows a def_delegator alias to the method it delegates to" do
    # 2
    expect(undefined("a.rb" => <<~RUBY)).to eq([])
      require "forwardable"
      class Inner
        def reset! = ($fd = 1)
      end
      class F
        extend Forwardable
        def initialize = (@in = Inner.new)
        def_delegator :@in, :reset!, :rf
      end
      f = F.new
      $fd = nil
      f.rf
      $fd + 1
    RUBY
  end

  it "does not read a nested def's body, which runs nothing where it is defined" do
    # NoMethodError: `setup_later` defines `later` without calling `reset_g`
    expect(undefined("a.rb" => <<~RUBY)).to eq([["a.rb", 7]])
      def setup_later
        def later = reset_g
      end
      def reset_g = ($ng = 1)
      $ng = nil
      setup_later
      $ng + 1
    RUBY
  end

  it "keeps $_, which a method writes in its own frame" do
    # NoMethodError
    expect(undefined("a.rb" => <<~RUBY)).to eq([["a.rb", 4]])
      def mfl = ($_ = "x")
      $_ = nil
      mfl
      $_ + 1
    RUBY
  end

  # Guard: past DEF_BUDGET bodies the search gives up and forgets, reading less than Ruby proves.
  it "forgets past the search budget even when no writer is reached" do
    # NoMethodError in Ruby; quiet past the budget
    expect(undefined("a.rb" => "def w = ($bg = 1)\ndef d0 = d1\ndef d1 = d2\ndef d2 = d3\ndef d3 = d4\ndef d4 = d5\ndef d5 = d6\ndef d6 = d7\ndef d7 = d8\ndef d8 = d9\ndef d9 = d10\ndef d10 = d11\ndef d11 = d12\ndef d12 = d13\ndef d13 = d14\ndef d14 = d15\ndef d15 = d16\ndef d16 = d17\ndef d17 = d18\ndef d18 = d19\ndef d19 = d20\ndef d20 = d21\ndef d21 = d22\ndef d22 = d23\ndef d23 = d24\ndef d24 = d25\ndef d25 = d26\ndef d26 = d27\ndef d27 = d28\ndef d28 = d29\ndef d29 = d30\ndef d30 = d31\ndef d31 = d32\ndef d32 = d33\ndef d33 = d34\ndef d34 = d35\ndef d35 = d36\ndef d36 = d37\ndef d37 = d38\ndef d38 = d39\ndef d39 = d40\ndef d40 = d41\ndef d41 = d42\ndef d42 = d43\ndef d43 = d44\ndef d44 = d45\ndef d45 = d46\ndef d46 = d47\ndef d47 = d48\ndef d48 = d49\ndef d49 = d50\ndef d50 = d51\ndef d51 = d52\ndef d52 = d53\ndef d53 = d54\ndef d54 = d55\ndef d55 = d56\ndef d56 = d57\ndef d57 = d58\ndef d58 = d59\ndef d59 = d60\ndef d60 = d61\ndef d61 = d62\ndef d62 = d63\ndef d63 = d64\ndef d64 = d65\ndef d65 = d66\ndef d66 = d67\ndef d67 = d68\ndef d68 = d69\ndef d69 = 1\n$bg = nil\nd0\n$bg + 1\n")).to eq([])
  end

  # Known gap: `alias $ay $ax` makes the two one variable, and the census keys a writer by the name it spells.
  it "keeps an aliased global a method writes under its other name" do
    # 2 in Ruby; still reported
    expect(undefined("a.rb" => <<~RUBY)).to eq([["a.rb", 5]])
      def aw = ($ax = 1)
      alias $ay $ax
      $ay = nil
      aw
      $ay + 1
    RUBY
  end

  describe "a case whose when test calls a method (#2211)" do
    it "forgets a global subject a when test's method writes" do
      # 2
      expect(undefined("a.rb" => <<~RUBY)).to eq([])
        def cw_reset = ($cw = 1)
        $cw = nil
        case $cw
        when String then 1
        when cw_reset then 2
        else $cw + 1
        end
      RUBY
    end

    it "keeps a global subject past a when test whose method reaches no writer" do
      # NoMethodError
      expect(undefined("a.rb" => <<~RUBY)).to eq([["a.rb", 7]])
        def cw_noop = 1
        def cw_reset = ($cw = 1)
        $cw = nil
        case $cw
        when String then 1
        when cw_noop then 2
        else $cw + 1
        end
      RUBY
    end
  end

  # The writer census and the bodies the search reads are cross-file reads: an edit to the writer re-checks the
  # reader, which then answers as a cold run does.
  describe "an incremental recheck" do
    def session_for(dir)
      Rigor::Analysis::IncrementalSession.new(configuration: configuration([dir]), paths: [dir])
    end

    def reported(diagnostics)
      diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }
    end

    def expect_edit(files:, edited:, after:, first:, second:)
      Dir.mktmpdir do |dir|
        files.each { |name, source| File.write(File.join(dir, name), source) }
        session = session_for(dir)
        expect(reported(guarded_baseline(session).to_a)).to eq(first)

        File.write(File.join(dir, edited), after)
        recheck = guarded_recheck(session)
        expect(recheck.affected).to include(File.join(dir, "use.rb"))
        expect(reported(recheck.diagnostics)).to eq(second)
      end
    end

    let(:use) { "$g = nil\nreset!\n$g + 1\n" }

    it "forgets the global once the called method starts writing it" do
      expect_edit(files: { "use.rb" => use, "other.rb" => "def reset! = 1\n" }, edited: "other.rb",
                  after: "def reset! = ($g = 1)\n", first: [["use.rb", 3]], second: [])
    end

    it "keeps the global once the called method stops writing it" do
      expect_edit(files: { "use.rb" => use, "other.rb" => "def reset! = ($g = 1)\n" }, edited: "other.rb",
                  after: "def reset! = 1\n", first: [], second: [["use.rb", 3]])
    end

    it "forgets a case subject once a when test's method starts writing it" do
      use = "$g = nil\ncase $g\nwhen String then 1\nwhen reset! then 2\nelse $g + 1\nend\n"
      expect_edit(files: { "use.rb" => use, "other.rb" => "def reset! = 1\n" }, edited: "other.rb",
                  after: "def reset! = ($g = 2)\n", first: [["use.rb", 5]], second: [])
    end

    it "forgets the global once a method the search follows by name is defined" do
      use = "def bar = baz\n$g = nil\nbar\n$g + 1\n"
      expect_edit(files: { "use.rb" => use, "other.rb" => "\n", "writer.rb" => "def w = ($g = 2)\n" },
                  edited: "other.rb", after: "def baz = w\n", first: [["use.rb", 4]], second: [])
    end

    it "forgets the global once an alias names its writer" do
      use = "$g = nil\nD.new.ra\n$g + 1\n"
      expect_edit(files: { "use.rb" => use, "other.rb" => "class D\n  def reset! = ($g = 1)\nend\n" },
                  edited: "other.rb", after: "class D\n  def reset! = ($g = 1)\n  alias_method :ra, :reset!\nend\n",
                  first: [["use.rb", 3]], second: [])
    end

    # The search reads `o.baz` by name, on a receiver no caller types, so only its own `defines:` read re-checks.
    it "forgets the global once a method the search follows on an untyped receiver is defined" do
      use = "def bar(o) = o.baz\n$g = nil\nbar(Object.new)\n$g + 1\n"
      expect_edit(files: { "use.rb" => use, "other.rb" => "\n", "writer.rb" => "def w = ($g = 2)\n" },
                  edited: "other.rb", after: "class Q\n  def baz = w\nend\n", first: [["use.rb", 4]], second: [])
    end

    # The alias keeps its name across the edit and the search reads no body in its file, so only the
    # `method_alias:` read re-checks.
    it "forgets the global once an alias is pointed at its writer" do
      use = "def bar(o) = o.ra\n$g = nil\nbar(Object.new)\n$g + 1\n"
      before = "class Q\n  alias_method :ra, :nothing_defines_this\nend\n"
      expect_edit(files: { "use.rb" => use, "other.rb" => before, "writer.rb" => "def w = ($g = 2)\n" },
                  edited: "other.rb", after: "class Q\n  alias_method :ra, :w\nend\n",
                  first: [["use.rb", 4]], second: [])
    end

    # A `when` test that runs no statement call, so only the case site's own census read re-checks.
    it "forgets a case subject once a when lambda's method starts writing it" do
      use = "$g = nil\ncase $g\nwhen String then 1\nwhen ->(_) { reset!; false } then 2\nelse $g + 1\nend\n"
      expect_edit(files: { "use.rb" => use, "other.rb" => "def reset! = 1\n" }, edited: "other.rb",
                  after: "def reset! = ($g = 2)\n", first: [["use.rb", 5]], second: [])
    end

    it "forgets the global once the called method starts calling its writer" do
      expect_edit(files: { "use.rb" => use, "other.rb" => "def reset! = 1\n", "writer.rb" => "def b1 = ($g = 2)\n" },
                  edited: "other.rb", after: "def reset! = b1\n", first: [["use.rb", 3]], second: [])
    end
  end
end
