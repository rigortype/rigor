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

  # What `rbs collection install` ships for activesupport 7.0, cut to the reporter's eight rows.
  def collection_rbs = <<~RBS
    class Object
      def acts_like?: (untyped duck) -> bool
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
      def to_fs: (?Symbol format) -> String
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
  end

  def config
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[a.rb b.rb], "plugins" => ["rigor-activesupport-core-ext"])
    )
  end

  def run(workers:, cache_store: nil)
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: config, cache_store: cache_store, workers: workers), %w[a.rb b.rb]
    )
    result.diagnostics.map { |d| [d.path, d.line, d.rule, d.message] }.sort
  end

  def store
    Rigor::Cache::Store.new(root: File.join(Dir.pwd, ".rigor", "cache"))
  end

  it "reports the typo, no false nil receiver, and one notice per stood-down member" do
    rows = run(workers: 0)
    rules = rows.map { |row| row[2] }
    expect(rules).to include("call.undefined-method")
    expect(rules).not_to include("call.possible-nil-receiver", "rbs.coverage.definition-build-failed")
    notices = rows.select { |row| row[2] == "rbs.coverage.plugin-signature-stood-down" }
    expect(notices.size).to eq(8)
    expect(notices.map { |row| row[3] }).to all(include(".gem_rbs_collection/activesupport/7.0/activesupport.rbs"))
    expect(notices.map { |row| row[3][/declares `([^`]+)`/, 1] }).to contain_exactly(
      "Object#acts_like?", "Array#compact_blank!", "Hash#compact_blank", "Integer#ordinalize",
      "NilClass#to_param", "TrueClass#to_param", "FalseClass#to_param", "Time#to_fs"
    )
  end

  it "says the same under the fork pool and on a cold and a warm env cache" do
    sequential = run(workers: 0)
    expect(run(workers: 2)).to eq(sequential)
    expect(run(workers: 0, cache_store: store)).to eq(sequential)
    expect(run(workers: 0, cache_store: store)).to eq(sequential)
    expect(run(workers: 2, cache_store: store)).to eq(sequential)
  end
end
