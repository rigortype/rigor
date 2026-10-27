# frozen_string_literal: true

require "tmpdir"
require "fileutils"

require "rigor"
require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/cache/store"

unless defined?(AS_CORE_EXT_PLUGIN_LIB)
  AS_CORE_EXT_PLUGIN_LIB = File.expand_path("../../plugins/rigor-activesupport-core-ext/lib", __dir__)
end
$LOAD_PATH.unshift(AS_CORE_EXT_PLUGIN_LIB) unless $LOAD_PATH.include?(AS_CORE_EXT_PLUGIN_LIB)
require "rigor-activesupport-core-ext"

# Issue #2422 end to end: `rigor-activesupport-core-ext` enabled beside an `rbs collection install` that
# declares `Object#acts_like?` (and the reporter's seven other rows). Before the fix the plugin's file reopened
# `Object` with a second `acts_like?`, every class under `Object` failed its definition build, `y.nil?` on a
# `String | nil` drew a false `call.possible-nil-receiver`, and the typo `1.foo` went unreported.
#
# Each arm asserts the typo IS reported, since a collapsed universe reports nothing, and that every run shape
# — sequential, the fork pool, a cold and a warm env cache — says the same thing.
RSpec.describe "plugin signature member stand-down through the runner (#2422)" do
  around do |example|
    Dir.mktmpdir("rigor-plugin-member-standdown-") do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  before do
    Rigor::Plugin.unregister!
    allow_any_instance_of(Rigor::Environment::RbsLoader).to receive(:warn) # rubocop:disable RSpec/AnyInstance
    write_project
  end

  after { Rigor::Plugin.unregister! }

  # What `rbs collection install` ships for activesupport 7.0, cut to the reporter's eight rows plus the two
  # literal returns the review of #2424 found folding correct code, and a `to_fs` wider than the plugin's.
  def collection_rbs = <<~RBS
    class Object
      def acts_like?: (untyped duck) -> bool
      def html_safe?: () -> false
      def duplicable?: () -> true
    end
    class Array[unchecked out Elem]
      def compact_blank!: () -> self
    end
    class Hash[unchecked out K, unchecked out V]
      def compact_blank: () -> Hash[K, V]
    end
    class Integer
      def ordinalize: () -> String
    end
    class NilClass
      def to_param: () -> self
    end
    class TrueClass
      def to_param: () -> self
    end
    class FalseClass
      def to_param: () -> self
    end
    class Time
      def to_fs: (?Symbol | String format) -> String
    end
    class Hash[unchecked out K, unchecked out V]
      def deep_merge: (untyped other) -> untyped
      def deep_transform_keys: () { (untyped) -> untyped } -> untyped
    end
  RBS

  def lockfile_yaml = <<~YAML
    ---
    path: ".gem_rbs_collection"
    gems:
    - name: activesupport
      version: '7.0'
      source:
        type: git
        name: ruby/gem_rbs_collection
        remote: https://github.com/ruby/gem_rbs_collection.git
        revision: abc
        repo_dir: gems
  YAML

  def write_project
    gem_dir = File.join(".gem_rbs_collection", "activesupport", "7.0")
    FileUtils.mkdir_p(gem_dir)
    File.write(File.join(gem_dir, "activesupport.rbs"), collection_rbs)
    File.write("rbs_collection.lock.yaml", lockfile_yaml)
    File.write("a.rb", "def m(x)\n  y = x ? \"s\" : nil\n  y.nil?\n  1.foo\nend\n")
    File.write("b.rb", "def n(x)\n  x.present?\nend\n")
    File.write("c.rb", composed_source)
  end

  # The project's own `sig/`, declaring a plugin method the collection does not.
  def write_own_sig
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "own.rbs"),
               "class Integer\n  def ordinal: () -> Symbol\n  def multiple_of?: (Integer) -> bool\nend\n")
  end

  # Correct code the collection's narrower declarations alone would misjudge: `html_safe?` read as always
  # false, `duplicable?` as always true, and a `to_fs` argument only the collection's overload accepts.
  def composed_source = <<~RUBY
    def h(o)
      if o.html_safe?
        1
      else
        2
      end
    end

    def d(o)
      return 1 unless o.duplicable?

      2
    end

    def t = Time.now.to_fs("x").upcase

    # Only the plugin declares `squish`: a run that silently lost the plugin reports it.
    def s = "  x ".squish
  RUBY

  def config
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[a.rb b.rb c.rb], "plugins" => ["rigor-activesupport-core-ext"])
    )
  end

  # The plugin is registered by the requirer on every run: once required, `require` does not register it again
  # after the `unregister!` each run starts from.
  def run(workers:, cache_store: nil)
    Rigor::Plugin.unregister!
    requirer = lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::ActivesupportCoreExt)
      true
    end
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: config, cache_store: cache_store, workers: workers,
                                  plugin_requirer: requirer),
      %w[a.rb b.rb c.rb]
    )
    result.diagnostics.map { |d| [d.path, d.line, d.rule, d.message] }.sort
  end

  def store
    Rigor::Cache::Store.new(root: File.join(Dir.pwd, ".rigor", "cache"))
  end

  it "composes with the collection: the typo reports, nothing false does, and nothing stood down" do
    rows = run(workers: 0)
    expect(rows.reject { |row| row[0] == ".rigor.yml" }.map { |row| [File.basename(row[0]), row[1], row[2]] })
      .to eq([["a.rb", 4, "call.undefined-method"]])
    expect(rows.map { |row| row[2] }).not_to include("rbs.coverage.plugin-signature-stood-down",
                                                     "rbs.coverage.definition-build-failed")
  end

  it "stands a member down to the project's own sig/ and names it in one notice" do
    write_own_sig
    rows = run(workers: 0)
    notices = rows.select { |row| row[2] == "rbs.coverage.plugin-signature-stood-down" }
    expect(notices.size).to eq(1)
    message = notices.first[3]
    expect(message).to include("core_ext.rbs", "loaded without 2 declaration(s)", "the other source's, named in")
    expect(message.scan(%r{`([^`/]+)` \(([^)]+)\)})).to eq([["Integer#multiple_of?", "sig/own.rbs"],
                                                            ["Integer#ordinal", "sig/own.rbs"]])
    expect(rows.map do |row|
      row[2]
    end).not_to include("call.possible-nil-receiver", "rbs.coverage.definition-build-failed")
  end

  # Review of #2424, S1: composing puts the plugin's overloads first, so a plugin row that pins the receiver's
  # types in its result took precedence over the collection's `untyped`. `deep_merge` adds the argument's keys
  # and values, and `deep_transform_keys` re-keys with the block's result.
  def write_probe
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "probe.rbs"), <<~RBS)
      class Probe
        def a2: (Hash[Symbol, Integer]) -> String
        def a3: (Hash[Symbol, Integer]) -> String
      end
    RBS
    File.write("c.rb", <<~RUBY)
      class Probe
        def a2(h)
          m = h.deep_merge({ b: "x" })
          v = m[:b]
          v.upcase
        end

        def a3(h)
          k = h.deep_transform_keys(&:to_s).keys.first
          k + "x"
        end
      end
    RUBY
  end

  def probe_rows(rows) = rows.select { |row| row[0].end_with?("c.rb") }

  it "types deep_merge and deep_transform_keys results by what they return, with the collection" do
    write_probe
    expect(probe_rows(run(workers: 0))).to be_empty
  end

  it "types deep_merge and deep_transform_keys results by what they return, without the collection" do
    write_probe
    FileUtils.rm_rf([".gem_rbs_collection", "rbs_collection.lock.yaml"])
    expect(probe_rows(run(workers: 0))).to be_empty
  end

  it "says the same under the fork pool and on a cold and a warm env cache" do
    write_own_sig
    sequential = run(workers: 0)
    expect(sequential.map { |row| row[2] }).to include("rbs.coverage.plugin-signature-stood-down")
    expect(run(workers: 2)).to eq(sequential)
    expect(run(workers: 0, cache_store: store)).to eq(sequential)
    expect(run(workers: 0, cache_store: store)).to eq(sequential)
    expect(run(workers: 2, cache_store: store)).to eq(sequential)
  end
end
