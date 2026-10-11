# frozen_string_literal: true

# Issue #1120 — method definitions outside a lexical class body reported `call.undefined-method` on correct
# Ruby.
#
# - A `def` inside `refine X do … end` defines X#m, visible only lexically after `using M` for the refining
#   module M, in that file (top level or class / module body), and inside the refine block itself. Ruby
#   raises `NoMethodError` for the same call anywhere else, so those calls keep reporting.
# - A `using` whose argument is not a constant (`using Module.new { refine … }`) cannot be resolved to a
#   module, so any project refinement of X declines `call.undefined-method` on X in that file.
# - `def o.m` on a local declines `call.undefined-method` for `o.m` in the same scope, without changing
#   `o`'s type.
#
# Every expectation below is the answer CRuby gives for the same source: a silent line runs, a reported line
# raises `NoMethodError`.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/incremental_session"
require "rigor/analysis/runner"
require "rigor/cache/incremental_snapshot"
require "rigor/cache/store"
require "rigor/configuration"

RSpec.describe "Ruby refinements (`refine` / `using`) and singleton defs on locals (#1120)" do
  around do |example|
    Dir.mktmpdir("rigor-refinement-using-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
  end

  def diagnostics(cache_store: nil)
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: cache_store)
    guarded_run(runner, %w[lib]).diagnostics
  end

  # `[file basename, line, method name]` for every `call.undefined-method`, sorted.
  def undefined_rows(cache_store: nil)
    diagnostics(cache_store: cache_store)
      .select { |d| d.qualified_rule == "call.undefined-method" }
      .map { |d| [File.basename(d.path.to_s), d.line, d.method_name.to_s] }
      .sort
  end

  describe "a refinement" do
    it "resolves after a top-level `using` in the same file, and reports before it" do
      write("lib/shout.rb", <<~RUBY)
        module Shout
          refine(String) { def shout = upcase }
        end
        "early".shout
        using Shout
        "a".shout
        "b".nope
        1.shout
      RUBY

      expect(undefined_rows).to eq(
        [["shout.rb", 4, "shout"], ["shout.rb", 7, "nope"], ["shout.rb", 8, "shout"]]
      )
    end

    it "resolves after a class-body `using`, and only inside that body" do
      write("lib/parser.rb", <<~RUBY)
        module StrExt
          refine String do
            def blank? = strip.empty?
          end
        end

        class Parser
          def before = "b".blank?
          using StrExt
          def go = "g".blank?
          def lit = "  ".blank?
          class Nested
            def inner = "x".blank?
          end
        end

        "x".blank?
      RUBY

      expect(undefined_rows).to eq([["parser.rb", 8, "blank?"], ["parser.rb", 17, "blank?"]])
    end

    it "resolves a refinement declared in another file, and reports in a file with no `using`" do
      write("lib/core_ext.rb", <<~RUBY)
        module App
          module CoreExt
            refine String do
              def shout = upcase
            end
          end
        end
      RUBY
      write("lib/use.rb", <<~RUBY)
        module App
          using CoreExt
          def self.go = "a".shout
        end
      RUBY
      write("lib/other.rb", <<~RUBY)
        "a".shout
      RUBY

      expect(undefined_rows).to eq([["other.rb", 1, "shout"]])
    end

    it "is active inside its own refine block, whose defs see an instance of the refined class as self" do
      write("lib/loud.rb", <<~RUBY)
        module Loud
          refine String do
            def loud = "\#{upcase}!"
            def twice = "x".loud + loud
            def probe = Rigor.dump_type(self)
          end
        end
      RUBY

      rows = diagnostics.map { |d| [d.qualified_rule, d.line, d.message] }
      expect(rows).to eq([["dump.type", 5, "dump_type: String"]])
    end

    it "declines for the refined class throughout a file whose `using` names no module" do
      write("lib/anon.rb", <<~RUBY)
        using Module.new {
          refine String do
            def whisper = downcase
          end
        }
        "A".whisper
        "A".undefined_here
      RUBY
      write("lib/elsewhere.rb", <<~RUBY)
        "A".whisper
      RUBY

      expect(undefined_rows).to eq([["anon.rb", 7, "undefined_here"], ["elsewhere.rb", 1, "whisper"]])
    end

    it "answers the same through a warm cache as cold" do
      write("lib/core_ext.rb", <<~RUBY)
        module CoreExt
          refine String do
            def shout = upcase
          end
        end
      RUBY
      write("lib/use.rb", <<~RUBY)
        using CoreExt
        "a".shout
        "a".nope
      RUBY
      root = File.join(Dir.pwd, ".rigor", "cache")

      cold = undefined_rows(cache_store: Rigor::Cache::Store.new(root: root))
      warm = undefined_rows(cache_store: Rigor::Cache::Store.new(root: root))

      expect(cold).to eq([["use.rb", 3, "nope"]])
      expect(warm).to eq(cold)
    end

    # Maintainer ruling a′ on PR #1424: a refinement exists to redefine, so a refine-body def of a method X already
    # declares is not checked against X's signature for it (return or parameters), while the rest of the body is.
    it "does not check a refine body's redefinition against the refined class's signature" do
      write("lib/override.rb", <<~RUBY)
        module Quiet
          refine String do
            def upcase = nil
            def center(width) = Rigor.dump_type(width)
            def fresh = 1.nope_ctl
            def probe = Rigor.dump_type(self)
          end
          refine Integer do
            def to_s = :sym
          end
        end
      RUBY

      rows = diagnostics.map { |d| [d.qualified_rule, d.line, d.message] }
      expect(rows).to eq(
        [
          ["dump.type", 4, "dump_type: Dynamic[top]"],
          ["call.undefined-method", 5, "undefined method `nope_ctl' for 1"],
          ["dump.type", 6, "dump_type: String"]
        ]
      )
    end

    it "still checks a monkey-patch against the class's signature" do
      write("lib/patch.rb", <<~RUBY)
        class String
          def upcase = nil
        end
      RUBY

      expect(diagnostics.map { |d| [d.qualified_rule, d.line] }).to eq([["def.return-type-mismatch", 2]])
    end
  end

  # A refine body is not a class's method, so the symbol fingerprints and appeared-symbol diff that invalidate a
  # plain `def`'s callers never see it. Each edit below must reach the `using` file on the warm run.
  describe "a refine body edited between runs" do
    let(:paths) { %w[lib/r.rb lib/u.rb] }
    let(:whisper_fires) { [["u.rb", 3, "whisper"]] }

    def write_refinement(extra = "")
      write("lib/r.rb", "module Shout\n  refine String do\n    def shout = upcase\n#{extra}  end\nend\n")
    end

    def write_project
      write_refinement
      write("lib/u.rb", "using Shout\n\"a\".shout\n\"a\".whisper\n")
    end

    def rows_of(diagnostics)
      diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }
                 .map { |d| [File.basename(d.path.to_s), d.line, d.method_name.to_s] }.sort
    end

    def incremental_rows
      root = File.join(Dir.pwd, ".rigor", "cache")
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
      session = Rigor::Analysis::IncrementalSession.new(
        configuration: configuration, paths: paths, cache_store: Rigor::Cache::Store.new(root: root)
      )
      found, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
      [rows_of(found), warm]
    end

    it "re-checks the `using` file under --incremental when a refined def appears and then goes" do
      write_project
      expect(incremental_rows).to eq([whisper_fires, false])

      write_refinement("    def whisper = downcase\n")
      expect(incremental_rows).to eq([[], true])
      expect(undefined_rows).to eq([])

      write_refinement
      expect(incremental_rows).to eq([whisper_fires, true])
      expect(undefined_rows).to eq(whisper_fires)
    end

    # The refining file is unchanged, so the warm run restores its table from its seed bundle while it
    # re-analyses the edited `using` file.
    it "serves an unchanged refining file's table from its seed bundle" do
      write_project
      expect(incremental_rows).to eq([whisper_fires, false])

      write("lib/u.rb", "using Shout\n\"a\".shout\n\"a\".whisper\n\"b\".shout\n")
      expect(incremental_rows).to eq([whisper_fires, true])
    end

    # Issue #1664 — the typed refined arm answers with the refine body's return, so an edit inside a body that keeps
    # the refinement table unchanged must still reach the `using` file.
    it "re-types the `using` file when only a refine body's return changes" do
      write("lib/r.rb", "module Shout\n  refine String do\n    def shout = upcase\n  end\nend\n")
      write("lib/u.rb", "using Shout\nRigor.dump_type(\"a\".shout)\n")
      dump = lambda do |found|
        found.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
      end
      root = File.join(Dir.pwd, ".rigor", "cache")
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
      run = lambda do
        fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
        session = Rigor::Analysis::IncrementalSession.new(
          configuration: configuration, paths: paths, cache_store: Rigor::Cache::Store.new(root: root)
        )
        found, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
        [dump.call(found), warm]
      end
      expect(run.call).to eq([["dump_type: String"], false])

      write("lib/r.rb", "module Shout\n  refine String do\n    def shout = size\n  end\nend\n")
      expect(run.call).to eq([["dump_type: non-negative-int"], true])
      expect(dump.call(diagnostics(cache_store: Rigor::Cache::Store.new(root: root)))).to eq(
        ["dump_type: non-negative-int"]
      )
    end

    it "answers an edited refinement on a cached run as a cold run does" do
      write_project
      root = File.join(Dir.pwd, ".rigor", "cache")
      expect(undefined_rows(cache_store: Rigor::Cache::Store.new(root: root))).to eq(whisper_fires)

      write_refinement("    def whisper = downcase\n")
      expect(undefined_rows(cache_store: Rigor::Cache::Store.new(root: root))).to eq([])

      write_refinement
      expect(undefined_rows(cache_store: Rigor::Cache::Store.new(root: root))).to eq(whisper_fires)
    end
  end

  # Issue #1671 — `using C` also activates the refinements of every module `C` includes, transitively (CRuby
  # `doc/syntax/refinements.rdoc` § "Refinement inheritance by Module#include").
  describe "a refinement inherited through `include`" do
    it "is in effect after `using` of a module that includes the refining module" do
      write("lib/inherit.rb", <<~RUBY)
        module A
          refine(String) { def shout = upcase + "!" }
        end

        module C
          include A
        end

        using C
        "hi".shout
        "hi".whisper
      RUBY

      expect(undefined_rows).to eq([["inherit.rb", 11, "whisper"]])
    end

    it "is not in effect when the `using`'d module does not include the refining module" do
      write("lib/inherit.rb", <<~RUBY)
        module A
          refine(String) { def shout = upcase + "!" }
        end

        module C
        end

        using C
        "hi".shout
      RUBY

      expect(undefined_rows).to eq([["inherit.rb", 9, "shout"]])
    end

    it "follows a two-level include, with the edges declared in other files" do
      write("lib/a.rb", "module A\n  refine(String) { def shout = upcase + \"!\" }\nend\n")
      write("lib/b.rb", "module B\n  include A\nend\n")
      write("lib/c.rb", "module C\n  include B\nend\n")
      write("lib/use.rb", "using C\n\"hi\".shout\n")
      write("lib/other.rb", "using B\n\"hi\".shout\nusing Comparable\n")

      expect(undefined_rows).to eq([])
    end

    it "follows a `prepend` and not an `extend`, as CRuby's ancestor walk does" do
      write("lib/inherit.rb", <<~RUBY)
        module A
          refine(String) { def shout = upcase + "!" }
        end
        module P
          prepend A
        end
        module E
          extend A
        end

        module Ok
          using P
          "hi".shout
        end
        using E
        "hi".shout
      RUBY

      expect(undefined_rows).to eq([["inherit.rb", 16, "shout"]])
    end

    it "declines when the `using`'d module includes a module the tables cannot name" do
      write("lib/inherit.rb", <<~RUBY)
        module A
          refine(String) { def shout = upcase + "!" }
        end
        module C
          [A].each { |m| include m }
        end

        using C
        "hi".shout
      RUBY

      expect(undefined_rows).to eq([])
    end

    it "declines when the `using`'d module's chain is cut at its limit" do
      depth = Rigor::Scope::ResolutionChain::LIMIT + 5
      links = (1..depth).map { |i| "module M#{i}\n  include M#{i - 1}\nend\n" }.join
      refining = "module M0\n  refine(String) { def shout = upcase }\nend\n"
      write("lib/deep.rb", "#{refining}#{links}using M#{depth}\n\"a\".shout\n")

      expect(undefined_rows).to eq([])
    end

    it "also reaches the argument checks' decline for a redefined method (#1663)" do
      write("lib/sym.rb", <<~RUBY)
        module SymSyntax
          refine Symbol do
            def [](other) = "\#{self}.\#{other}"
          end
        end
        module Syntax
          include SymSyntax
        end
        using Syntax
        :authors[:age]
      RUBY

      expect(diagnostics.map(&:qualified_rule)).not_to include("call.argument-type-mismatch")
    end

    it "does not reach a module that includes the `using`'d one" do
      write("lib/inherit.rb", <<~RUBY)
        module C
        end

        module A
          include C
          refine(String) { def shout = upcase + "!" }
        end

        using C
        "hi".shout
      RUBY

      expect(undefined_rows).to eq([["inherit.rb", 10, "shout"]])
    end

    # The answer reads an include edge declared in another file, so editing that edge must reach the `using`
    # file on a warm run.
    describe "when the include edge is edited between runs" do
      let(:shout_fires) { [["use.rb", 2, "shout"]] }

      def write_project(include_line)
        write("lib/a.rb", "module A\n  refine(String) { def shout = upcase }\nend\n")
        write("lib/c.rb", "module C\n#{include_line}end\n")
        write("lib/use.rb", "using C\n\"a\".shout\n")
      end

      def cached_rows
        undefined_rows(cache_store: Rigor::Cache::Store.new(root: File.join(Dir.pwd, ".rigor", "cache")))
      end

      def incremental_rows(paths)
        root = File.join(Dir.pwd, ".rigor", "cache")
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
        fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
        session = Rigor::Analysis::IncrementalSession.new(
          configuration: configuration, paths: paths, cache_store: Rigor::Cache::Store.new(root: root)
        )
        found, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
        rows = found.select { |d| d.qualified_rule == "call.undefined-method" }
                    .map { |d| [File.basename(d.path.to_s), d.line, d.method_name.to_s] }.sort
        [rows, warm]
      end

      it "answers on a cached run as a cold run does" do
        write_project("")
        expect(cached_rows).to eq(shout_fires)

        write_project("  include A\n")
        expect(cached_rows).to eq([])
        expect(undefined_rows).to eq([])

        write_project("")
        expect(cached_rows).to eq(shout_fires)
        expect(undefined_rows).to eq(shout_fires)
      end

      it "re-checks the `using` file under --incremental when the include appears and then goes" do
        paths = %w[lib/a.rb lib/c.rb lib/use.rb]
        write_project("")
        expect(incremental_rows(paths)).to eq([shout_fires, false])

        write_project("  include A\n")
        expect(incremental_rows(paths)).to eq([[], true])

        write_project("")
        expect(incremental_rows(paths)).to eq([shout_fires, true])
      end

      it "re-checks the `using` file under --incremental when a new file reopens the module to include" do
        write_project("")
        expect(incremental_rows(%w[lib])).to eq([shout_fires, false])

        write("lib/c_ext.rb", "module C\n  include A\nend\n")
        expect(incremental_rows(%w[lib])).to eq([[], true])
        expect(undefined_rows).to eq([])
      end

      # `Helpers` is declared by no file on the first run, so it sits on `C`'s chain as an external entry. ADR-121 WD7:
      # such a module may refine anything (it reported before), so the first run is silent; a new file declaring
      # `Helpers` with no refinement makes it known, and `shout` reports again.
      it "re-checks the `using` file under --incremental when a new file declares an included module" do
        write_project("  include Helpers\n")
        expect(incremental_rows(%w[lib])).to eq([[], false])

        write("lib/helpers.rb", "module Helpers\nend\n")
        expect(incremental_rows(%w[lib])).to eq([shout_fires, true])
        expect(undefined_rows).to eq(shout_fires)

        write("lib/helpers.rb", "module Helpers\n  include A\nend\n")
        expect(incremental_rows(%w[lib])).to eq([[], true])
        expect(undefined_rows).to eq([])
      end

      # `use.rb` names `C` and not `B`, so only the chain's own edges can tie it to a file reopening `B`.
      it "re-checks the `using` file under --incremental when a new file gives an included module the include" do
        write_project("  include B\n")
        write("lib/b.rb", "module B\nend\n")
        expect(incremental_rows(%w[lib])).to eq([shout_fires, false])

        write("lib/b_ext.rb", "module B\n  include A\nend\n")
        expect(incremental_rows(%w[lib])).to eq([[], true])
        expect(undefined_rows).to eq([])
      end
    end
  end

  # Issue #1663 — a refinement that REDEFINES a method the class already has replaces the signature the call-site
  # argument and arity rules read, so while it is in effect those rules decline. Typing the call from the refine
  # body is #1664; here the call keeps the unrefined return type.
  describe "a refinement redefining an existing method" do
    def call_rows(cache_store: nil)
      diagnostics(cache_store: cache_store)
        .select { |d| %w[call.argument-type-mismatch call.wrong-arity].include?(d.qualified_rule) }
        .map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }
        .sort
    end

    before do
      write("lib/ext.rb", <<~RUBY)
        module SymSyntax
          refine Symbol do
            def [](other) = "\#{self}.\#{other}"
          end
          refine Integer do
            def succ(step) = self + step
          end
        end
        module Unrelated
          refine Symbol do
            def other_method = 1
          end
        end
      RUBY
    end

    it "declines the argument-type and arity checks after the `using`, for the refined names only" do
      write("lib/use.rb", <<~RUBY)
        :before[:age]
        1.succ(2)
        using SymSyntax
        :authors[:age]
        1.succ(2)
        1.gcd(:x)
      RUBY

      expect(call_rows).to eq(
        [
          ["use.rb", 1, "call.argument-type-mismatch"],
          ["use.rb", 2, "call.wrong-arity"],
          ["use.rb", 6, "call.argument-type-mismatch"]
        ]
      )
    end

    it "keeps checking a file with no `using`, or a `using` of a module refining other names" do
      write("lib/plain.rb", <<~RUBY)
        :authors[:age]
        1.succ(2)
      RUBY
      write("lib/unrelated.rb", <<~RUBY)
        using Unrelated
        :authors[:age]
      RUBY

      expect(call_rows).to eq(
        [
          ["plain.rb", 1, "call.argument-type-mismatch"],
          ["plain.rb", 2, "call.wrong-arity"],
          ["unrelated.rb", 2, "call.argument-type-mismatch"]
        ]
      )
    end

    it "answers the same through a warm cache as cold" do
      write("lib/use.rb", "using SymSyntax\n:authors[:age]\n:x[:y]\n")
      write("lib/plain.rb", ":authors[:age]\n")
      root = File.join(Dir.pwd, ".rigor", "cache")

      cold = call_rows(cache_store: Rigor::Cache::Store.new(root: root))
      warm = call_rows(cache_store: Rigor::Cache::Store.new(root: root))

      expect(cold).to eq([["plain.rb", 1, "call.argument-type-mismatch"]])
      expect(warm).to eq(cold)
    end

    # Issue #1740 — Ruby finds a method the receiver's class (or a nearer ancestor) defines before it consults an
    # ancestor's refinement, so the argument checks report there, and only where Rigor can prove that definer and
    # that no refinement in effect may answer first. Every reported line raises on Ruby 4.0.5; every silent line
    # under a `using` returns the refinement's answer there, and its control line (no `using`) reports.
    describe "of an ancestor (#1740)" do
      let(:ancestors) do
        <<~RUBY
          module ObjCenter; refine(Object) { def center(a, b, c) = a }; end
          module KernCenter; refine(Kernel) { def center(a, b, c) = a }; end
          module ObjIndex; refine(Object) { def [](other) = other }; end
          module NumDigits; refine(Numeric) { def digits(a, b, c) = a; def floor(a, b, c) = a }; end
          module NumQuo; refine(Numeric) { def quo(a, b, c) = a }; end
          module CmpClamp; refine(Comparable) { def clamp(a, b, c) = a }; end
          module IOPath; refine(IO) { def to_path(a, b, c) = 1 }; end
          module ObjOld; refine(Object) { def &(a, b) = :ref; def taint(a, b) = :ref }; end
        RUBY
      end

      before { write("lib/ancestors.rb", ancestors) }

      def write_class(name, body, signature)
        write("lib/#{name.downcase}.rb", "class #{name}\n#{body}end\n")
        write("sig/#{name.downcase}.rbs", "class #{name}\n#{signature}end\n")
      end

      def controls(lines) = lines.map { |line| ["control.rb", line, "call.wrong-arity"] }

      # `String#center`, `Symbol#[]`, `Integer#digits`, `Integer#floor` and `Own#center` answer: the CRuby catalogue
      # proves the core definers, `Own`'s certain `def` its own.
      it "keeps checking a method the receiver's class defines itself" do
        write_class("Own", "  def center(width) = width\n", "  def center: (Integer) -> Integer\n")
        write("lib/object.rb", "using ObjCenter\n\"x\".center(1, 2, 3)\nOwn.new.center(1, 2, 3)\n")
        write("lib/kernel.rb", "using KernCenter\n\"x\".center(1, 2, 3)\n")
        write("lib/index.rb", "using ObjIndex\n:authors[:age]\n")
        write("lib/numeric.rb", "using NumDigits\n1.digits(1, 2, 3)\n1.floor(1, 2, 3)\n")

        expect(call_rows).to eq(
          [["index.rb", 2, "call.argument-type-mismatch"], ["kernel.rb", 2, "call.wrong-arity"],
           ["numeric.rb", 2, "call.wrong-arity"], ["numeric.rb", 3, "call.wrong-arity"],
           ["object.rb", 2, "call.wrong-arity"], ["object.rb", 3, "call.wrong-arity"]]
        )
      end

      # `Comparable#clamp` is the owner. Core RBS declares `Integer#quo`, `File#to_path`, `Process::Status#&` and
      # `Pathname#taint`, but CRuby defines the first two on `Numeric` and `IO` and the last two nowhere.
      it "declines where the catalogue does not prove the definer below the refinement" do
        write_class("Probe", "  def self.status = Process::Status.allocate\n  def self.path = Pathname.new(\"x\")\n",
                    "  def self.status: () -> Process::Status\n  def self.path: () -> Pathname\n")
        calls = "\"a\".clamp(1, 2, 3)\n1.quo(1, 2, 3)\nFile.new(__FILE__).to_path(1, 2, 3)\n" \
                "Probe.status.&(1, 2)\nProbe.path.taint(1, 2)\n"
        write("lib/use.rb", "using CmpClamp\nusing NumQuo\nusing IOPath\nusing ObjOld\n#{calls}")
        write("lib/control.rb", calls)

        expect(call_rows).to eq(controls(1..5))
      end

      # `GemRef` lives outside the analysed paths, and so does the `B` that `A` includes. Each refines `String#center`
      # (Ruby prints `:gem`, `:b`), so the opaque module keeps the decline.
      it "declines while an in-effect module is opaque" do
        write("vendor/gem_ref.rb", "module GemRef; refine(String) { def center(a, b, c) = :gem }; end\n")
        write("vendor/b.rb", "module B; refine(String) { def center(a, b, c) = :b }; end\n")
        write("lib/mixer.rb", "module A\n  include B\n  refine(Integer) { def x = 1 }\nend\n")
        write("lib/gem_use.rb", "using ObjCenter\nusing GemRef\n\"s\".center(1, 2, 3)\n")
        write("lib/mixer_use.rb", "using ObjCenter\nusing A\n\"x\".center(1, 2, 3)\n")

        expect(call_rows).to eq([])
      end

      # Ruby prints `:alias_method`, `:dm` and `:imported`: each refine body defines `String#center` other than by
      # `def`, which the table records as the name or as a names-wildcard.
      it "declines while an in-effect refine body defines the name other than by `def`" do
        write("lib/str_refs.rb", <<~RUBY)
          module StrAlias; refine(String) { def c3(a, b, c) = :alias_method; alias_method :center, :c3 }; end
          module StrDefine; refine(String) { def other = 1; define_method(:center) { |a, b, c| :dm } }; end
          module Helper; def center(a, b, c) = :imported; end
          module StrImport; refine(String) { import_methods Helper; def shout = upcase }; end
        RUBY
        %w[Alias Define Import].each do |kind|
          write("lib/#{kind.downcase}_use.rb", "using ObjCenter\nusing Str#{kind}\n\"x\".center(1, 2, 3)\n")
        end

        expect(call_rows).to eq([])
      end

      # Issue #1797. On Ruby 4.0.5 `Inc#bar` answers ahead of the refinement of the module `Inc` includes, and a
      # refinement of another name on `Base` leaves `Kid#center` answering, with and without a `using`: each raises.
      # `RK` refines `Kid` itself and answers (`1`).
      it "keeps checking a class's own method ahead of a refined module or superclass" do
        write("lib/inc.rb", "module N; end\nclass Inc\n  def bar(a) = a\n  include N\nend\n" \
                            "module M; refine(N) { def bar(a, b, c) = :n }; end\n")
        write("lib/kid.rb", "class Base; def other = 0; end\nmodule RB; refine(Base) { def other = 1 }; end\n" \
                            "class Kid < Base; def center(a) = a; end\n" \
                            "module RK; refine(Kid) { def center(a, b, c) = 1 }; end\n")
        write("lib/inc_use.rb", "using M\nInc.new.bar(1, 2, 3)\n")
        write("lib/plain.rb", "Kid.new.center(1, 2, 3)\n")
        write("lib/base_use.rb", "using RB\nKid.new.center(1, 2, 3)\n")
        write("lib/kid_use.rb", "using RK\nKid.new.center(1, 2, 3)\n")

        expect(call_rows).to eq(
          [["base_use.rb", 2, "call.wrong-arity"], ["inc_use.rb", 2, "call.wrong-arity"],
           ["plain.rb", 1, "call.wrong-arity"]]
        )
      end

      # Critique F3. Ruby 4.0.5 answers `:refined` for each call: with the variable unset no definer runs, and
      # `Object`'s refinement answers. A definer that may not have run proves nothing, however it defines.
      it "declines over a definer that may not have run" do
        body = <<~RUBY.gsub(/^/, "  ")
          if ENV["RIGOR_PROBE_X"]
            def center(a) = a
            attr_reader :ljust
            define_method(:rjust) { |a| a }
          end
        RUBY
        signature = "  def center: (untyped) -> untyped\n  def ljust: () -> untyped\n  def rjust: (untyped) -> void\n"
        write_class("Own", body, signature)
        write("lib/ro.rb", "module RO\n  refine(Object) { def center(a, b, c) = 1; def ljust(a, b, c) = 1; " \
                           "def rjust(a, b, c) = 1 }\nend\n")
        calls = "Own.new.center(1, 2, 3)\nOwn.new.ljust(1, 2, 3)\nOwn.new.rjust(1, 2, 3)\n"
        write("lib/use.rb", "using RO\n#{calls}")
        write("lib/control.rb", calls)

        expect(call_rows).to eq(controls(1..3))
      end

      # Critique F4. A value typed as `Base`, as `Typed` (its method declared in `sig/`) or as `String` may be an
      # instance of the refined subclass, and the value `Opener.io` (`-> IO`) answers is a `File`, a subclass RBS
      # declares: for such a value Ruby 4.0.5 answers `:kid`, `:typed_kid`, `:mystr` and `:file`.
      it "declines where a refinement in effect refines a subclass of the receiver's class" do
        write("lib/base.rb", "class Base; def center(a) = a; end\nclass Kid < Base; end\n" \
                             "module KidRef; refine(Kid) { def center(a, b, c) = :kid }; end\n")
        write_class("Typed", "  def ljust(a) = a\n", "  def ljust: (untyped) -> untyped\n")
        write("lib/typed_kid.rb", "class TypedKid < Typed; end\n" \
                                  "module TypedRef; refine(TypedKid) { def ljust(a, b, c) = :typed_kid }; end\n")
        write("lib/my_str.rb", "class MyStr < String; end\n" \
                               "module StrRef; refine(MyStr) { def rjust(a, b, c) = :mystr }; end\n")
        write_class("Opener", "  def self.io = File.new(__FILE__)\n", "  def self.io: () -> IO\n")
        write("lib/file_ref.rb", "module FileRef; refine(File) { def fsync(a, b, c) = :file }; end\n")
        calls = "Base.new.center(1, 2, 3)\nTyped.new.ljust(1, 2, 3)\n\"x\".rjust(1, 2, 3)\nOpener.io.fsync(1, 2, 3)\n"
        write("lib/use.rb", "using KidRef\nusing TypedRef\nusing StrRef\nusing FileRef\n#{calls}")
        write("lib/control.rb", calls)

        expect(call_rows).to eq(controls(1..4))
      end

      # Ruby 4.0.5 answers `:kid`, `:cmp`, `:mys4` and `:vkid`: `Kid < Object.const_get(:Base)` and the two
      # `Class.new(String)` classes are subclasses the superclass table does not record, and `VKid`'s superclass
      # `VendorBase < Typed` is declared outside the analysed paths. A refined class must be placed by a fully read
      # chain, and a class whose superclass is unknown may be a subclass of any class.
      it "declines where a refined class or a subclass has a superclass the tables do not know" do
        write_class("Typed", "  def center(a) = a\n  def chop(a) = a\n",
                    "  def center: (untyped) -> untyped\n  def chop: (untyped) -> untyped\n")
        write("lib/unknown.rb", <<~RUBY)
          class Kid < Object.const_get(:Typed); end
          module KidRef; refine(Kid) { def center(a, b, c) = :kid }; end
          MyS2 = Class.new(String) { prepend Comparable }
          module CmpRef; refine(Comparable) { def ljust(a, b, c) = :cmp }; end
          MyS4 = Class.new(String)
          module S4Ref; refine(MyS4) { def rjust(a, b, c) = :mys4 }; end
          class VKid < VendorBase; end
          module VKidRef; refine(VKid) { def chop(a, b, c) = :vkid }; end
        RUBY
        write("vendor/v.rb", "class VendorBase < Typed; end\n")
        calls = "Typed.new.center(1, 2, 3)\n\"x\".ljust(1, 2, 3)\n\"x\".rjust(1, 2, 3)\nTyped.new.chop(1, 2, 3)\n"
        write("lib/use.rb", "using KidRef\nusing CmpRef\nusing S4Ref\nusing VKidRef\n#{calls}")
        write("lib/control.rb", calls)

        expect(call_rows).to eq(controls(1..4))
      end

      # `Sub` prepends `N` again ahead of `Host#ljust`, and a String may extend `Ext`, a refined module the receiver's
      # levels do not hold: Ruby 4.0.5 answers `:n` for a `Sub` and `:ext` for an extended String. A refined module a
      # class prepends answers ahead of its own method, `NE` (no methods) as well: `:np`, `:ne`.
      it "declines where a class or its subclass prepends a refined module, or a value may extend one" do
        write("lib/host.rb", <<~RUBY)
          module N; end
          class Host; include N; def ljust(a) = a; end
          class Sub < Host; prepend N; end
          module NRef; refine(N) { def ljust(a, b, c) = :n }; end
          module Ext; end
          module ExtRef; refine(Ext) { def chop(a, b, c) = :ext }; end
        RUBY
        write("sig/host.rbs", "module N\nend\nclass Host\n  include N\n  def ljust: (untyped) -> untyped\nend\n")
        write("lib/pre.rb", <<~RUBY)
          module NP; def x = 1; end
          module NE; end
          class Pre; prepend NP; def center(a) = a; end
          class PreE; prepend NE; def ljust(a) = a; end
          module NPRef; refine(NP) { def center(a, b, c) = :np }; end
          module NERef; refine(NE) { def ljust(a, b, c) = :ne }; end
        RUBY
        calls = "Host.new.ljust(1, 2, 3)\n\"y\".chop(1, 2, 3)\nPre.new.center(1, 2, 3)\nPreE.new.ljust(1, 2, 3)\n"
        write("lib/use.rb", "using NRef\nusing ExtRef\nusing NPRef\nusing NERef\n#{calls}")
        write("lib/control.rb", calls)

        expect(call_rows).to eq(controls(1..4))
      end

      # Ruby 4.0.5 answers `:cmp` and `:kernel`: a `prepend` onto an object's singleton class puts the module ahead of
      # the object's class even though the class already includes it, so its refinement answers first.
      it "declines where code prepends a refined module the class holds to an object's singleton class" do
        write("lib/prepends.rb", <<~RUBY)
          module RC; refine(Comparable) { def ljust(a, b, c) = :cmp }; end
          s = +"x"
          s.singleton_class.prepend(Comparable)
          class Wrap
            def self.loud(obj)
              class << obj
                prepend Kernel
              end
              obj
            end
          end
        RUBY
        write("lib/use.rb", "using RC\nusing KernCenter\n\"x\".ljust(1, 2, 3)\n\"x\".center(1, 2, 3)\n")
        write("lib/control.rb", "\"x\".ljust(1, 2, 3)\n\"x\".center(1, 2, 3)\n")

        expect(call_rows).to eq(controls(1..2))
      end

      # No refinement here. Ruby 4.0.5 answers `true` for `Bar.new.between?(1, 2)` (Comparable's, ahead of
      # `Foo#between?`) and raises for `Baz` and `Repo`. A singleton prepend, a `class << self` prepend and an
      # `extend` naming `Comparable` do not make it a project module with no `between?`, and a `class << self`
      # prepend of `Finders` in a class body is the class object's, not every object's, so `Repo#find` stays checked;
      # an empty project module is still the project's.
      it "keeps the arity rule's mixin reading where a mark names a module the project does not declare" do
        write("lib/marks.rb", <<~RUBY)
          x = Object.new
          x.singleton_class.prepend(Comparable)
          class Model; class << self; prepend Comparable; end; end
          class Deco; def self.wrap(o) = o.extend(Comparable); end
          module Finders; def find(*args) = super; end
          class Store; def self.find(id) = id; class << self; prepend Finders; end; end
        RUBY
        write("lib/use.rb", <<~RUBY)
          class Foo; def between?(a) = a; end
          class Bar < Foo; include Comparable; def <=>(other) = 0; end
          module Helper; end
          class Baz < Foo; include Helper; end
          class Repo; def find(id) = id; end
          Bar.new.between?(1, 2)
          Baz.new.between?(1, 2)
          Repo.new.find(1, 2)
        RUBY

        expect(call_rows).to eq([["use.rb", 7, "call.wrong-arity"], ["use.rb", 8, "call.wrong-arity"]])
      end

      # No refinement here. Ruby 4.0.5 answers `[1, 2]` for the first three calls: a module the project rewrites
      # dynamically (a computed `define_method` in a `module_eval` or `class_eval` block, an `include` of a
      # non-constant), whether core or vendored with a signature, may define the name ahead of `Base#foo`, so the
      # arity rule keeps it on the chain. `HostQ` includes an untouched vendored module and raises.
      it "keeps a module the project rewrites dynamically on the arity rule's chain" do
        write("vendor/m.rb", "module M; end\nmodule N; end\nmodule Loud; def foo(*a) = a; end\nmodule Quiet; end\n")
        write("sig/m.rbs", "module M\nend\nmodule N\nend\nmodule Quiet\nend\n")
        write("lib/use.rb", <<~RUBY)
          Comparable.module_eval { define_method(["ze", "ta"].join) { |*a| a } }
          M.class_eval { define_method(["f", "oo"].join) { |*a| a } }
          N.include(Object.const_get(:Loud))
          class Base; def zeta(a) = a; def foo(a) = a; end
          class Host < Base; include Comparable; end
          class HostM < Base; include M; end
          class HostN < Base; include N; end
          class HostQ < Base; include Quiet; end
          Host.new.zeta(1, 2)
          HostM.new.foo(1, 2)
          HostN.new.foo(1, 2)
          HostQ.new.foo(1, 2)
        RUBY

        expect(call_rows).to eq([["use.rb", 12, "call.wrong-arity"]])
      end

      # Ruby 4.0.5 answers `:cmp` for each: a block's `self` may be an object even at the top level or in a class
      # body, so a `singleton_class.prepend` or a `class << self` prepend inside `instance_eval`, `instance_exec` or a
      # `define_method` block puts `Comparable` ahead of the object's class.
      {
        "an instance_eval block" => "s = +\"x\"\ns.instance_eval { singleton_class.prepend(Comparable) }\n",
        "a class << self in an instance_exec block" =>
          "s = +\"x\"\ns.instance_exec do\n  class << self\n    prepend Comparable\n  end\nend\n",
        "a define_method block" =>
          "class Loud < String\n  define_method(:louden) { singleton_class.prepend(Comparable); self }\nend\n"
      }.each do |shape, source|
        it "declines where #{shape} prepends a refined module the class holds" do
          write("lib/prepends.rb", "module RC; refine(Comparable) { def center(a, b, c) = :cmp }; end\n#{source}")
          write("lib/use.rb", "using RC\n\"y\".center(1, 2, 3)\n")
          write("lib/control.rb", "\"y\".center(1, 2, 3)\n")

          expect(call_rows).to eq(controls([1]))
        end
      end

      # Ruby 4.0.5 raises for `Repo.new.find(1, 2)`: a `singleton_class.prepend` on `self` written directly in a class
      # body prepends to the class object, not to every object, so `Repo#find` stays checked.
      it "keeps checking where a class body prepends a module to its own singleton class" do
        write("lib/store.rb", <<~RUBY)
          module Finders; def find(*args) = super; end
          class Store
            def self.find(id) = id
            singleton_class.prepend(Finders)
            self.singleton_class.prepend(Finders)
          end
        RUBY
        write("lib/use.rb", "class Repo; def find(id) = id; end\nRepo.new.find(1, 2)\n")

        expect(call_rows).to eq([["use.rb", 2, "call.wrong-arity"]])
      end

      # Ruby 4.0.5 answers `:base`: `Random#seed` runs on `Random::Base`, which RBS declares beside `Random` rather than
      # above it. CRuby registers `Random#seed` only inside `random.c`'s `#if 0` block for RDoc, which the catalogue
      # skips, so nothing proves `Random` defines it.
      it "declines where CRuby registers the method on the class only for RDoc" do
        write("lib/seed.rb", <<~RUBY)
          module RObj; refine(Object) { def seed(a, b, c) = :obj }; end
          module RBase; refine(Random::Base) { def seed(a, b, c) = :base }; end
        RUBY
        write("lib/use.rb", "using RObj\nusing RBase\nRandom.new.seed(1, 2, 3)\n")
        write("lib/control.rb", "Random.new.seed(1, 2, 3)\n")

        expect(call_rows).to eq(controls([1]))
      end

      # Ruby 4.0.5 answers `:bar`: a constant is looked up through the refining module's ancestors before the top
      # level, so `refine(Bar)` in `R`, which includes `Foo`, refines `Foo::Bar` even though a top-level `Bar` exists.
      it "declines where the refining module's ancestors hold the refined class" do
        write("lib/foo.rb", <<~RUBY)
          class Bar; end
          module Foo
            class Bar < Object
              def center(a) = a
            end
          end
          module R
            include Foo
            refine(Bar) { def center(a, b, c) = :bar }
          end
        RUBY
        write("lib/use.rb", "using ObjCenter\nusing R\nFoo::Bar.new.center(1, 2, 3)\n")
        write("lib/control.rb", "using ObjCenter\nFoo::Bar.new.center(1, 2, 3)\n")

        expect(call_rows).to eq([["control.rb", 2, "call.wrong-arity"]])
      end

      # Ruby 4.0.5 answers `:bar` and `:vendor`: `refine(Bar)` in a module that includes `Foo` resolves `Bar` through
      # the module's ancestors to `Foo::Bar`, which the table records under `R::Bar` and `Bar` only, and `VendorStr <
      # String` is declared outside the analysed paths. A refined class no table declares by any spelling cannot be
      # placed in the receiver's hierarchy.
      it "declines under a refinement of a class no table declares" do
        write("lib/foo.rb", <<~RUBY)
          module Foo
            class Bar < Object
              def center(a) = a
            end
          end
          module R
            include Foo
            refine(Bar) { def center(a, b, c) = :bar }
          end
          module ObjRjust; refine(Object) { def rjust(a, b, c) = a }; end
        RUBY
        write("vendor/v.rb", "class VendorStr < String; end\n")
        write("lib/vendor_ref.rb", "module RV; refine(VendorStr) { def rjust(a, b, c) = :vendor }; end\n")
        write("sig/show.rbs", "class Show\n  def self.call: (String) -> untyped\nend\n")
        write_class("Plain", "  def self.call(s) = s.rjust(1, 2, 3)\n", "  def self.call: (String) -> untyped\n")
        write("lib/use.rb", "using ObjCenter\nusing R\nusing ObjRjust\nusing RV\nFoo::Bar.new.center(1, 2, 3)\n" \
                            "class Show\n  def self.call(s) = s.rjust(1, 2, 3)\nend\n")
        write("lib/control.rb", "using ObjCenter\nFoo::Bar.new.center(1, 2, 3)\n")

        expect(call_rows).to eq([["control.rb", 2, "call.wrong-arity"], ["plain.rb", 2, "call.wrong-arity"]])
      end

      # Critique F7. Ruby 4.0.5 answers `:refined` for each: the project removed `String#center`, so the catalogue
      # proves nothing about it; nor for a class whose body rewrites its table through `send`; nor does a project
      # `def` or `attr_reader` the class then removes.
      it "declines where the project removed or rewrote the definer's method" do
        write("lib/removed.rb", <<~RUBY)
          class String; remove_method :center; end
          class Symbol; send(:remove_method, :to_proc); end
          module ObjProc; refine(Object) { def to_proc(a) = :refined }; end
        RUBY
        write_class("Own2", "  def center(a) = a\n  remove_method :center\n", "  def center: (untyped) -> untyped\n")
        write_class("Own3", "  attr_reader :center\n  remove_method :center\n", "  def center: () -> untyped\n")
        calls = "\"x\".center(1, 2, 3)\n:s.to_proc(1)\nOwn2.new.center(1, 2, 3)\nOwn3.new.center(1, 2, 3)\n"
        write("lib/use.rb", "using ObjCenter\nusing ObjProc\n#{calls}")
        write("lib/control.rb", calls)

        expect(call_rows).to eq(controls(1..4))
      end

      # Ruby 4.0.5 answers `:wide`: a module the project prepends to `String` sits where RBS does not place it.
      it "declines past a level the project mixes into" do
        write("lib/wide.rb", "module Wide; end\nclass String; prepend Wide; end\n" \
                             "module RW; refine(Wide) { def center(a, b, c) = :wide }; end\n")
        write("lib/use.rb", "using ObjCenter\nusing RW\n\"x\".center(1, 2, 3)\n")
        write("lib/control.rb", "\"x\".center(1, 2, 3)\n")

        expect(call_rows).to eq(controls([1]))
      end

      # Ruby 4.0.5 answers `:str`: a `using` whose argument is not a constant may put any module in effect.
      it "declines under a `using` whose argument is not a constant" do
        write("lib/str_ref.rb", "module StrRef; refine(String) { def center(a, b, c) = :str }; end\n")
        write("lib/use.rb", "using ObjCenter\nusing Object.const_get(:StrRef)\n\"x\".center(1, 2, 3)\n")
        write("lib/control.rb", "\"x\".center(1, 2, 3)\n")

        expect(call_rows).to eq(controls([1]))
      end

      # Ruby 4.0.5 answers `:anon`: the refine body of a `using Module.new { … }` runs on a module no constant names.
      it "declines under a `using Module.new { … }`" do
        write("lib/use.rb", <<~RUBY)
          using ObjCenter
          using Module.new { refine(String) { def center(a, b, c) = :anon } }
          "x".center(1, 2, 3)
        RUBY

        expect(call_rows).to eq([])
      end

      # Round 3 of #1793's review. Ruby 4.0.5 answers `:each_target` and `:alias_target`: a target the walk cannot
      # name may be `String`, whichever definer `ObjCenter` would leave first. Requiring `round3.rb` before
      # `by_shadow_string.rb` answers `:shadow`, the other order raises: `refine(String)` names `::String` while
      # `ByShadow::String` is not loaded yet, so the raw table's every spelling counts, not the one the typed arm
      # resolves.
      it "declines under a refinement whose target the walk cannot name or pin" do
        write("lib/round3.rb", <<~RUBY)
          K = String
          module ObjLjust; refine(Object) { def ljust(a, b, c) = a; def rjust(a, b, c) = a }; end
          module ByEach; [String].each { |k| refine(k) { def center(a, b, c) = :each_target } }; end
          module ByAlias; refine(K) { def ljust(a, b, c) = :alias_target }; end
          module ByShadow; refine(String) { def rjust(a, b, c) = :shadow }; end
        RUBY
        write("lib/by_shadow_string.rb", "module ByShadow; class String; end; end\n")
        write("lib/use.rb", "using ObjCenter\nusing ObjLjust\nusing ByEach\nusing ByAlias\nusing ByShadow\n" \
                            "\"x\".center(1, 2, 3)\n\"x\".ljust(1, 2, 3)\n\"x\".rjust(1, 2, 3)\n")

        expect(call_rows).to eq([])
      end

      it "answers a report and a decline the same through a warm cache as cold" do
        write("lib/use.rb", "using ObjCenter\nusing CmpClamp\n\"x\".center(1, 2, 3)\n\"a\".clamp(1, 2, 3)\n")
        root = File.join(Dir.pwd, ".rigor", "cache")

        cold = call_rows(cache_store: Rigor::Cache::Store.new(root: root))
        warm = call_rows(cache_store: Rigor::Cache::Store.new(root: root))

        expect(cold).to eq([["use.rb", 3, "call.wrong-arity"]])
        expect(warm).to eq(cold)
      end

      # A names-wildcard row appearing in the refining file may define `String#center`, so the reported call turns
      # silent on the re-check, and back when the row goes (`refinement:*`).
      it "re-checks the `using` file under --incremental when a refine body gains and loses an `import_methods`" do
        write("lib/helper.rb", "module Helper; def center(a, b, c) = 1; end\n")
        refining = lambda do |extra|
          write("lib/extra.rb", "module Extra\n  refine(String) do\n    def shout = 1\n#{extra}  end\nend\n")
        end
        refining.call("")
        write("lib/use.rb", "using ObjCenter\nusing Extra\n\"x\".center(1, 2, 3)\n")
        fires = [["use.rb", 3, "call.wrong-arity"]]

        expect(incremental_call_rows).to eq([fires, false])
        refining.call("    import_methods Helper\n")
        expect(incremental_call_rows).to eq([[], true])
        expect(call_rows).to eq([])
        refining.call("")
        expect(incremental_call_rows).to eq([fires, true])
        expect(call_rows).to eq(fires)
      end

      # A refined class turning into a subclass of the receiver's class in its own file re-checks the call. Ruby 4.0.5
      # raises `ArgumentError` for `Base.new.center(1, 2, 3)` while `Kid` is unrelated, and a value typed as `Base`
      # may be a `Kid`, answering `:kid`, once `Kid < Base`.
      it "re-checks the `using` file under --incremental when a refined class becomes a subclass" do
        write("lib/base.rb", "class Base; def center(a) = a; end\n")
        write("lib/kid.rb", "class Kid; end\n")
        write("lib/kid_ref.rb", "module KidRef; refine(Kid) { def center(a, b, c) = :kid }; end\n")
        write("lib/use.rb", "using KidRef\nBase.new.center(1, 2, 3)\n")
        fires = [["use.rb", 2, "call.wrong-arity"]]

        expect(incremental_call_rows).to eq([fires, false])
        write("lib/kid.rb", "class Kid < Base; end\n")
        expect(incremental_call_rows).to eq([[], true])
        expect(call_rows).to eq([])
        write("lib/kid.rb", "class Kid; end\n")
        expect(incremental_call_rows).to eq([fires, true])
        expect(call_rows).to eq(fires)
      end

      # A new subclass moves the receiver class's subclass set, which no declaration the call read names. Ruby 4.0.5
      # raises for `"x".ljust(1, 2, 3)` until `Sub < String` prepends `Comparable` again, and then answers `:cmp` for
      # a value typed as `String` that is a `Sub`.
      it "re-checks the `using` file under --incremental when a new file declares a subclass" do
        write("lib/rc.rb", "module RC; refine(Comparable) { def ljust(a, b, c) = :cmp }; end\n")
        write("lib/use.rb", "using RC\n\"x\".ljust(1, 2, 3)\n")
        fires = [["use.rb", 2, "call.wrong-arity"]]

        expect(incremental_call_rows).to eq([fires, false])
        write("lib/sub.rb", "class Sub < String; prepend Comparable; end\n")
        expect(incremental_call_rows).to eq([[], true])
        expect(call_rows).to eq([])
        File.delete("lib/sub.rb")
        expect(incremental_call_rows).to eq([fires, true])
        expect(call_rows).to eq(fires)
      end

      # A class whose superclass the tables do not know may be a subclass of any class, so a new file declaring one
      # re-checks the call through `subclass_of:*`. Ruby 4.0.5 answers `:cmp` for a `MyS2` typed as `String`.
      it "re-checks the `using` file under --incremental when a new file declares a Class.new subclass" do
        write("lib/rc.rb", "module RC; refine(Comparable) { def ljust(a, b, c) = :cmp }; end\n")
        write("lib/use.rb", "using RC\n\"x\".ljust(1, 2, 3)\n")
        fires = [["use.rb", 2, "call.wrong-arity"]]

        expect(incremental_call_rows).to eq([fires, false])
        write("lib/sub.rb", "MyS2 = Class.new(String) { prepend Comparable }\n")
        expect(incremental_call_rows).to eq([[], true])
        expect(call_rows).to eq([])
        File.delete("lib/sub.rb")
        expect(incremental_call_rows).to eq([fires, true])
      end

      # A subclass level the walk cannot read hides only modules, so a refinement of `Object` keeps the call
      # checked: with `module Mixin; end`, Ruby 4.0.5 raises for both calls.
      it "keeps checking past a subclass whose mixins the walk cannot read when no module is refined" do
        write_class("Base", "  def center(a) = a\n", "  def center: (untyped) -> untyped\n")
        write("lib/kid.rb", "class Kid < Base\n  include(Object.const_get(:Mixin))\nend\n" \
                            "class MyStr < String\n  include(Object.const_get(:Mixin))\nend\n")
        write("lib/use.rb", "using ObjCenter\nBase.new.center(1, 2, 3)\n\"x\".center(1, 2, 3)\n")

        expect(call_rows).to eq([["use.rb", 2, "call.wrong-arity"], ["use.rb", 3, "call.wrong-arity"]])
      end

      # The declining side of the example above: Ruby 4.0.5 answers `:kid` when the subclass whose mixins the walk
      # cannot read is itself refined, for a value typed as `Base`. Adding the unreadable mixin to a refined subclass
      # keeps the decline under --incremental.
      it "declines where a refined subclass's mixins cannot be read, cold and after an edit" do
        write_class("Base", "  def center(a) = a\n", "  def center: (untyped) -> untyped\n")
        write("lib/mixin.rb", "module Mixin; end\nmodule RK; refine(Kid) { def center(a, b, c) = :kid }; end\n")
        write("lib/kid.rb", "class Kid < Base; end\n")
        write("lib/use.rb", "using ObjCenter\nusing RK\nBase.new.center(1, 2, 3)\n")

        expect(incremental_call_rows).to eq([[], false])
        write("lib/kid.rb", "class Kid < Base\n  include(Object.const_get(:Mixin))\nend\n")
        expect(incremental_call_rows).to eq([[], true])
        expect(call_rows).to eq([])
      end

      def incremental_call_rows
        root = File.join(Dir.pwd, ".rigor", "cache")
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
        fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: %w[lib])
        session = Rigor::Analysis::IncrementalSession.new(
          configuration: configuration, paths: %w[lib], cache_store: Rigor::Cache::Store.new(root: root)
        )
        found, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
        rows = found.select { |d| %w[call.argument-type-mismatch call.wrong-arity].include?(d.qualified_rule) }
                    .map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }.sort
        [rows, warm]
      end
    end
  end

  # ADR-121 WD7 — the refinement table records what it could not read, and a module whose refinements Rigor cannot
  # read is opaque, so a decline follows from a row or from a module no file declares, never from a missing row. Every
  # reported line raises on Ruby 4.0.5. A silent line runs there, or sits under an opaque module, whose refinements
  # Rigor cannot read and which may therefore refine it (the decline is the possibility, not Ruby's answer for the
  # fixture's own module).
  describe "a refinement Rigor cannot read (ADR-121 WD7)" do
    let(:call_rules) { %w[call.undefined-method call.wrong-arity call.argument-type-mismatch] }

    # Issue #1799: one refining module per definer shape.
    let(:definer_shapes) do
      <<~RUBY
        module Helper; def chop(a, b, c) = :im; end
        module ByAliasMethod
          refine(String) do
            def c3(a, b, c) = :alias_method
            alias_method :center, :c3
          end
        end
        module ByAlias
          refine(String) do
            def c3(a, b, c) = :alias
            alias center c3
          end
        end
        module ByDefineMethod
          refine(String) { define_method(:center) { |a, b, c| :dm } }
        end
        module ByImport
          refine(String) { import_methods Helper }
        end
        module ByComputedName
          name = :center
          refine(String) { define_method(name) { |a, b, c| :computed } }
        end
      RUBY
    end

    # `[file basename, line, rule]` for every call-check diagnostic in `lib/`, sorted.
    def call_rows
      diagnostics.select { |d| call_rules.include?(d.qualified_rule) }
                 .map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }
                 .sort
    end

    # Issue #1796. Ruby 4.0.5 prints `:gem`; `b.rb`, with no `using`, raises `ArgumentError (given 3, expected 1..2)`.
    it "declines every call under a `using` of a module required from outside the analysed paths" do
      write("outside/gemref.rb", "module GemRef; refine(String) { def center(a, b, c) = :gem }; end\n")
      write("lib/a.rb", <<~RUBY)
        $LOAD_PATH.unshift(File.join(__dir__, "..", "outside"))
        require "gemref"
        using GemRef
        p "s".center(1, 2, 3)
        p "s".nope_anything
        p :sym.center(1, 2, 3)
        p Integer.oo
      RUBY
      write("lib/b.rb", "p \"s\".center(1, 2, 3)\n")

      expect(call_rows).to eq([["b.rb", 1, "call.wrong-arity"]])
    end

    # Issue #1799, one refining module per shape so no row masks another. Ruby 4.0.5 prints `:alias_method`,
    # `:alias`, `:dm`, `:im` and `:computed` for the five refined calls, and raises `ArgumentError` for each
    # `ljust(1, 2, 3)` / `succ(2)` control and for `center(1, 2, 3)` with no `using`.
    it "declines a name a refine body defines by alias, alias_method, define_method or import_methods" do
      write("lib/ext.rb", definer_shapes)
      %w[ByAliasMethod ByAlias ByDefineMethod].each do |mod|
        write("lib/#{mod.downcase}.rb", "using #{mod}\n\"x\".center(1, 2, 3)\n\"x\".ljust(1, 2, 3)\n")
      end
      write("lib/byimport.rb", "using ByImport\n\"x\".chop(1, 2, 3)\n1.succ(2)\n")
      write("lib/bycomputedname.rb", "using ByComputedName\n\"x\".center(1, 2, 3)\n1.succ(2)\n")
      write("lib/plain.rb", "\"x\".center(1, 2, 3)\n")

      expect(call_rows).to eq(
        [["byalias.rb", 3, "call.wrong-arity"], ["byaliasmethod.rb", 3, "call.wrong-arity"],
         ["bycomputedname.rb", 3, "call.wrong-arity"], ["bydefinemethod.rb", 3, "call.wrong-arity"],
         ["byimport.rb", 3, "call.wrong-arity"], ["plain.rb", 1, "call.wrong-arity"]]
      )
    end

    # Round 3 of #1793's review. Ruby 4.0.5 prints `:each_target` and `:alias_target` (`refine_census_spec.rb`).
    it "declines a refined name whose target the walk cannot name, on any receiver" do
      write("lib/ext.rb", <<~RUBY)
        K = String
        module ByEach
          [String].each { |k| refine(k) { def center(a, b, c) = :each_target } }
        end
        module ByAlias
          refine(K) { def ljust(a, b, c) = :alias_target }
        end
      RUBY
      write("lib/use.rb", <<~RUBY)
        using ByEach
        using ByAlias
        "x".center(1, 2, 3)
        "x".ljust(1, 2, 3)
        "x".rjust(1, 2, 3)
      RUBY

      expect(call_rows).to eq([["use.rb", 5, "call.wrong-arity"]])
    end

    # A6. Ruby 4.0.5 prints `:or_assign` and `:const_set_target`.
    it "declines a refined name whose target the file binds by ||= or a literal const_set" do
      write("lib/ext.rb", <<~RUBY)
        K ||= String
        Object.const_set(:L, String)
        module ByOrAssign
          refine(K) { def center(a, b, c) = :or_assign }
        end
        module ByConstSet
          refine(L) { def ljust(a, b, c) = :const_set_target }
        end
      RUBY
      write("lib/use.rb", "using ByOrAssign\nusing ByConstSet\n\"x\".center(1, 2, 3)\n\"x\".ljust(1, 2, 3)\n" \
                          "\"x\".rjust(1, 2, 3)\n")

      expect(call_rows).to eq([["use.rb", 5, "call.wrong-arity"]])
    end

    # Ruby 4.0.5 prints `:c`: a refine block is in effect inside itself whatever its target, and its class-unknown row
    # reaches the String receiver there.
    it "is in effect inside its own refine block whose target the walk cannot name" do
      write("lib/m.rb", <<~RUBY)
        module M
          [String].each do |k|
            refine(k) do
              def center(a, b, c) = :c
              def twice = "x".center(1, 2, 3)
            end
          end
        end
        "x".center(1, 2, 3)
      RUBY

      expect(call_rows).to eq([["m.rb", 9, "call.wrong-arity"]])
    end

    # Ruby 4.0.5 raises `NoMethodError` for `String.make` before the `using`, prints `:made` after it, and raises for
    # `String.nope`: a class-unknown row reaches a class object, for its own names only.
    it "declines a class object's call a refinement whose target the walk cannot name defines" do
      write("lib/m.rb", <<~RUBY)
        module M
          [String.singleton_class].each { |k| refine(k) { def make = :made } }
        end
        String.make
        using M
        String.make
        String.nope
      RUBY

      expect(call_rows).to eq([["m.rb", 4, "call.undefined-method"], ["m.rb", 7, "call.undefined-method"]])
    end

    # Round 2 of #1793's review. Ruby 4.0.5 prints `:vendored`.
    it "declines under a `using` of a module that includes a module declared outside the analysed paths" do
      write("vendor/b.rb", "module B; refine(String) { def center(a, b, c) = :vendored }; end\n")
      write("lib/a.rb", <<~RUBY)
        require_relative "../vendor/b"
        module A
          include B
        end
        using A
        p "s".center(1, 2, 3)
      RUBY

      expect(call_rows).to eq([])
    end

    # Ruby 4.0.5 prints `:ext` and raises `NoMethodError` for both `nope` calls.
    it "keeps checking under a `using` of a project module from a nested body, and of one that refines nothing" do
      write("lib/ext.rb", "module Ext; refine(String) { def shout = :ext }; end\nmodule Helpers; def helper = 1; end\n")
      write("lib/use.rb", <<~RUBY)
        module Outer
          using Ext
          "x".shout
          "x".nope
        end
        using Helpers
        "x".nope
        "x".center(1, 2, 3)
      RUBY

      expect(call_rows).to eq(
        [["use.rb", 4, "call.undefined-method"], ["use.rb", 7, "call.undefined-method"],
         ["use.rb", 8, "call.wrong-arity"]]
      )
    end

    # Critique F1. `rb/p6load`: requiring `foo.rb` first prints `:bar`; requiring `foo_bar.rb` first raises
    # `ArgumentError`. Which `Bar` the `using` names depends on load order, so both stay listed.
    it "keeps both declared candidates of a `using` listed" do
      write("lib/bar.rb", "module Bar; refine(String) { def center(a, b, c) = :bar; def shout = :bar }; end\n")
      write("lib/foo_bar.rb", "module Foo; module Bar; refine(String) { def upcase = :inner }; end; end\n")
      write("lib/foo.rb", <<~RUBY)
        require_relative "bar"
        module Foo
          using Bar
          "x".center(1, 2, 3)
          "x".shout
          "x".nope
        end
      RUBY

      expect(call_rows).to eq([["foo.rb", 6, "call.undefined-method"]])
    end

    # Each row kind rides the cross-file pre-pass and the seed bundle: the consumers answer the same cold, warm, and
    # warm with only the consumers re-analysed (their refining files served from their seed bundles).
    it "carries each wildcard row kind across files and through a warm run" do
      write("lib/nw.rb", "module NW\n  refine(String) { import_methods Helper }\nend\n")
      write("lib/cu.rb", "module CU\n  [String].each { |k| refine(k) { def ljust(a, b, c) = 1 } }\nend\n")
      write("lib/bu.rb", "module BU\n  def self.setup(k) = refine(k) { def x = 1 }\nend\n")
      write("lib/u1.rb", "using NW\n\"x\".center(1, 2, 3)\n1.succ(2)\n")
      write("lib/u2.rb", "using CU\n\"x\".ljust(1, 2, 3)\n\"x\".rjust(1, 2, 3)\n")
      write("lib/u3.rb", "using BU\n\"x\".nope\n:s.nope\n")
      write("lib/plain.rb", "\"x\".nope\n")
      expected = [["plain.rb", 1, "call.undefined-method"], ["u1.rb", 3, "call.wrong-arity"],
                  ["u2.rb", 3, "call.wrong-arity"]]
      store = -> { Rigor::Cache::Store.new(root: File.join(Dir.pwd, ".rigor", "cache")) }
      rows = lambda do
        diagnostics(cache_store: store.call).select { |d| call_rules.include?(d.qualified_rule) }
                                            .map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }.sort
      end

      expect(rows.call).to eq(expected)
      expect(rows.call).to eq(expected)
      %w[u1 u2 u3].each { |name| File.write("lib/#{name}.rb", "#{File.read("lib/#{name}.rb")}nil\n") }
      expect(rows.call).to eq(expected)
    end

    describe "edited between runs" do
      def incremental_rows
        root = File.join(Dir.pwd, ".rigor", "cache")
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
        fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: %w[lib])
        session = Rigor::Analysis::IncrementalSession.new(
          configuration: configuration, paths: %w[lib], cache_store: Rigor::Cache::Store.new(root: root)
        )
        found, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
        rows = found.select { |d| call_rules.include?(d.qualified_rule) }
                    .map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }.sort
        [rows, warm]
      end

      def cached_rows
        diagnostics(cache_store: Rigor::Cache::Store.new(root: File.join(Dir.pwd, ".rigor", "cache-cold-warm")))
          .select { |d| call_rules.include?(d.qualified_rule) }
          .map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }.sort
      end

      let(:center_fires) { [["u.rb", 2, "call.wrong-arity"]] }

      def write_refinement(extra = "")
        write("lib/r.rb", "module Shout\n  refine String do\n    def shout = upcase\n#{extra}  end\nend\n")
      end

      # A names-wildcard row appearing re-checks the consumer through `refinement:*` (A5).
      it "re-checks the `using` file when a refine body gains and loses an `import_methods`" do
        write_refinement
        write("lib/u.rb", "using Shout\n\"a\".center(1, 2, 3)\n")
        expect(incremental_rows).to eq([center_fires, false])
        expect(cached_rows).to eq(center_fires)

        write_refinement("    import_methods Helper\n")
        expect(incremental_rows).to eq([[], true])
        expect(cached_rows).to eq([])
        expect(call_rows).to eq([])

        write_refinement
        expect(incremental_rows).to eq([center_fires, true])
        expect(cached_rows).to eq(center_fires)
      end

      # A3 + A5: the new file declares no module and names no class the consumer read; only the `:refine` literal's
      # targets-wildcard row ties it to the consumer. Ruby 4.0.5 runs `M.send(:refine, String) { … }`
      # (`refine_census_spec.rb`).
      it "re-checks the `using` file when a new file refines its module through `send(:refine, …)`" do
        write("lib/m.rb", "module M\n  refine(String) { def shout = 1 }\nend\n")
        write("lib/u.rb", "using M\n\"a\".center(1, 2, 3)\n")
        expect(incremental_rows).to eq([center_fires, false])
        expect(cached_rows).to eq(center_fires)

        write("lib/m_ext.rb", "M.send(:refine, String) { def center(a, b, c) = 1 }\n")
        expect(incremental_rows).to eq([[], true])
        expect(cached_rows).to eq([])
        expect(call_rows).to eq([])
      end

      # A6: `refine(K)` keeps a normal row; once a file binds `K` to a value, the row's class is the wildcard. Ruby
      # 4.0.5 prints `:alias_target` for `K = String; refine(K) { … }` (`refine_census_spec.rb`). The visibility
      # decline shows it: a row under a class nothing declares matches no receiver there. (The argument checks
      # decline under such a row either way, since the class may be a subclass of the receiver's, #1820.)
      it "re-checks the `using` file when a new file binds the constant a `refine` targets" do
        write("lib/m.rb", "module M\n  refine(K) { def shout = 1 }\nend\n")
        write("lib/u.rb", "using M\n\"a\".shout\n")
        expect(incremental_rows).to eq([[["u.rb", 2, "call.undefined-method"]], false])

        write("lib/k.rb", "K = String\n")
        expect(incremental_rows).to eq([[], true])
        expect(call_rows).to eq([])
      end

      # The `using`'s only candidate is declared by no file, so it is opaque; a new file declaring it with no
      # refinement makes it known, and the call reports. Ruby 4.0.5 raises `ArgumentError` for that program.
      it "re-checks the `using` file when a new file declares the module its `using` names" do
        write("lib/u.rb", "using GemRef\n\"a\".center(1, 2, 3)\n")
        expect(incremental_rows).to eq([[], false])
        expect(cached_rows).to eq([])

        write("lib/gemref.rb", "module GemRef\nend\n")
        expect(incremental_rows).to eq([center_fires, true])
        expect(cached_rows).to eq(center_fires)
        expect(call_rows).to eq(center_fires)
      end
    end

    # A `refine` whose `self` is rebound when it runs. Ruby 4.0.5 prints `:dm_extend`, `:top_block` and
    # `:other_module`: a `define_method` body runs on the module that extends its owner, a top-level block an eval
    # runs refines for the eval's receiver, and so does a block a DSL in another module's body runs. `plain.rb`, with
    # no `using`, raises `ArgumentError`.
    {
      "a define_method body" => {
        "lib/m.rb" => "module Helper\n  define_method(:setup) do\n    " \
                      "refine(String) { def center(a, b, c) = :dm_extend }\n  end\nend\n" \
                      "module N; extend Helper; setup; end\n",
        "lib/use.rb" => "using N\n\"x\".center(1, 2, 3)\n"
      },
      "a top-level block an eval runs" => {
        "lib/ext.rb" => "module Ext\n  def self.define(&blk) = module_eval(&blk)\nend\n",
        "lib/setup.rb" => "Ext.define do\n  refine(String) { def center(a, b, c) = :top_block }\nend\n",
        "lib/use.rb" => "using Ext\n\"x\".center(1, 2, 3)\n"
      },
      "a block another module's DSL runs" => {
        "lib/registry.rb" => "module Registry\n  def self.refining(mod, &blk) = mod.module_eval(&blk)\nend\n",
        "lib/m.rb" => "module Ext; end\nmodule Setup\n  Registry.refining(Ext) do\n    " \
                      "refine(String) { def center(a, b, c) = :other_module }\n  end\nend\n",
        "lib/use.rb" => "using Ext\n\"x\".center(1, 2, 3)\n"
      }
    }.each do |shape, files|
      it "declines under a `using` of a module refined in #{shape}" do
        files.each { |path, source| write(path, source) }
        write("lib/plain.rb", "\"x\".center(1, 2, 3)\n")

        expect(call_rows).to eq([["plain.rb", 1, "call.wrong-arity"]])
      end
    end

    # R2: inside a method body a block follows the same rule as in a module body. Ruby 4.0.5 prints `:installed`,
    # `:class_installed`, `:in_def_dsl`, `:const_eval`, `:iexec`, `:dsm_eval`, `:nested_dsm` and `:nested_def`: each
    # `refine` refines for `Ext`, not the module or class its method is written in.
    {
      "an eval block on a parameter in a def self.x" =>
        "module Installer\n  def self.install(mod) = mod.module_eval { refine(String) { def center(a, b, c) = 1 } }\n" \
        "end\nInstaller.install(Ext)\n",
      "an eval block on a parameter in a class's def self.x" =>
        "class Installer\n  def self.install(mod) = mod.module_eval { refine(String) { def center(a, b, c) = 1 } }\n" \
        "end\nInstaller.install(Ext)\n",
      "a DSL block in a def self.x" =>
        "module Registry\n  def self.refining(mod, &blk) = mod.module_eval(&blk)\nend\nmodule Setup\n  " \
        "def self.run = Registry.refining(Ext) { refine(String) { def center(a, b, c) = 1 } }\nend\nSetup.run\n",
      "an eval block on a constant in a def self.x" =>
        "module Installer\n  def self.install = Ext.module_eval { refine(String) { def center(a, b, c) = 1 } }\nend\n" \
        "Installer.install\n",
      "an instance_exec block on a parameter in a def self.x" =>
        "module Installer\n  def self.install(mod) = mod.instance_exec do\n    " \
        "refine(String) { def center(a, b, c) = 1 }\n  end\nend\nInstaller.install(Ext)\n",
      "a define_singleton_method block in a DSL block" =>
        "module Registry\n  def self.refining(mod, &blk) = mod.module_eval(&blk)\nend\nmodule Setup\n  " \
        "Registry.refining(Ext) do\n    define_singleton_method(:install) do\n      " \
        "refine(String) { def center(a, b, c) = 1 }\n    end\n  end\nend\nExt.install\n",
      "a def self.x in a DSL block" =>
        "module Registry\n  def self.refining(mod, &blk) = mod.module_eval(&blk)\nend\nmodule Setup\n  " \
        "Registry.refining(Ext) do\n    def self.install = refine(String) { def center(a, b, c) = 1 }\n  end\nend\n" \
        "Ext.install\n"
    }.each do |shape, setup|
      it "declines under a `using` of a module a method refines through #{shape}" do
        write("lib/ext.rb", "module Ext; end\n")
        write("lib/setup.rb", setup)
        write("lib/use.rb", "using Ext\n\"x\".center(1, 2, 3)\n")
        write("lib/plain.rb", "\"x\".center(1, 2, 3)\n")

        expect(call_rows).to eq([["plain.rb", 1, "call.wrong-arity"]])
      end
    end

    # R2: a core iterator's block on a constant this file binds to a literal keeps `self`, and a core iterator's block
    # on a literal or a `define_method` block in a plain class's method keeps the class, so none of these makes an
    # unrelated `using` opaque. Ruby 4.0.5 prints `:each_const` for `M`'s `center` under `using M`, `[:show, :show]`,
    # `[10, 20]` and `2`, and raises `NoMethodError` for each `"x".nope`.
    it "keeps an unrelated `using` checked and typed where an iterator or a plain class's blocks name refine" do
      write("lib/m.rb", "module M\n  TARGETS = [String, Symbol].freeze\n  " \
                        "TARGETS.each { |k| refine(k) { def center(a, b, c) = :each_const } }\nend\n")
      write("lib/controller.rb",
            "class Controller\n  def actions = %w[a b].map { |a| a == \"x\" ? :refine : :show }\nend\n")
      write("lib/query.rb", <<~RUBY)
        class Query
          def refine(n) = yield(n)
          def all = [1, 2].map { |n| refine(n) { |q| q * 10 } }
          define_method(:one) { refine(1) { |q| "x".nope } }
        end
      RUBY
      write("lib/u.rb", "module Shout\n  refine(String) { def shout = :s }\nend\nusing Shout\n" \
                        "Rigor.dump_type(\"x\".upcase)\n\"x\".nope\n")

      rows = diagnostics.map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }.sort
      expect(rows).to eq(
        [["query.rb", 4, "call.undefined-method"], ["u.rb", 5, "dump.type"], ["u.rb", 6, "call.undefined-method"]]
      )
    end

    # R3-S2: a core iteration method keeps `self` only on a receiver whose value is a literal in this file; a project
    # method of that name on any other receiver, or another name on a literal, may run the block under any `self`.
    # Ruby 4.0.5 prints `:config_each`, `:local_each`, `:array_configure` and `:times` under `using Ext`, one per
    # shape, and raises `ArgumentError (given 3, expected 1..2)` in `plain.rb`.
    {
      "a module's own `each`" =>
        "module Config\n  def self.each(&blk) = Ext.module_eval(&blk)\nend\nmodule Setup\n  " \
        "Config.each { refine(String) { def center(a, b, c) = :config_each } }\nend\n",
      "a local holding a project object" =>
        "module Setup\n  runner = Runner.new(Ext)\n  " \
        "runner.each { refine(String) { def center(a, b, c) = :local_each } }\nend\n",
      "another method on a literal" =>
        "class Array\n  def configure(&blk) = Ext.module_eval(&blk)\nend\nmodule Setup\n  " \
        "[1].configure { refine(String) { def center(a, b, c) = :array_configure } }\nend\n",
      "a module's own `times`" =>
        "module Count\n  def self.times(&blk) = Ext.module_eval(&blk)\nend\nmodule Setup\n  " \
        "Count.times { refine(String) { def center(a, b, c) = :times } }\nend\n"
    }.each do |shape, setup|
      it "declines under a module the block of #{shape} may refine for" do
        write("lib/ext.rb", "module Ext; end\nclass Runner\n  def initialize(mod) = @mod = mod\n  " \
                            "def each(&blk) = @mod.module_eval(&blk)\nend\n")
        write("lib/setup.rb", setup)
        write("lib/use.rb", "using Ext\np \"x\".center(1, 2, 3)\n")
        write("lib/plain.rb", "\"x\".center(1, 2, 3)\n")

        expect(call_rows).to eq([["plain.rb", 1, "call.wrong-arity"]])
      end
    end

    # R3-S3: `M.module_eval { … }` in `module L` runs on `L::M` once a file declares it, so the walk charges every name
    # `M` can denote there; the body may be either one's, so it types from neither. Ruby 4.0.5 prints `:lm` twice,
    # under `using L::M` in each file, and raises `ArgumentError (given 3, expected 1..2)` in `plain.rb`.
    it "declines under a module an eval block's constant receiver names in another file" do
      write("lib/lm.rb", "module L\n  module M; end\nend\n")
      write("lib/setup.rb", "require_relative \"lm\"\nmodule L\n  " \
                            "M.module_eval { refine(String) { def center(a, b, c) = :lm } }\nend\n" \
                            "using L::M\nRigor.dump_type(\"x\".center(1, 2, 3))\n")
      write("lib/u.rb", "require_relative \"setup\"\nusing L::M\np \"x\".center(1, 2, 3)\n")
      write("lib/plain.rb", "\"x\".center(1, 2, 3)\n")

      rows = diagnostics.map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule, d.message] }.sort
      arity = "wrong number of arguments to `center' on String (given 3, expected 1..2)"
      expect(rows).to eq(
        [["plain.rb", 1, "call.wrong-arity", arity], ["setup.rb", 6, "dump.type", "dump_type: Dynamic[top]"]]
      )
    end

    # The union receiver rule and `call.unresolved-toplevel` ask the refinement predicate too. Ruby 4.0.5 prints `:int`
    # and `1` under a `using` of the module (read from outside the analysed paths or from the project alike), and
    # raises `NoMethodError` for both calls in `plain.rb`.
    it "declines a union receiver's call and an implicit-self top-level call a refinement in effect may define" do
      refinement = "refine(Integer) { def shout = :int }\n  refine(Symbol) { def shout = :sym }\n  " \
                   "refine(Object) { def helper(x) = x }\n"
      calls = "x = ARGV.empty? ? 1 : :a\np x.shout\np helper(1)\n"
      write("outside/gemref.rb", "module GemRef\n  #{refinement}end\n")
      write("lib/opaque.rb", "$LOAD_PATH.unshift(File.join(__dir__, \"..\", \"outside\"))\nrequire \"gemref\"\n" \
                             "using GemRef\n#{calls}")
      write("lib/readable.rb", "module R\n  #{refinement}end\nusing R\n#{calls}")
      write("lib/plain.rb", calls)

      rows = diagnostics.select { |d| %w[call.undefined-method call.unresolved-toplevel].include?(d.qualified_rule) }
                        .map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }.sort
      expect(rows).to eq([["plain.rb", 2, "call.undefined-method"], ["plain.rb", 3, "call.unresolved-toplevel"]])
    end

    # M3. In a plain class's method a `:refine` Symbol is data and a `refine` call is the class's own method: Ruby
    # 4.0.5 runs `Query#refine`'s block with no refinement in effect (`"x".nope` raises there) and prints `"X"`.
    it "keeps checks and types where a plain class's method names refine" do
      write("lib/c.rb", "class Controller\n  def action_name = :refine\nend\n")
      write("lib/q.rb", <<~RUBY)
        class Query
          def refine(extra) = yield(extra)
          def narrowed
            refine(1) do |q|
              Rigor.dump_type("x".upcase)
              "x".nope
            end
          end
        end
      RUBY
      write("lib/u.rb", "module Shout\n  refine(String) { def shout = :s }\nend\nusing Shout\n" \
                        "Rigor.dump_type(\"x\".upcase)\n\"x\".center(1, 2, 3)\n")

      rows = diagnostics.map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule, d.message] }.sort
      expect(rows).to eq(
        [["q.rb", 5, "dump.type", %(dump_type: "X")],
         ["q.rb", 6, "call.undefined-method", "undefined method `nope' for \"x\""],
         ["u.rb", 5, "dump.type", %(dump_type: "X")],
         ["u.rb", 6, "call.wrong-arity", "wrong number of arguments to `center' on String (given 3, expected 1..2)"]]
      )
    end

    # R3-M1: a parameter's default runs in the method's body, so a `:refine` default in a plain class's method is data
    # and makes no `using` opaque. Ruby 4.0.5 prints `:refine` and `"X"`, and raises `NoMethodError` for `"x".nope`.
    it "keeps checks and types where a plain class's parameter defaults name refine" do
      write("lib/search.rb", "class Search\n  def initialize(mode = :refine) = @mode = mode\n  " \
                             "def self.build(kind = :refine) = new(kind)\nend\np Search.build\n")
      write("lib/u.rb", "module Shout\n  refine(String) { def shout = :s }\nend\nusing Shout\n" \
                        "Rigor.dump_type(\"x\".upcase)\n\"x\".nope\n")

      rows = diagnostics.map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }.sort
      expect(rows).to eq([["u.rb", 5, "dump.type"], ["u.rb", 6, "call.undefined-method"]])
    end

    # R2-S3: `call.possible-nil-receiver`, `def.method-visibility-mismatch` and `flow.always-raises` ask the refinement
    # predicate too. Each file run with `lib/foo.rb` required first (`ruby -r ./lib/foo.rb lib/opaque.rb`), Ruby 4.0.5
    # prints `:nil_up`, `:public_secret` and `:no_raise` under a `using` of the module (read from outside the analysed
    # paths or from the project alike), and raises for each call in `plain.rb`, each run after its first line.
    it "declines a nil receiver's, a private method's and a zero division's report a refinement in effect may answer" do
      write("lib/foo.rb", "class Foo\n  private\n\n  def secret = 1\nend\n")
      refinement = "refine(NilClass) { def upcase = :nil_up }\n  refine(Foo) { def secret = :public_secret }\n  " \
                   "refine(Integer) { def /(other) = :no_raise }\n"
      calls = "x = ARGV.empty? ? nil : \"a\"\np x.upcase\np Foo.new.secret\np 1 / 0\n"
      write("outside/gemref.rb", "module GemRef\n  #{refinement}end\n")
      write("lib/opaque.rb", "$LOAD_PATH.unshift(File.join(__dir__, \"..\", \"outside\"))\nrequire \"gemref\"\n" \
                             "using GemRef\n#{calls}")
      write("lib/readable.rb", "module R\n  #{refinement}end\nusing R\n#{calls}")
      write("lib/plain.rb", calls)

      rules = %w[call.possible-nil-receiver def.method-visibility-mismatch flow.always-raises]
      rows = diagnostics.select { |d| rules.include?(d.qualified_rule) }
                        .map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }.sort
      expect(rows).to eq(
        [["plain.rb", 2, "call.possible-nil-receiver"], ["plain.rb", 3, "def.method-visibility-mismatch"],
         ["plain.rb", 4, "flow.always-raises"]]
      )
    end

    # R3-S1: a file may hold bytes its encoding does not, here binary `__END__` data, and the refinement scans read
    # it as bytes. Ruby 4.0.5 prints `:ext` and `1`, then raises `ArgumentError (given 2, expected 1)` on line 5.
    it "reads a refining file whose `__END__` data is not valid in its encoding" do
      write("lib/a.rb", "module Ext\n  refine(String) { def center(a, b, c) = :ext }\nend\nclass Helper\n  " \
                        "def self.go(a) = a\nend\n__END__\n\x89PNG\xff\xfe binary payload\n")
      write("lib/b.rb", "require_relative \"a\"\nusing Ext\np \"x\".center(1, 2, 3)\np Helper.go(1)\nHelper.go(1, 2)\n")

      rows = diagnostics.map { |d| [File.basename(d.path.to_s), d.line, d.qualified_rule] }
      expect(rows).to eq([["b.rb", 5, "call.wrong-arity"]])
    end

    # Critique F5a. Ruby 4.0.5 prints `:via_alias` (`rb/p4_alias_refine.rb`).
    it "declines under a module that refines through an alias of `refine`" do
      write("lib/m.rb", <<~RUBY)
        module M
          class << self
            alias_method :my_refine, :refine
          end
          my_refine(String) { def shout = :via_alias }
        end
        using M
        "s".shout
      RUBY

      expect(call_rows).to eq([])
    end
  end

  # Issue #1749. Ruby 4.0.5 prints `1` for `"a".yy` after `M.setup` under `using M`, for a `refine` in `def self.setup`
  # and in a `def` written in `class << self`; the same line with no `using` and `"a".zz` raise `NoMethodError`. A
  # `refine` in a module's instance method refines for whichever module calls it, and a class has no `refine` (`Class`
  # undefines it), so `class C; def self.setup = refine(String) { … }; end; C.setup` raises `NoMethodError`.
  describe "a refine in a module's singleton method (#1749)" do
    let(:shapes) do
      {
        "def self.setup" => "module M\n  def self.setup\n    refine(String) { def yy = 1 }\n  end\nend\n",
        "a def in class << self" =>
          "module M\n  class << self\n    def setup\n      refine(String) { def yy = 1 }\n    end\n  end\nend\n"
      }
    end
    let(:expected) { [["other.rb", 3, "yy"], ["plain.rb", 1, "yy"], ["use.rb", 4, "zz"]] }

    def write_project(source)
      write("lib/m.rb", source)
      write("lib/use.rb", "M.setup\nusing M\n\"a\".yy\n\"a\".zz\n")
      write("lib/plain.rb", "\"a\".yy\n")
      write("lib/other.rb", "module P; end\nusing P\n\"a\".yy\n")
    end

    it "reads the module's refinement: its method is known, any other name and any other module still report" do
      shapes.each do |shape, source|
        write_project(source)

        expect(undefined_rows).to eq(expected), shape
      end
    end

    # Ruby 4.0.5 prints `1` for `"a".yy` after `M.setup`, whose target `Foo` a `class << self` body binds. That write is
    # one no project-wide table sees, so the row is the wildcard class's: `yy` declines, `zz` still reports.
    it "reads a target a class << self body binds as a class Rigor cannot name, so only the names it defines decline" do
      write("lib/m.rb", <<~RUBY)
        module M
          class << self
            Foo = String
            def setup
              refine(Foo) { def yy = 1 }
            end
          end
        end
      RUBY
      write("lib/use.rb", "M.setup\nusing M\n\"a\".yy\n\"a\".zz\n")
      write("lib/plain.rb", "\"a\".yy\n")

      expect(undefined_rows).to eq([["plain.rb", 1, "yy"], ["use.rb", 4, "zz"]])
    end

    it "answers the same through a warm cache as cold, and with only the consumers re-analysed" do
      shapes.each do |shape, source|
        write_project(source)
        use_source = File.read("lib/use.rb")
        root = File.join(Dir.pwd, ".rigor", "cache-#{shapes.keys.index(shape)}")
        store = -> { Rigor::Cache::Store.new(root: root) }

        expect(undefined_rows(cache_store: store.call)).to eq(expected), shape
        expect(undefined_rows(cache_store: store.call)).to eq(expected), shape
        File.write("lib/use.rb", "#{use_source}nil\n")
        expect(undefined_rows(cache_store: store.call)).to eq(expected), shape
      end
    end

    it "keeps the unreadable cases unreadable: an instance method's refine opaques every module, a class's none" do
      write("lib/h.rb", "module H\n  def setup = refine(String) { def yy = 1 }\nend\n")
      write("lib/n.rb", "module N\n  extend H\n  setup\nend\nusing N\n\"a\".zz\n")
      write("lib/p.rb", "module P; end\nusing P\n\"a\".zz\n\"a\".yy\n")
      write("lib/plain.rb", "\"a\".zz\n")

      expect(undefined_rows).to eq([["plain.rb", 1, "zz"]])

      FileUtils.rm("lib/h.rb")
      write("lib/c.rb", "class C\n  def self.setup = refine(String) { def yy = 1 }\nend\n")

      expect(undefined_rows).to eq([["n.rb", 6, "zz"], ["p.rb", 3, "zz"], ["p.rb", 4, "yy"], ["plain.rb", 1, "zz"]])
    end
  end

  describe "a singleton def on a local" do
    it "declines for that local's method in the same scope and nowhere else" do
      write("lib/locals.rb", <<~RUBY)
        o = Object.new
        def o.announce = 1
        o.announce

        h = {}
        def h.special = 42
        h.special

        logger = Object.new
        def logger.info(msg) = puts(msg)
        logger.info("x")
        logger.warn_ctl("x")

        other = Object.new
        other.announce

        def helper
          o = Object.new
          o.announce
        end
      RUBY

      expect(undefined_rows).to eq(
        [["locals.rb", 12, "warn_ctl"], ["locals.rb", 15, "announce"], ["locals.rb", 19, "announce"]]
      )
    end
  end

  it "leaves a plain monkey-patch unchanged" do
    write("lib/patch.rb", <<~RUBY)
      class String
        def patched = upcase
      end
      "a".patched
      "a".nonexistent_ctl
    RUBY

    expect(undefined_rows).to eq([["patch.rb", 5, "nonexistent_ctl"]])
  end

  # Issue #1689 — `Class` undefines `refine`, so a `refine` call in a class body is the class's own method. Here
  # `Widget.refine` yields, and the block's `def` defines `Widget#label`, whose `self` is a Widget, like any `def`
  # in a block in that body. A project class has no RBS, so `call.undefined-method` does not fire on it either way;
  # the def's `self` is the observable.
  it "treats a `refine` call in a class body as the class's own method, not a refinement" do
    write("lib/widget.rb", <<~RUBY)
      class Widget
        def self.refine(_target) = yield

        refine String do
          def label = dump_type(self)
        end
      end
    RUBY

    dumps = diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)

    expect(dumps).to eq(["dump_type: Widget"])
  end
end
