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

    it "forgets the global once the called method starts calling its writer" do
      expect_edit(files: { "use.rb" => use, "other.rb" => "def reset! = 1\n", "writer.rb" => "def b1 = ($g = 2)\n" },
                  edited: "other.rb", after: "def reset! = b1\n", first: [["use.rb", 3]], second: [])
    end
  end
end
