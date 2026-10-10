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
      write("lib/bu.rb", "module BU\n  def self.setup = refine(String) { def x = 1 }\nend\n")
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
      # 4.0.5 prints `:alias_target` for `K = String; refine(K) { … }` (`refine_census_spec.rb`).
      it "re-checks the `using` file when a new file binds the constant a `refine` targets" do
        write("lib/m.rb", "module M\n  refine(K) { def center(a, b, c) = 1 }\nend\n")
        write("lib/u.rb", "using M\n\"a\".center(1, 2, 3)\n")
        expect(incremental_rows).to eq([center_fires, false])

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
