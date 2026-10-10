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

rbs_inline_lib = File.expand_path("../../plugins/rigor-rbs-inline/lib", __dir__)
$LOAD_PATH.unshift(rbs_inline_lib) unless $LOAD_PATH.include?(rbs_inline_lib)
require "rigor-rbs-inline"

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

  after { Rigor::Plugin.unregister! }

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

  it "drops the require an editor buffer bound to a relative path removes" do
    write("lib/use.rb", "require 'prime'\np 12.prime_division\n")
    write("buffer.rb", "p 12.prime_division\n")
    buffer = Rigor::Analysis::BufferBinding.new(logical_path: "lib/use.rb", physical_path: "buffer.rb")
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: config, buffer: buffer), %w[lib/use.rb])

    expect(call_rows(result)).to contain_exactly(a_string_matching(/prime_division' for 12/))
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

    it "loads beside a project overload continuation of one of its members" do
      write("sig/ext.rbs", "class Integer\n  def prime?: (String) -> bool | ...\nend\n")
      write("lib/use.rb", "require 'prime'\np 7.prime?\np 7.prime?(\"x\")\np 12.prime_division\np 1.nope\n")
      result = run(configuration: config(signature_paths: %w[sig]))

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to contain_exactly(a_string_matching(/nope' for 1/))
    end

    it "loads beside a project subclass declaration that names the same superclass absolutely" do
      write("sig/ext.rbs", <<~RBS)
        class Prime
          class EratosthenesGenerator < ::Prime::PseudoPrimeGenerator
            def extra: () -> void
          end
        end
      RBS
      write("lib/use.rb", "require 'prime'\np 12.prime_division\np 7.prime?\nPrime.each(10) { |x| p x }\n")
      result = run(configuration: config(signature_paths: %w[sig]))

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to be_empty
    end

    it "stands down for a project Prime at another generic arity, keeping the project's" do
      write("sig/prime.rbs", "class Prime[T]\n  def initialize: () -> void\n  def extra: () -> T\nend\n")
      write("lib/use.rb", "require 'prime'\np Prime.new.extra\nPrime.new.nope\n")
      result = run(configuration: config(signature_paths: %w[sig]))

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to contain_exactly(a_string_matching(/nope' for Prime/))
    end

    it "stands down for a project module Prime, keeping the project's file" do
      write("sig/prime.rbs", "module Prime\n  def self.sieve: (Integer) -> Array[Integer]\nend\n")
      write("lib/use.rb", "require 'prime'\nPrime.sieve(10).zzz\n")
      result = run(configuration: config(signature_paths: %w[sig]))

      expect(result.diagnostics.map(&:qualified_rule)).not_to include("rbs.coverage.quarantined-signature")
      expect(call_rows(result)).to contain_exactly(a_string_matching(/zzz' for Array\[Integer\]/))
    end

    it "builds once when the only quarantined project file declares none of its types", :fresh_rbs_env do
      write("sig/base64.rbs", "class Base64\nend\n")
      allow(Rigor::Environment::RbsLoader).to receive(:build_env_attempt).and_call_original
      Rigor::Environment::RbsLoader.build_env_for(
        libraries: Rigor::Environment::DEFAULT_LIBRARIES + [Rigor::Environment::RequiredFeatures.token("prime")],
        signature_paths: [Pathname("sig")]
      )

      expect(Rigor::Environment::RbsLoader).to have_received(:build_env_attempt).once
    end

    it "loads beside a project signature that reopens Integer with other members" do
      write("sig/ext.rbs", "class Integer\n  def my_ext: () -> Integer\nend\n")
      write("lib/use.rb", "require 'prime'\np 12.prime_division\np 3.my_ext\n")
      result = run(configuration: config(signature_paths: %w[sig]))

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to be_empty
    end
  end

  # Issue #1713 — a clash stands down only what clashes: a member, a type whose header disagrees, and only when
  # nothing narrower builds, the directory.
  describe "standing down only what clashes" do
    let(:standdown_rule) { "rbs.coverage.vendored-signature-stood-down" }
    let(:prime_api_use) do
      <<~RUBY
        require "prime"
        p 12.prime_division
        p Integer.from_prime_division([[2, 2], [3, 1]])
        Prime.each(10) { |x| p x }
        p Prime::EratosthenesGenerator.new.next
        p 1.nope
      RUBY
    end

    def standdown_rows(result)
      result.diagnostics.select { |d| d.qualified_rule == standdown_rule }
    end

    def sig_config
      config(signature_paths: %w[sig])
    end

    def incremental_run(configuration, plugin_requirer: nil)
      root = File.join(Dir.pwd, ".rigor", "cache")
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: %w[lib])
      session = Rigor::Analysis::IncrementalSession.new(
        configuration: configuration, paths: %w[lib], cache_store: Rigor::Cache::Store.new(root: root),
        plugin_requirer: plugin_requirer
      )
      guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
    end

    it "keeps the rest of the API beside a one-member shim, which declares that member" do
      write("sig/ext.rbs", "class Integer\n  def prime?: () -> Integer\nend\n")
      write("lib/use.rb", "#{prime_api_use}7.prime?.zzz\n")
      result = run(configuration: sig_config)

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to contain_exactly(
        a_string_matching(/nope' for 1/), a_string_matching(/zzz' for Integer/)
      )
      rows = standdown_rows(result)
      expect(rows.size).to eq(1)
      expect(rows.first.severity).to eq(:info)
      expect(rows.first.path).to eq(".rigor.yml")
      expect(rows.first.message).to include("left out 1 method declaration(s)", "`Integer#prime?` (sig/ext.rbs)")
    end

    it "reports the stand-down cold, warm and under --incremental, and drops it with the clash" do
      write("sig/ext.rbs", "class Integer\n  def prime?: () -> bool\nend\n")
      write("lib/use.rb", prime_api_use)
      store = Rigor::Cache::Store.new(root: File.join(Dir.pwd, ".rigor", "cache"))

      expect(standdown_rows(run(cache_store: store, configuration: sig_config)).size).to eq(1)
      expect(standdown_rows(run(cache_store: store, configuration: sig_config)).size).to eq(1)
      expect(standdown_rows(run(cache_store: Rigor::Cache::Store.new(root: store.root),
                                configuration: sig_config)).size).to eq(1)
      found, = incremental_run(sig_config)
      expect(standdown_rows(Struct.new(:diagnostics).new(found)).size).to eq(1)
      found, warm = incremental_run(sig_config)
      expect(warm).to be(true)
      expect(standdown_rows(Struct.new(:diagnostics).new(found)).size).to eq(1)

      write("sig/ext.rbs", "class Integer\n  def my_ext: () -> bool\nend\n")
      expect(standdown_rows(run(cache_store: store, configuration: sig_config))).to be_empty
      found, = incremental_run(sig_config)
      expect(standdown_rows(Struct.new(:diagnostics).new(found))).to be_empty
      expect(call_rows(Struct.new(:diagnostics).new(found))).to contain_exactly(a_string_matching(/nope' for 1/))
    end

    # Inline RBS is a source the signature-state snapshot's `signature_paths:` gate does not see, so only the
    # required-feature gate lets a nothing-changed recheck, which resolves an environment only when a gate asks,
    # report the stand-down.
    it "reports a clash with inline RBS on a nothing-changed --incremental recheck, with no signature_paths" do
      write("lib/ext.rb", "class Integer\n  #: () -> bool\n  def prime? = true\nend\n")
      write("lib/use.rb", prime_api_use)
      configuration = config(signature_paths: [], plugins: ["rigor-rbs-inline"])
      requirer = lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::RbsInline)
        true
      end
      Rigor::Plugin.unregister!

      found, = incremental_run(configuration, plugin_requirer: requirer)
      expect(standdown_rows(Struct.new(:diagnostics).new(found)).map(&:message))
        .to contain_exactly(a_string_including("`Integer#prime?` (virtual:rbs-inline:lib/ext.rb)"))
      Rigor::Plugin.unregister!
      found, warm = incremental_run(configuration, plugin_requirer: requirer)
      expect(warm).to be(true)
      expect(standdown_rows(Struct.new(:diagnostics).new(found)).size).to eq(1)
    end

    it "stands only the type down for a project Prime at another generic arity" do
      write("sig/prime.rbs", "class Prime[T]\n  def initialize: () -> void\n  def extra: () -> T\nend\n")
      write("lib/use.rb", "require 'prime'\np 12.prime_division\np 7.prime?\nPrime.new.nope\n" \
                          "p Prime::EratosthenesGenerator.new.next\n")
      result = run(configuration: sig_config)

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to contain_exactly(a_string_matching(/nope' for Prime/))
      expect(standdown_rows(result).map(&:message)).to contain_exactly(a_string_including("`Prime` (sig/prime.rbs)"))
    end

    it "plans a generic-arity clash without a trial that fails first", :fresh_rbs_env do
      write("sig/prime.rbs", "class Prime[T]\n  def each: () -> T\nend\n")
      allow(Rigor::Environment::RbsLoader).to receive(:build_env_attempt).and_call_original
      Rigor::Environment::RbsLoader.build_env_for(
        libraries: Rigor::Environment::DEFAULT_LIBRARIES + [Rigor::Environment::RequiredFeatures.token("prime")],
        signature_paths: [Pathname("sig")]
      )

      expect(Rigor::Environment::RbsLoader).to have_received(:build_env_attempt).exactly(3).times
    end

    it "keeps a project module Prime and the rest of the API" do
      write("sig/prime.rbs", "module Prime\n  def self.sieve: (Integer) -> Array[Integer]\nend\n")
      write("lib/use.rb", "require 'prime'\nPrime.sieve(10).zzz\np 12.prime_division\np 7.prime?\n")
      result = run(configuration: sig_config)

      expect(result.diagnostics.map(&:qualified_rule)).not_to include("rbs.coverage.quarantined-signature")
      expect(call_rows(result)).to contain_exactly(a_string_matching(/zzz' for Array\[Integer\]/))
      expect(standdown_rows(result).map(&:message)).to contain_exactly(a_string_including("`Prime` (sig/prime.rbs)"))
    end

    it "stands a nested type down when only the trial build finds its superclass disagrees" do
      write("sig/prime.rbs", <<~RBS)
        class Prime
          class Generator23 < Numeric
            def extra: () -> Integer
          end
        end
      RBS
      write("lib/use.rb", "require 'prime'\np 12.prime_division\nPrime.each(10) { |x| p x }\n" \
                          "Prime::Generator23.new.extra.zzz\n")
      result = run(configuration: sig_config)

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to contain_exactly(a_string_matching(/zzz' for Integer/))
      expect(standdown_rows(result).map(&:message))
        .to contain_exactly(a_string_including("`Prime::Generator23` (sig/prime.rbs)"))
    end

    it "does not read a stub Rigor synthesized for a shim's reference as a clashing Prime" do
      # Without the vendored copy the reference resolves to nothing, so the environment planned against stubs
      # `Prime` as a module and `Prime::PseudoPrimeGenerator` inside it.
      write("sig/ext.rbs", "class Integer\n  def prime?: () -> bool\nend\n" \
                           "class Shim\n  def gen: () -> Prime::PseudoPrimeGenerator\nend\n")
      write("lib/use.rb", prime_api_use)
      result = run(configuration: sig_config)

      expect(call_rows(result)).to contain_exactly(a_string_matching(/nope' for 1/))
      expect(standdown_rows(result).map(&:message)).to contain_exactly(a_string_including("`Integer#prime?`"))
    end

    it "keeps a continued member beside another member's clash" do
      write("sig/ext.rbs",
            "class Integer\n  def prime?: (String) -> bool | ...\n  def prime_division: () -> Array[Integer]\nend\n")
      write("lib/use.rb", "#{prime_api_use}p 7.prime?\np 7.prime?(\"x\")\n")
      result = run(configuration: sig_config)

      expect(call_rows(result)).to contain_exactly(a_string_matching(/nope' for 1/))
      expect(standdown_rows(result).map(&:message))
        .to contain_exactly(a_string_including("left out 1 method declaration(s)",
                                               "`Integer#prime_division` (sig/ext.rbs)"))
    end

    it "keeps an accessor's reader when another source declares only its writer" do
      write("sig/ext.rbs",
            "class Prime\n  class PseudoPrimeGenerator\n    attr_writer upper_bound: Integer?\n  end\nend\n")
      write("lib/use.rb", "require 'prime'\ng = Prime::EratosthenesGenerator.new\np g.upper_bound\n" \
                          "g.upper_bound = 3\np 12.prime_division\np 1.nope\n")
      result = run(configuration: sig_config)

      expect(call_rows(result)).to contain_exactly(a_string_matching(/nope' for 1/))
      expect(standdown_rows(result).map(&:message))
        .to contain_exactly(a_string_including("`Prime::PseudoPrimeGenerator#upper_bound=` (sig/ext.rbs)."))
    end

    it "keeps an accessor's writer when another source declares only its reader" do
      write("sig/ext.rbs",
            "class Prime\n  class PseudoPrimeGenerator\n    def upper_bound: () -> Integer?\n  end\nend\n")
      write("lib/use.rb", "require 'prime'\ng = Prime::EratosthenesGenerator.new\np g.upper_bound\n" \
                          "g.upper_bound = 3\np 1.nope\n")
      result = run(configuration: sig_config)

      expect(call_rows(result)).to contain_exactly(a_string_matching(/nope' for 1/))
      expect(standdown_rows(result).map(&:message))
        .to contain_exactly(a_string_including("`Prime::PseudoPrimeGenerator#upper_bound` (sig/ext.rbs)."))
    end

    # The project makes the generators' superclass a module, so each generator fails on its superclass although
    # nothing else declares it; they stay, unchecked for what they inherited, rather than lose every method.
    it "does not report a generator's inherited method once its superclass stood down" do
      write("sig/ext.rbs", "class Prime\n  module PseudoPrimeGenerator\n    def foo: () -> Integer\n  end\nend\n")
      write("lib/use.rb", "require 'prime'\np 12.prime_division\nPrime.each(10) { |x| p x }\n" \
                          "p Prime::Generator23.new.succ\np 1.nope\n")
      result = run(configuration: sig_config)

      expect(build_failures(result)).to be_empty
      expect(call_rows(result)).to contain_exactly(a_string_matching(/nope' for 1/))
      message = standdown_rows(result).map(&:message).first
      expect(message).to include("`Prime::PseudoPrimeGenerator` (sig/ext.rbs)", "without their superclass",
                                 "`Prime::Generator23`")
      expect(message).not_to include("declarations of one method")
    end

    it "keeps everything, without a notice, beside an overload continuation" do
      write("sig/ext.rbs", "class Integer\n  def prime?: (String) -> bool | ...\nend\n")
      write("lib/use.rb", "#{prime_api_use}p 7.prime?\np 7.prime?(\"x\")\n")
      result = run(configuration: sig_config)

      expect(call_rows(result)).to contain_exactly(a_string_matching(/nope' for 1/))
      expect(standdown_rows(result)).to be_empty
    end

    it "reports nothing when nothing clashes" do
      write("sig/ext.rbs", "class Integer\n  def my_ext: () -> Integer\nend\n")
      write("lib/use.rb", prime_api_use)
      result = run(configuration: sig_config)

      expect(call_rows(result)).to contain_exactly(a_string_matching(/nope' for 1/))
      expect(standdown_rows(result)).to be_empty
    end

    # The trial build stays the arbiter: Integer fails beside the project's own duplicate whatever the vendored
    # copy does, so no plan is better than the directory, which stays whole as it did before #1713.
    it "keeps the directory whole when no plan builds better than it" do
      write("sig/ext.rbs", "class Integer\n  def prime?: () -> bool\n  def prime?: () -> bool\nend\n")
      write("lib/use.rb", prime_api_use)

      expect(standdown_rows(run(configuration: sig_config))).to be_empty
    end

    it "reports the whole directory standing down when no plan builds", :fresh_rbs_env do
      write("sig/ext.rbs", "class Integer\n  def prime?: () -> bool\nend\n")
      write("lib/use.rb", prime_api_use)
      allow(Rigor::Environment::RbsLoader).to receive(:partial_gated_env).and_return(nil)
      result = run(configuration: sig_config)

      expect(standdown_rows(result).map(&:message)).to contain_exactly(
        a_string_including("stood down entirely", "`Integer#prime?` (sig/ext.rbs)")
      )
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
        loader = Rigor::Environment::RbsLoader.new(
          libraries: Rigor::Environment::DEFAULT_LIBRARIES + ["prime", Rigor::Environment::RequiredFeatures.token("prime")]
        )

        expect(integer.methods[:prime?]).not_to be_nil
        # Issue #1713 — the vendored copy never loaded, so nothing of it stood down.
        expect(loader.vendored_standdowns).to eq([])
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
