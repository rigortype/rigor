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

require "rigor/analysis/runner"
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
end
