# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tempfile"

# Issue #1367 (ADR-117 WD2) — `global.write-type-mismatch` and `global.readonly-write`: a write to a special global that
# the interpreter's setter rejects, so the write raises every time it runs. The envelope is the setter
# (`CheckRules::SpecialGlobalSetters`), not the RBS declaration; a firing must be a write Ruby rejects, and a value the
# rules cannot place stays silent. `spec/integration/fixtures/special_global_writes/` carries the issue's examples with
# the error Ruby raises for each.
RSpec.describe "special global writes", type: :runner do
  let(:setters) { Rigor::Analysis::CheckRules::SpecialGlobalSetters }

  def global_diagnostics(source, config: {})
    analyze(source, config: config).diagnostics.select { |d| d.rule.to_s.start_with?("global.") }
  end

  def fired(source, config: {})
    global_diagnostics(source, config: config).map { |d| [d.line, d.rule.to_s] }
  end

  # The setter table against the running interpreter, both ways. A child Ruby tries every write (so an accepted one
  # cannot disturb this process), and the rules are run over the same writes, one per line: a write fires
  # `global.write-type-mismatch` exactly when Ruby raises `TypeError` for it, and every read-only special fires
  # `global.readonly-write` and raises `NameError`. The samples are literals, whose class is exact.
  describe "the setter table" do
    let(:samples) { ["1", "1.5", '"s"', ":sym", "nil", "true", "false", "[1]", "{ a: 1 }", "/re/", "1..2"] }

    def runtime_errors(writes)
      script = <<~RUBY
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
      output, status = Open3.capture2({ "RUBYOPT" => nil }, RbConfig.ruby, "--disable-gems", "-W0", "-e", script,
                                      stdin_data: writes.join("\n"))
      expect(status).to be_success
      output.lines(chomp: true)
    end

    it "reports a typed write exactly when Ruby raises TypeError for it" do
      writes = setters::CONTRACTS.keys.product(samples).map { |name, sample| "#{name} = #{sample}" }
      raised = runtime_errors(writes)
      expected = writes.each_index.filter_map { |i| [i + 1, "global.write-type-mismatch"] if raised[i] == "TypeError" }

      expect(raised.size).to eq(writes.size)
      expect(raised - %w[ok TypeError]).to be_empty
      expect(fired(writes.join("\n"))).to eq(expected)
    end

    it "reports every read-only special, which Ruby refuses with NameError" do
      writes = setters::READ_ONLY.map { |name| "#{name} = nil" }

      expect(runtime_errors(writes)).to all(eq("NameError"))
      expect(fired(writes.join("\n"))).to eq(writes.each_index.map { |i| [i + 1, "global.readonly-write"] })
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

  describe "values the rules cannot prove rejected (silent)" do
    # A class or module object is judged by its singleton surface, which the rules do not read (`IO.write` exists,
    # so Ruby takes `$stdout = IO`), so they decline every one: `$stdout = Time` raises, yet stays silent.
    it "stays silent on Dynamic, a union with an accepted member, and a class or module object" do
      source = <<~RUBY
        def dynamic(v) = ($stdout = v)
        def union(c) = ($/ = c ? 1 : "\\n")
        $stdout = IO
        $stdout = Time
        $0 = String
        $stdout = Comparable
      RUBY
      expect(fired(source)).to be_empty
    end

    it "stays silent on a value typed as a generic carrier or by a project-declared class" do
      source = <<~RUBY
        class Sink
        end
        $stdout = Object.new
        $stdout = Sink.new
      RUBY
      expect(fired(source)).to be_empty
    end

    # A project `sig/` may declare a class without the superclass its source gives it; RBS then orders it apart from
    # String although Ruby takes it. A class only the project's `sig/` declares is read the same way.
    it "stays silent on a class the project declares, whose ancestry its sig/ may omit" do
      sig = { "sep.rbs" => "class Separator\nend\nclass Generated\nend\n" }
      source = <<~RUBY
        class Separator < String
        end
        $/ = Separator.new(",")
        $/ = Generated.new
      RUBY
      diagnostics = analyze(source, sig: sig).diagnostics
      expect(diagnostics.select { |d| d.rule.to_s.start_with?("global.") }).to be_empty
    end

    it "stays silent on a delegator, which answers `write` through method_missing" do
      expect(fired(%(require "delegate"\n$stdout = SimpleDelegator.new(1)\n))).to be_empty
    end

    it "stays silent on a declaration-sourced nil and on a builtin global still on its declared seed" do
      source = <<~RUBY
        class Holder
          def initialize
            @out = nil
          end

          def restore = ($stdout = @out)
        end

        $VERBOSE = true
        def separator = ($/ = $VERBOSE)
        def parenthesised_separator = ($/ = ($VERBOSE))

        def copied_separator
          verbose = $VERBOSE
          $/ = verbose
        end
      RUBY
      expect(fired(source)).to be_empty
    end

    it "never checks `$stdin`, nor a special whose setter takes any value" do
      expect(fired(%($stdin = 1\n$_ = 1\n$VERBOSE = 1\n$DEBUG = 1\n$= = 1\n))).to be_empty
    end
  end

  describe "project code that can make the value answer the setter" do
    it "stays silent when the project gives every object the conversion or a method_missing hatch" do
      [
        "class Object\n  def method_missing(*) = 0\nend\n",
        "module Kernel\n  def to_str = \"\"\nend\n",
        "def to_str = \"\"\n"
      ].each do |patch|
        expect(fired("#{patch}$0 = 1\n")).to be_empty, patch
      end
    end

    it "stays silent when the project reopens the value's class" do
      expect(fired("class Integer\n  def write(*) = 0\nend\n$stdout = 1\n")).to be_empty
    end

    it "stays silent when another project file gives every object the hatch" do
      files = {
        "patch.rb" => "class Object\n  def method_missing(*) = 0\nend\n",
        "main.rb" => "$0 = 1\n$stdout = :sym\n"
      }
      diagnostics = analyze(files: files).diagnostics
      expect(diagnostics.select { |d| d.rule.to_s.start_with?("global.") }).to be_empty
    end

    it "judges a literal by its own class, but a nominal value, which may be a subclass, by any project `write`" do
      source = <<~RUBY
        class Recorder
          def write(*) = 0
        end
        $stdout = Time.now
        $stdout = 1
      RUBY
      expect(fired(source)).to eq([[5, "global.write-type-mismatch"]])
      expect(fired("$stdout = Time.now\n")).to eq([[1, "global.write-type-mismatch"]])
    end

    it "stays silent on a value rooted at an inferred parameter, which is only a lower bound" do
      source = <<~RUBY
        class Redirect
          def go = install(1)

          def install(io)
            $stdout = io
          end
        end
      RUBY
      config = Rigor::Configuration.new("paths" => [], "parameter_inference" => true)
      diagnostics = Tempfile.create(["redirect", ".rb"]) do |file|
        file.write(source)
        file.flush
        guarded_run(Rigor::Analysis::Runner.new(configuration: config, cache_store: nil), [file.path]).diagnostics
      end
      expect(diagnostics.map(&:rule)).not_to include("global.write-type-mismatch")
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
