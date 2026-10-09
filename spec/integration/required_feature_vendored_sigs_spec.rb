# frozen_string_literal: true

# Issue #1700 — the vendored `prime` signatures load only when the project's source requires `prime`.
#
# `prime` left the default gems for the bundled gems and rbs 4.x no longer ships `stdlib/prime`, so after
# `require "prime"` a call into it on a receiver Rigor knows (`12.prime_division`) reported
# `call.undefined-method`. The gem's own `sig/` is vendored under `data/vendored_gem_sigs/prime/`, but it declares
# a top-level `class Prime` and reopens `Integer`, so it is gated on a literal `require "prime"` in the run's
# source: a project with its own `Prime` and no such require must not have the gem's signatures read against it.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/buffer_binding"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"
require "rbs"

RSpec.describe "vendored signatures gated on a required feature (#1700)" do
  def config(**overrides)
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0).merge(overrides.transform_keys(&:to_s))
    )
  end

  def run(cache_store: nil, paths: %w[lib], configuration: config)
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: cache_store), paths)
  end

  def build_failures(result)
    result.diagnostics.select { |d| d.qualified_rule == "rbs.coverage.definition-build-failed" }.map(&:message)
  end

  def vendored_prime_dir
    File.expand_path("../../data/vendored_gem_sigs/prime", __dir__)
  end

  def call_rows(result)
    calls = result.diagnostics.select { |d| d.qualified_rule.start_with?("call.") }
    calls.map { |d| "#{d.qualified_rule} #{d.message}" }
  end

  def write(path, source)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  around do |example|
    Dir.mktmpdir("rigor-required-feature-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "types prime's API after require \"prime\" and still reports a misspelt method" do
    write("lib/factor.rb", <<~RUBY)
      require "prime"

      p 12.prime_division
      p 7.prime?
      p Prime.each(10).to_a
      p Prime.prime?(7)
      p Integer.from_prime_division([[2, 2], [3, 1]])
      p 12.prime_divisionn
    RUBY

    expect(call_rows(run)).to contain_exactly(a_string_matching(/undefined method `prime_divisionn' for 12/))
  end

  it "loads them for a file that relies on another file's require" do
    write("lib/setup.rb", "require 'prime'\n")
    write("lib/use.rb", "p 12.prime_division\n")

    expect(call_rows(run)).to be_empty
  end

  it "does not read them against a project's own Prime when nothing requires prime" do
    write("lib/prime.rb", <<~RUBY)
      class Prime
        def initialize(n)
          @n = n
        end

        def prime?
          @n > 1
        end
      end

      p Prime.new(3).prime?
    RUBY

    expect(call_rows(run)).to be_empty
  end

  # Issue #1700 review — the gate is decided over the configured paths, not over the files a run is given, so a
  # pre-commit hook or a changed-files run over `lib/use.rb` alone sees the require in `lib/setup.rb`.
  it "sees a require outside the files the run checks" do
    write("lib/setup.rb", "require 'prime'\n")
    write("lib/use.rb", "p 12.prime_division\n")

    expect(call_rows(run(paths: %w[lib/use.rb]))).to be_empty
  end

  it "reads an editor buffer in place of the file it stands for" do
    write("lib/use.rb", "p 12.prime_division\n")
    write("buffer.rb", "require 'prime'\np 12.prime_division\n")
    buffer = Rigor::Analysis::BufferBinding.new(logical_path: "lib/use.rb", physical_path: "buffer.rb")
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: config, buffer: buffer), %w[lib/use.rb])

    expect(call_rows(result)).to be_empty
  end

  describe "standing down for another copy of the declarations" do
    it "stands down for a project signature that declares a member it declares, keeping Integer typed" do
      write("sig/ext.rbs", "class Integer\n  def prime?: () -> bool\nend\n")
      write("lib/use.rb", "require 'prime'\np 7.prime?\np 1.no_such_method_zzz\n")
      result = run(configuration: config(signature_paths: %w[sig]))

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to contain_exactly(a_string_matching(/no_such_method_zzz' for 1/))
    end

    it "stands down for a gem's own copy reached through signature_paths" do
      FileUtils.mkdir_p("vendor/prime/sig")
      FileUtils.cp(Dir.glob(File.join(vendored_prime_dir, "*.rbs")), "vendor/prime/sig")
      write("lib/use.rb", "require 'prime'\np 12.prime_division\np Prime.each(10).to_a\n")
      result = run(configuration: config(signature_paths: %w[vendor/prime/sig]))

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to be_empty
    end

    it "loads beside a project signature that reopens Integer with other members" do
      write("sig/ext.rbs", "class Integer\n  def my_ext: () -> Integer\nend\n")
      write("lib/use.rb", "require 'prime'\np 12.prime_division\np 3.my_ext\n")
      result = run(configuration: config(signature_paths: %w[sig]))

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to be_empty
    end
  end

  describe "a configured libraries: [prime]" do
    # The prime gem is not visible to RBS here (rbs 4 has no `stdlib/prime`), so nothing else supplies it.
    it "loads the vendored copy, with or without a require" do
      write("lib/use.rb", "p 12.prime_division\n")

      expect(call_rows(run(configuration: config(libraries: %w[prime])))).to be_empty
    end

    # A host whose prime gem ships its `sig/` resolves `prime` as a library; the vendored copy then stands down
    # rather than declare every member a second time.
    it "stands down when prime resolves as an RBS library", :fresh_rbs_env do
      Dir.mktmpdir("rigor-prime-repo-") do |repo_dir|
        FileUtils.mkdir_p(File.join(repo_dir, "prime", "0.1.4"))
        FileUtils.cp(Dir.glob(File.join(vendored_prime_dir, "*.rbs")), File.join(repo_dir, "prime", "0.1.4"))
        repository = RBS::Repository.new.tap { |repo| repo.add(Pathname(repo_dir)) }
        allow(RBS::EnvironmentLoader).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs, repository: repository)
        end

        env = Rigor::Environment::RbsLoader.build_env_for(
          libraries: Rigor::Environment::DEFAULT_LIBRARIES + ["prime", Rigor::Environment::RequiredFeatures.token("prime")],
          signature_paths: []
        )
        integer = RBS::DefinitionBuilder.new(env: env).build_instance(RBS::TypeName.parse("::Integer"))

        expect(integer.methods[:prime?]).not_to be_nil
      end
    end
  end

  it "leaves an rbs collection copy of a gated gem to load" do
    skipped = Rigor::Environment.send(:collection_skip_gem_names, %w[json])

    expect(skipped).to include("json", "redis")
    expect(skipped).not_to include("prime")
  end

  it "rebuilds rather than serving a cached environment when a file gains or drops the require" do
    store = Rigor::Cache::Store.new(root: File.join(Dir.pwd, ".rigor-cache"))
    write("lib/use.rb", "p 12.prime_division\n")
    expect(call_rows(run(cache_store: store))).to contain_exactly(a_string_matching(/prime_division/))

    write("lib/use.rb", "require \"prime\"\np 12.prime_division\n")
    expect(call_rows(run(cache_store: store))).to be_empty

    write("lib/use.rb", "p 12.prime_division\n")
    expect(call_rows(run(cache_store: store))).to contain_exactly(a_string_matching(/prime_division/))
  end

  it "moves the incremental snapshot fingerprint only for a project that requires a gated feature" do
    write("lib/use.rb", "p 12\n")
    before = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: %w[lib])

    write("lib/other.rb", "p 13\n")
    expect(Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: %w[lib])).to eq(before)

    write("lib/use.rb", "require 'prime'\np 12\n")
    expect(Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: %w[lib])).not_to eq(before)
  end
end
