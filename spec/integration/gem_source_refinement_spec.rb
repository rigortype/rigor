# frozen_string_literal: true

# Issue #1672 — gem source inference (`dependencies.source_inference:`) recognises `refine X do … end` bodies.
#
# A refine-body `def` in an opted-in gem is a refinement of X, visible after `using M`, and not an instance method
# of the refining module M. Before the fix the walker filed it as `M#shout` and the project's refinement table
# never learnt `String#shout`, so `using M; "hi".shout` reported `call.undefined-method`.
#
# Issue #1814 — a gem's refining module stays opaque (#1811), so where a gem's rows are the observable the `using`
# names no module: that declines the names some row defines and reports every other. The gem walker reads a gem's
# `refine` calls through the census the project walk runs, and a refine key is decided at read time, per segment,
# from the project's constant census and the constants the opted-in gems write.
#
# Every expectation below is the answer CRuby gives for the same source: a silent line runs, a reported line
# raises `NoMethodError`.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/incremental_run_slot"
require "rigor/analysis/incremental_session"
require "rigor/analysis/runner"
require "rigor/cache/incremental_snapshot"
require "rigor/cache/store"
require "rigor/configuration"

RSpec.describe "Gem source inference over `refine` bodies (#1672)" do
  around do |example|
    Dir.mktmpdir("rigor-gem-refine-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:gem_dir) { File.join(Dir.pwd, "vendor", "shouty") }

  before do
    write("vendor/shouty/lib/shouty.rb", <<~RUBY)
      module Shouty
        refine String do
          def shout = upcase + "!"
        end

        def whisper = "psst"
      end
    RUBY
    allow(Rigor::Analysis::DependencySourceInference::GemResolver)
      .to receive(:locate_gem_spec).and_call_original
    stub_gem("shouty", "1.0.0")
  end

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  # Makes `name` resolve to `vendor/<name>`, at `version`, as the bundle would.
  def stub_gem(name, version)
    spec = instance_double(Gem::Specification, version: Gem::Version.new(version),
                                               full_gem_path: File.join(Dir.pwd, "vendor", name))
    allow(Rigor::Analysis::DependencySourceInference::GemResolver)
      .to receive(:locate_gem_spec).with(name).and_return(spec)
  end

  # Writes `vendor/<name>/<relative>` for each pair, and resolves `name`.
  def write_gem(name, files, version = "1.0.0")
    files.each { |relative, contents| write("vendor/#{name}/#{relative}", contents) }
    stub_gem(name, version)
  end

  def configuration(workers: 0, gems: %w[shouty])
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "workers" => workers,
        "dependencies" => { "source_inference" => gems.map { |name| { "gem" => name, "mode" => "when_missing" } } }
      )
    )
  end

  def undefined_rows_of(found)
    found.select { |d| d.qualified_rule == "call.undefined-method" }
         .map { |d| [File.basename(d.path.to_s), d.line, d.method_name.to_s] }.sort
  end

  # `[file basename, line, method name]` for every `call.undefined-method`, sorted.
  def undefined_rows(cache_store: nil, workers: 0, gems: %w[shouty])
    runner = Rigor::Analysis::Runner.new(configuration: configuration(workers: workers, gems: gems),
                                         cache_store: cache_store)
    undefined_rows_of(guarded_run(runner, %w[lib]).diagnostics)
  end

  # ADR-121 WD7 — a module the project does not declare is opaque, a walked gem's included, so `"hi".nope` after
  # `using Shouty` declines too (it reported before). Flip the `nope` row back when gem modules whose source the walker
  # read become known (#1814).
  it "resolves a gem refinement after `using`, and reports it before" do
    write("lib/app.rb", <<~RUBY)
      "early".shout
      using Shouty
      "hi".shout
      "hi".nope
    RUBY

    expect(undefined_rows).to eq([["app.rb", 1, "shout"]])
  end

  # Under a `using` that names no module, a name some refinement defines declines and any other name reports, so the
  # gem's refinements still reach the check rules.
  it "declines a gem-refined name under a `using` that names no module, and reports any other name" do
    write("lib/app.rb", <<~RUBY)
      using Module.new { }
      "hi".shout
      "hi".nope
    RUBY

    expect(undefined_rows).to eq([["app.rb", 3, "nope"]])
  end

  it "still reports a refined call in a project that never `using`s the module" do
    write("lib/app.rb", <<~RUBY)
      "hi".shout
    RUBY

    expect(undefined_rows).to eq([["app.rb", 1, "shout"]])
  end

  # A value typed as a module declines `call.undefined-method` whatever its methods (#739), so the catalogue
  # entry itself is the observable: the dispatcher's gem-source tier reads `contribution_for`.
  it "does not file a refine-body def as the refining module's own method" do
    write("lib/app.rb", "using Shouty\n")
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    guarded_run(runner, %w[lib])
    index = runner.dependency_source_index

    expect(index.contribution_for(class_name: "Shouty", method_name: :whisper)).not_to be_nil
    expect(index.contribution_for(class_name: "Shouty", method_name: :shout)).to be_nil
    expect(index.refinements).to include("String" => { shout: ["Shouty"] })
  end

  # `unknown.rb` keeps the gem table observable now that `using Shouty` makes `app.rb` opaque (flip `app.rb`'s `nope`
  # row back with the example above).
  it "seeds a file re-analysed on a warm run with the gem refinements" do
    write("lib/app.rb", <<~RUBY)
      using Shouty
      "hi".shout
      "hi".nope
    RUBY
    write("lib/unknown.rb", "using Module.new { }\n\"hi\".shout\n\"hi\".nope\n")
    root = File.join(Dir.pwd, ".rigor-cache")
    cold = undefined_rows(cache_store: Rigor::Cache::Store.new(root: root))
    File.write("lib/app.rb", "#{File.read('lib/app.rb')}\"again\".shout\n")
    File.write("lib/unknown.rb", "#{File.read('lib/unknown.rb')}\"again\".shout\n")

    warm = undefined_rows(cache_store: Rigor::Cache::Store.new(root: root))

    expect(cold).to eq([["unknown.rb", 3, "nope"]])
    expect(warm).to eq(cold)
  end

  it "seeds pool workers with the gem refinements" do
    write("lib/app.rb", <<~RUBY)
      using Shouty
      "hi".shout
      "hi".nope
    RUBY
    write("lib/other.rb", "\"x\".shout\n")
    write("lib/unknown.rb", "using Module.new { }\n\"hi\".shout\n\"hi\".nope\n")

    expect(undefined_rows(workers: 2)).to eq([["other.rb", 1, "shout"], ["unknown.rb", 3, "nope"]])
  end

  # Issue #1814 (#1815 item 5) — a refine key is decided at read time, per segment, from the project's constant census
  # and the constants the opted-in gems write without declaring a class or module by them: a key with a bound segment
  # names whatever value the write holds, so its names decline on every receiver (a class-unknown row), where a
  # normal row keyed by a name no class declares matched no receiver and reported the refined call on correct code.
  describe "a refine target a constant write binds" do
    # Ruby 4.0.5 prints "X" for `"x".shout` after `module Shared; Target = String; end` (a gem) and
    # `module BRef; refine(Shared::Target) { def shout = upcase }; end; using BRef` (the project).
    it "reads a project refine of a target an opted-in gem's constant write binds as class-unknown" do
      write_gem("sharedg", "lib/sharedg.rb" => "module Shared\n  Target = String\nend\n")
      write("lib/bref.rb", "module BRef\n  refine(Shared::Target) { def shout = upcase }\nend\n")
      write("lib/app.rb", "using BRef\n\"x\".shout\n\"x\".nope\n")

      expect(undefined_rows(gems: %w[sharedg])).to eq([["app.rb", 3, "nope"]])
    end

    it "reads a gem refine of a target another opted-in gem's constant write binds the same way" do
      write_gem("sharedg", "lib/sharedg.rb" => "module Shared\n  Target = String\nend\n")
      write_gem("brefg", "lib/brefg.rb" => "module BRef\n  refine(Shared::Target) { def shout = upcase }\nend\n")
      write("lib/app.rb", "using Module.new { }\n\"x\".shout\n\"x\".nope\n")

      expect(undefined_rows(gems: %w[sharedg brefg])).to eq([["app.rb", 3, "nope"]])
    end

    # Ruby 4.0.5 prints 1 for `Encoding::Converter.new("UTF-8", "EUC-JP").shout` after `Enc = ::Encoding;
    # refine(Enc::Converter) { def shout = 1 }` (#1815 item 5).
    it "reads a target with a prefix a gem's constant write binds as class-unknown" do
      write_gem("pag",
                "lib/pag.rb" => "module Pag\n  Enc = ::Encoding\n  refine(Enc::Converter) { def shout = 1 }\nend\n")
      write("lib/app.rb", "using Module.new { }\nEncoding::Converter.new('UTF-8', 'EUC-JP').shout\n\"x\".nope\n")

      expect(undefined_rows(gems: %w[pag])).to eq([["app.rb", 3, "nope"]])
    end

    # The controls: a class the gem declares by a constant write (`Struct.new`, `Data.define`, `Class.new`) is no
    # bound name, so its refine keeps a normal row that matches no String receiver and the call reports; a write that
    # is no class (`DelegateClass(Array)`) is bound, so `"x".pw` declines; a target no write binds keeps its row.
    it "keeps the row of a class a gem declares by a write, and of a target nothing binds" do
      write_gem("clg", "lib/clg.rb" => <<~RUBY)
        require 'delegate'
        module Clg
          Point = Struct.new(:x)
          Pair = Data.define(:a)
          Wrap = DelegateClass(Array)
          Sub = Class.new(StandardError)
          refine(Point) { def px = x }
          refine(Pair) { def pa = a }
          refine(Wrap) { def pw = 1 }
          refine(Sub) { def ps = 2 }
          refine(Symbol) { def plain = 1 }
        end
      RUBY
      write("lib/app.rb", "using Module.new { }\n\"x\".px\n\"x\".pa\n\"x\".pw\n\"x\".ps\n\"x\".plain\n\"x\".nope\n")

      expect(undefined_rows(gems: %w[clg]))
        .to eq([["app.rb", 2, "px"], ["app.rb", 3, "pa"], ["app.rb", 5, "ps"], ["app.rb", 6, "plain"],
                ["app.rb", 7, "nope"]])
    end
  end

  # ADR-10 slice 3, issue #1814 — the gem half of the refinement table is no analysed file's, so no per-file diff
  # (`Incremental.changed_refinement_names`) sees a gem bump change it, and `app.rb` below never changes. The run's
  # cache identity must: the lockfile digest covers a `bundle update`, and the `(name, version, mode)` rows of the
  # walked gems cover a project with no lockfile. The `using` names no module, so the gem's rows are the observable
  # (a gem module itself is opaque, #1811): the refined name declines and any other reports.
  describe "a gem bump between two warm runs" do
    def bump(version, refine_body)
      write("vendor/shouty/lib/shouty.rb", "module Shouty\n  refine String do\n#{refine_body}  end\nend\n")
      stub_gem("shouty", version)
    end

    def lockfile(version) = write("Gemfile.lock", "GEM\n  specs:\n    shouty (#{version})\n")

    def cached_rows = undefined_rows(cache_store: Rigor::Cache::Store.new(root: File.join(Dir.pwd, ".rigor-cache")))

    def incremental_rows
      root = File.join(Dir.pwd, ".rigor-cache")
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: %w[lib])
      session = Rigor::Analysis::IncrementalSession.new(
        configuration: configuration, paths: %w[lib], cache_store: Rigor::Cache::Store.new(root: root)
      )
      found, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
      [undefined_rows_of(found), warm]
    end

    before do
      bump("1.0.0", "    def shout = upcase\n")
      write("lib/app.rb", "using Module.new { }\n\"hi\".shout\n\"hi\".yell\n")
    end

    [true, false].each do |locked|
      suffix = locked ? "with a lockfile" : "with no lockfile"

      it "re-checks the `using` file when a refined def is renamed, #{suffix}" do
        lockfile("1.0.0") if locked
        expect(cached_rows).to eq([["app.rb", 3, "yell"]])

        bump("1.1.0", "    def yell = upcase\n")
        lockfile("1.1.0") if locked

        expect(cached_rows).to eq([["app.rb", 2, "shout"]])
        expect(undefined_rows).to eq([["app.rb", 2, "shout"]])
      end

      it "re-checks the `using` file when a refine body gains an import_methods, #{suffix}" do
        lockfile("1.0.0") if locked
        expect(cached_rows).to eq([["app.rb", 3, "yell"]])

        bump("1.1.0", "    def shout = upcase\n    import_methods Kernel\n")
        lockfile("1.1.0") if locked

        expect(cached_rows).to eq([])
        expect(undefined_rows).to eq([])
      end

      it "re-checks the `using` file under --incremental, #{suffix}" do
        lockfile("1.0.0") if locked
        expect(incremental_rows).to eq([[["app.rb", 3, "yell"]], false])

        bump("1.1.0", "    def yell = upcase\n")
        lockfile("1.1.0") if locked

        expect(incremental_rows).to eq([[["app.rb", 2, "shout"]], false])
      end
    end

    # The CLI asks the engine-free probe (`IncrementalRunSlot.serve`) before it loads the engine, and the slot's key
    # carries the gems' rows as the plain key does (the round-1 review of #1838 found it dropped them).
    it "declines the engine-free --incremental probe after the bump, with no lockfile" do
      root = File.join(Dir.pwd, ".rigor-cache")
      serve = lambda do
        Rigor::Analysis::IncrementalRunSlot.serve(configuration: configuration, cache_root: root, paths: %w[lib])
      end
      expect(incremental_rows).to eq([[["app.rb", 3, "yell"]], false])
      expect(serve.call).not_to be_nil

      bump("1.1.0", "    def yell = upcase\n")

      expect(serve.call).to be_nil
      expect(incremental_rows).to eq([[["app.rb", 2, "shout"]], false])
      expect(undefined_rows_of(serve.call.result.diagnostics)).to eq([["app.rb", 2, "shout"]])
    end

    # The control: nothing changed, so the run is served from the snapshot and the identity did not move.
    it "keeps serving an unchanged gem from the snapshot" do
      expect(incremental_rows).to eq([[["app.rb", 3, "yell"]], false])
      expect(incremental_rows).to eq([[["app.rb", 3, "yell"]], true])
    end
  end
end
