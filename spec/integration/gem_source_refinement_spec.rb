# frozen_string_literal: true

# Issue #1672 — gem source inference (`dependencies.source_inference:`) recognises `refine X do … end` bodies.
#
# A refine-body `def` in an opted-in gem is a refinement of X, visible after `using M`, and not an instance method
# of the refining module M. Before the fix the walker filed it as `M#shout` and the project's refinement table
# never learnt `String#shout`, so `using M; "hi".shout` reported `call.undefined-method`.
#
# Issue #1814 — a gem module whose source the walker read in full is known on the same terms as a project module, and
# one it could not read in full stays opaque.
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

  def configuration(workers: 0, gems: %w[shouty], budget: nil)
    dependencies = { "source_inference" => gems.map { |name| { "gem" => name, "mode" => "when_missing" } } }
    dependencies["budget_per_gem"] = budget if budget
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => workers, "dependencies" => dependencies)
    )
  end

  def diagnostics(cache_store: nil, workers: 0, **)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(workers: workers, **),
                                         cache_store: cache_store)
    guarded_run(runner, %w[lib]).diagnostics
  end

  def undefined_rows_of(found)
    found.select { |d| d.qualified_rule == "call.undefined-method" }
         .map { |d| [File.basename(d.path.to_s), d.line, d.method_name.to_s] }.sort
  end

  # `[file basename, line, method name]` for every `call.undefined-method`, sorted.
  def undefined_rows(cache_store: nil, workers: 0, **)
    undefined_rows_of(diagnostics(cache_store: cache_store, workers: workers, **))
  end

  # ADR-121 WD7, issue #1814 — `Shouty` is a gem module the walker read in full (every file under its `lib/`, no
  # mixin, no unreadable file, nothing truncated), so it is known on the same terms as a project module: the `using`
  # does not decline `"hi".nope`, which reported before #1811 made every gem module opaque.
  it "resolves a gem refinement after `using`, and reports it before" do
    write("lib/app.rb", <<~RUBY)
      "early".shout
      using Shouty
      "hi".shout
      "hi".nope
    RUBY

    expect(undefined_rows).to eq([["app.rb", 1, "shout"], ["app.rb", 4, "nope"]])
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

  # `app.rb` reports `nope` once `Shouty` is known (#1814); `unknown.rb` keeps the gem table observable where the
  # `using` names no module, which declines the gem-refined name and reports any other.
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

    expect(cold).to eq([["app.rb", 3, "nope"], ["unknown.rb", 3, "nope"]])
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

    expect(undefined_rows(workers: 2))
      .to eq([["app.rb", 3, "nope"], ["other.rb", 1, "shout"], ["unknown.rb", 3, "nope"]])
  end

  # ADR-121 WD7, issue #1814 — which gem modules are known. A module is known when every file that could refine it was
  # read; each example below pairs a gem that stays opaque with `shouty`, the control that must report in the same run.
  describe "a gem module the walker did not read in full" do
    let(:reads) { [["app.rb", 3, "nope"]] }
    let(:refining) { "module %<name>s\n  refine(String) { def shout = upcase }\nend\n" }

    # `lib/app.rb` uses `Shouty` (the control) and `lib/other.rb` the module under test, with the same `nope` call.
    def rows_for(gem_name, module_name, **)
      write("lib/app.rb", "using Shouty\n\"hi\".shout\n\"hi\".nope\n")
      write("lib/other.rb", "using #{module_name}\n\"hi\".shout\n\"hi\".nope\n")
      undefined_rows(gems: ["shouty", gem_name], **)
    end

    # The catalogue budget stops the walk (Outcome#truncated), so a file past it could have reopened the module.
    it "stays opaque when the budget truncated its walk" do
      filler = (1..1300).map { |index| "  def m#{index}; end\n" }.join
      write_gem("bigshout", "lib/big.rb" => format(refining, name: "BigShout"),
                            "lib/zz_filler.rb" => "class Filler\n#{filler}end\n")

      expect(rows_for("bigshout", "BigShout", budget: 1250)).to eq(reads)
      expect(rows_for("bigshout", "BigShout")).to eq(reads + [["other.rb", 3, "nope"]])
    end

    # A file that does not parse may have declared or refined anything: Walker drops it, and says so in `unread`.
    it "stays opaque when one of its files does not parse" do
      write_gem("brokenshout", "lib/broken_shout.rb" => format(refining, name: "BrokenShout"))

      expect(rows_for("brokenshout", "BrokenShout")).to eq(reads + [["other.rb", 3, "nope"]])

      write("vendor/brokenshout/lib/unterminated.rb", "def broken\n")
      expect(rows_for("brokenshout", "BrokenShout")).to eq(reads)
    end

    # Ruby 4.0.5 prints `:inc` for `"x".foo` after `using M` with `module M; include Inc; end`: `using` activates the
    # refinements of every module the used module includes, and the gem table has no mixin edges.
    it "stays opaque when the gem mixes a module into a module, and does not report the included module's names" do
      write_gem("mixshout", "lib/mix_shout.rb" => <<~RUBY)
        module Inc
          refine(String) { def foo = :inc }
        end
        module MixShout
          include Inc
        end
      RUBY
      write("lib/app.rb", "using Shouty\n\"hi\".shout\n\"hi\".nope\n")
      write("lib/other.rb", "using MixShout\n\"hi\".foo\n\"hi\".nope\n")

      expect(undefined_rows(gems: %w[shouty mixshout])).to eq(reads)
    end

    # A class's own `include` mixes into a class, which `using` rejects, so it does not make the gem opaque.
    it "stays known when only a class includes a module" do
      write_gem("classmix", "lib/class_mix.rb" => <<~RUBY)
        module ClassMix
          refine(String) { def shout = upcase }
        end
        class Presenter
          include Comparable
        end
      RUBY

      expect(rows_for("classmix", "ClassMix")).to eq(reads + [["other.rb", 3, "nope"]])
    end

    # A targets-wildcard row (a `refine` in a method of the module) makes it opaque however fully it was read; the
    # wildcard check runs before the gem source does.
    it "stays opaque when a refine in a method leaves a targets-wildcard row" do
      write_gem("wildshout", "lib/wild_shout.rb" => <<~RUBY)
        module WildShout
          refine(String) { def shout = upcase }
          def self.setup = refine(Integer) { def succ2 = 1 }
        end
      RUBY

      expect(rows_for("wildshout", "WildShout")).to eq(reads)
    end

    # Two gems reopening one module: the module is fully read only when both were.
    it "stays opaque when another gem reopens the module and was not read in full" do
      write_gem("sharedshout", "lib/shared_shout.rb" => format(refining, name: "SharedShout"))
      write_gem("sharedext", "lib/shared_ext.rb" => "module SharedShout\n  def ext = 1\nend\n",
                             "lib/broken.rb" => "def broken\n")
      write("lib/app.rb", "using Shouty\n\"hi\".shout\n\"hi\".nope\n")
      write("lib/other.rb", "using SharedShout\n\"hi\".shout\n\"hi\".nope\n")

      expect(undefined_rows(gems: %w[shouty sharedshout sharedext])).to eq(reads)
      expect(undefined_rows(gems: %w[shouty sharedshout])).to eq(reads + [["other.rb", 3, "nope"]])
    end

    # A gem that refines a module through an eval on its constant (`Base.module_eval { refine … }`) names the module
    # without declaring it, so the module is judged on that gem too.
    it "stays opaque when another gem refines it through an eval on its constant and was not read in full" do
      write_gem("evalbase", "lib/eval_base.rb" => "module EvalBase\n  def base = 1\nend\n")
      write_gem("evalext", "lib/eval_ext.rb" => "EvalBase.module_eval { refine(String) { def shout = upcase } }\n",
                           "lib/broken.rb" => "def broken\n")
      write("lib/app.rb", "using Shouty\n\"hi\".shout\n\"hi\".nope\n")
      write("lib/other.rb", "using EvalBase\n\"hi\".shout\n\"hi\".nope\n")

      expect(undefined_rows(gems: %w[shouty evalbase evalext])).to eq(reads)
      expect(undefined_rows(gems: %w[shouty evalbase]))
        .to eq(reads + [["other.rb", 2, "shout"], ["other.rb", 3, "nope"]])
    end
  end

  # ADR-121 WD7 — `import_methods` leaves the refined class's names unknown and its targets known, so the decline is
  # for String receivers, not for the whole span.
  it "declines the names of a refined class only, when a gem refine body imports methods" do
    write_gem("importshout", "lib/import_shout.rb" => <<~RUBY)
      module Helpers
        def whisper = "psst"
      end
      module ImportShout
        refine String do
          import_methods Helpers
        end
      end
    RUBY
    write("lib/app.rb", "using ImportShout\n\"hi\".whisper\n\"hi\".nope\n1.nope\n")

    expect(undefined_rows(gems: %w[importshout])).to eq([["app.rb", 4, "nope"]])
  end

  # ADR-121 WD3 — a gem's refine body is not inferred, so a call it replaces answers `Dynamic[top]`, never the
  # signature it replaces; every other call under the `using` keeps its type.
  it "types a call a gem refinement replaces as Dynamic[top], and every other call as before" do
    write_gem("centershout", "lib/center_shout.rb" => <<~RUBY)
      module CenterShout
        refine(String) { def center(width) = :refined }
      end
    RUBY
    write("lib/app.rb", <<~RUBY)
      Rigor.dump_type("hi".center(5))
      using CenterShout
      Rigor.dump_type("hi".center(5))
      Rigor.dump_type("hi".upcase)
      Rigor.dump_type(1.succ)
    RUBY

    dumped = diagnostics(gems: %w[centershout]).select { |d| d.qualified_rule == "dump.type" }
    expect(dumped.map(&:message)).to eq(['dump_type: " hi  "', "dump_type: Dynamic[top]", 'dump_type: "HI"',
                                         "dump_type: 2"])
  end

  # ADR-10 slice 3, issue #1814 — the gem half of the refinement table is no analysed file's, so no per-file diff
  # (`Incremental.changed_refinement_names`) sees a gem bump change it, and `app.rb` below never changes. The run's
  # cache identity must: the lockfile digest covers a `bundle update`, and the `(name, version, mode)` rows of the
  # walked gems cover a project with no lockfile.
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
      write("lib/app.rb", "using Shouty\n\"hi\".shout\n\"hi\".yell\n")
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

    # The control: nothing changed, so the run is served from the snapshot and the identity did not move.
    it "keeps serving an unchanged gem from the snapshot" do
      expect(incremental_rows).to eq([[["app.rb", 3, "yell"]], false])
      expect(incremental_rows).to eq([[["app.rb", 3, "yell"]], true])
    end
  end
end
