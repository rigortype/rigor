# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# Issue #2517 — `core_root:` loads a core signature directory IN PLACE OF the `rbs` gem's `core/`, the interface a
# provider such as rbs-shifter writes an older CRuby's core for. The fixture core is the gem's own with two of
# rbs-shifter's initial Ruby 3.3 rules applied: `Array#rfind` removed and `String#strip` taking no argument.
require "spec_helper"
require "rigor/cli"
require "rigor/cache/rbs_descriptor"
require "rigor/cache/incremental_snapshot"

RSpec.describe "core_root: (#2517)" do
  def shifted_core(dir)
    root = File.join(dir, "core33")
    FileUtils.cp_r(RBS::EnvironmentLoader::DEFAULT_CORE_ROOT.to_s, root)
    array = File.join(root, "array.rbs")
    File.write(array, File.read(array).sub(/^  def rfind: .*?(?=^\n)/m, ""))
    string = File.join(root, "string.rbs")
    File.write(string, File.read(string).sub("  def strip: (*selector) -> String", "  def strip: () -> String"))
    root
  end

  def buffer_names(loader)
    env = loader.send(:env)
    env.each_rbs_source.map { |source| source.buffer.name.to_s }
  end

  describe Rigor::Environment::CoreRoot, ".validate!" do
    it "returns the absolute directory, frozen" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "object.rbs"), "class Object\nend\n")
        resolved = described_class.validate!(dir)

        expect(resolved).to eq(File.expand_path(dir))
        expect(resolved).to be_frozen
      end
    end

    it "rejects a missing path, a file, and a directory without signatures" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "core.rbs")
        File.write(file, "")
        empty = File.join(dir, "empty")
        FileUtils.mkdir_p(empty)

        expect { described_class.validate!(File.join(dir, "nope")) }
          .to raise_error(Rigor::Environment::CoreRootError, /does not exist/)
        expect { described_class.validate!(file) }.to raise_error(Rigor::Environment::CoreRootError, /not a directory/)
        expect { described_class.validate!(empty) }.to raise_error(Rigor::Environment::CoreRootError, /no \.rbs/)
      end
    end

    it "is a configuration error, so the CLI reports it as one" do
      expect(Rigor::Environment::CoreRootError.ancestors).to include(Rigor::ConfigurationError)
    end
  end

  describe "an environment built from a selected core" do
    # One environment build for the group: the fixture core is the whole of the gem's.
    # rubocop:disable RSpec/BeforeAfterAll, RSpec/InstanceVariable
    before(:all) do
      @dir = Dir.mktmpdir("rigor-core-root-spec-")
      @core = shifted_core(@dir)
      @loader = Rigor::Environment::RbsLoader.new(libraries: Rigor::Environment::DEFAULT_LIBRARIES, core_root: @core)
    end

    after(:all) do
      FileUtils.remove_entry(@dir)
    end
    # rubocop:enable RSpec/BeforeAfterAll, RSpec/InstanceVariable

    let(:loader) { @loader } # rubocop:disable RSpec/InstanceVariable
    let(:core) { @core } # rubocop:disable RSpec/InstanceVariable

    it "loads core from the selected directory and not from the rbs gem's" do
      names = buffer_names(loader)
      default_core = "#{RBS::EnvironmentLoader::DEFAULT_CORE_ROOT}/"

      expect(names).to include(File.join(core, "array.rbs"))
      expect(names.grep(/\A#{Regexp.escape(default_core)}/)).to be_empty
    end

    it "drops what the selected core removed, and keeps what it keeps" do
      methods = loader.instance_definition("Array").methods

      expect(methods).not_to have_key(:rfind)
      expect(methods).to have_key(:find)
    end

    it "takes the selected core's signature for a method it changed" do
      strip = loader.instance_definition("String").methods.fetch(:strip)

      expect(strip.method_types.map(&:to_s)).to eq(["() -> ::String"])
    end

    it "attributes core and stdlib classes as the default core does" do
      default = Rigor::Environment::RbsLoader.new(libraries: Rigor::Environment::DEFAULT_LIBRARIES)
      names = %w[Array String Integer Hash Kernel Comparable Logger Set Pathname]

      expect(names.map { |name| loader.core_class?(name) }).to eq(names.map { |name| default.core_class?(name) })
      expect(names.map { |name| loader.core_or_stdlib_class?(name) })
        .to eq(names.map { |name| default.core_or_stdlib_class?(name) })
      expect(loader.core_class?("String")).to be(true)
    end

    it "leaves the default core's environment as it was" do
      default = Rigor::Environment::RbsLoader.new(libraries: [])

      expect(default.core_root).to be_nil
      expect(default.instance_definition("Array").methods).to have_key(:rfind)
    end
  end

  describe "a selected core that does not build" do
    it "raises instead of degrading to an empty environment" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "broken.rbs"), "class Broken\n  def x: ( -> Integer\nend\n")
        loader = Rigor::Environment::RbsLoader.new(libraries: [], core_root: dir)

        expect { loader.verify_core_root! }
          .to raise_error(Rigor::Environment::CoreRootError, /did not build an RBS environment.*ParsingError/)
        expect { loader.instance_definition("Broken") }.to raise_error(Rigor::Environment::CoreRootError)
      end
    end
  end

  describe "cache identity" do
    def descriptor_rows(loader)
      Rigor::Cache::RbsDescriptor.file_entries(loader).map { |entry| [entry.path.to_s, entry.value] }
    end

    it "keys the environment on the selected root and on its files' contents" do
      Dir.mktmpdir do |dir|
        core = File.join(dir, "core")
        FileUtils.mkdir_p(core)
        File.write(File.join(core, "object.rbs"), "class Object\nend\n")
        loader = Rigor::Environment::RbsLoader.new(libraries: [], core_root: core)
        default = Rigor::Environment::RbsLoader.new(libraries: [])

        configs = Rigor::Cache::RbsDescriptor.env_only_config_entries(loader).map(&:key)
        expect(configs).to include("rbs.core_root")
        expect(Rigor::Cache::RbsDescriptor.env_only_config_entries(default).map(&:key)).not_to include("rbs.core_root")

        before = descriptor_rows(loader)
        expect(before.map(&:first)).to include(File.join(File.realpath(core), "object.rbs")).or(
          include(File.join(core, "object.rbs"))
        )

        File.write(File.join(core, "object.rbs"), "class Object\n  def x: () -> Integer\nend\n")
        expect(descriptor_rows(loader)).not_to eq(before)
      end
    end

    it "moves the incremental fingerprint when a selected core file changes" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p(%w[lib core])
          File.write("lib/a.rb", "class Foo\nend\n")
          File.write("core/object.rbs", "class Object\nend\n")
          configuration = Rigor::Configuration.new("paths" => %w[lib], "core_root" => File.join(dir, "core"))
          fingerprint = -> { Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: %w[lib]) }

          before = fingerprint.call
          File.write("core/object.rbs", "class Object\n  def x: () -> Integer\nend\n")

          expect(fingerprint.call).not_to eq(before)
        end
      end
    end
  end

  describe "rigor check" do
    def check(config)
      out = StringIO.new
      err = StringIO.new
      status = Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--config", config, "lib"], out: out, err: err).run
      [status, out.string, err.string]
    end

    around do |example|
      Dir.mktmpdir("rigor-core-root-check-") { |dir| Dir.chdir(dir) { example.run } }
    end

    before do
      FileUtils.mkdir_p("lib")
      File.write("lib/demo.rb", <<~RUBY)
        class Demo
          def ok_find = [1, 2].find { |n| n.even? }
          def ok_strip = " text ".strip
          def bad_rfind = [1, 2].rfind { |n| n.even? }
          def bad_strip = " text ".strip(" ")
        end
      RUBY
    end

    it "reports the APIs the selected core does not have, and only those" do
      shifted_core(Dir.pwd)
      File.write(".rigor.yml", "paths: [lib]\ntarget_ruby: \"3.3\"\ncore_root: core33\n")

      status, out, = check(".rigor.yml")

      expect(status).to eq(1)
      expect(out).to include("lib/demo.rb:4:", "undefined method `rfind'", "[call.undefined-method]")
      expect(out).to include("lib/demo.rb:5:", "[call.wrong-arity]")
      expect(out).not_to include("lib/demo.rb:2:", "lib/demo.rb:3:")
    end

    it "fails with one configuration error for a core that does not exist" do
      File.write(".rigor.yml", "paths: [lib]\ncore_root: missing\n")

      status, out, err = check(".rigor.yml")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to match(/\Arigor: core_root: ".*missing" does not exist$/)
      expect(out).to be_empty
    end
  end
end
