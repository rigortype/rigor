# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/environment/rbs_collection_discovery"

RSpec.describe Rigor::Environment::RbsCollectionDiscovery do
  let(:tmpdir) { Dir.mktmpdir("rigor-rbs-collection-discovery-spec-") }

  after { FileUtils.rm_rf(tmpdir) }

  # Builds a `.gem_rbs_collection/<gem>/<version>/<gem>.rbs`
  # layout matching what `rbs collection install` produces.
  def make_collection(root, *entries)
    entries.each do |name, version|
      gem_dir = File.join(root, name, version)
      FileUtils.mkdir_p(gem_dir)
      File.write(File.join(gem_dir, "#{name}.rbs"), "module #{name.capitalize}_Stub\nend\n")
    end
  end

  def write_lockfile(body, name: "rbs_collection.lock.yaml")
    path = File.join(tmpdir, name)
    File.write(path, body)
    path
  end

  describe ".discover with explicit lockfile_path" do
    it "returns per-gem RBS directories listed in the lockfile" do # rubocop:disable RSpec/ExampleLength
      make_collection(File.join(tmpdir, ".gem_rbs_collection"), ["activerecord", "7.1"], ["rack", "3.0"])
      body = <<~YAML
        ---
        path: ".gem_rbs_collection"
        gems:
        - name: activerecord
          version: '7.1'
          source:
            type: git
            name: ruby/gem_rbs_collection
            remote: https://github.com/ruby/gem_rbs_collection.git
            revision: abc
            repo_dir: gems
        - name: rack
          version: '3.0'
          source:
            type: git
            name: ruby/gem_rbs_collection
            remote: https://github.com/ruby/gem_rbs_collection.git
            revision: abc
            repo_dir: gems
        gemfile_lock_path: Gemfile.lock
      YAML
      path = write_lockfile(body)

      result = described_class.discover(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      gem_dirs = result.map { |p| [p.parent.basename.to_s, p.basename.to_s] }.sort
      expect(gem_dirs).to eq([["activerecord", "7.1"], ["rack", "3.0"]])
    end

    it "skips entries with source type stdlib (already covered by DEFAULT_LIBRARIES)" do
      make_collection(File.join(tmpdir, ".gem_rbs_collection"), %w[logger 0], ["activerecord", "7.1"])
      body = <<~YAML
        ---
        path: ".gem_rbs_collection"
        gems:
        - name: logger
          version: '0'
          source:
            type: stdlib
        - name: activerecord
          version: '7.1'
          source:
            type: git
        gemfile_lock_path: Gemfile.lock
      YAML
      path = write_lockfile(body)

      result = described_class.discover(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      gem_names = result.map { |p| p.parent.basename.to_s }
      expect(gem_names).to eq(["activerecord"])
    end

    it "drops entries whose <collection>/<name>/<version>/ directory is missing" do
      # Lockfile names two gems but only one is actually installed.
      make_collection(File.join(tmpdir, ".gem_rbs_collection"), ["rack", "3.0"])
      body = <<~YAML
        ---
        path: ".gem_rbs_collection"
        gems:
        - name: rack
          version: '3.0'
          source:
            type: git
        - name: not_installed
          version: '1.0'
          source:
            type: git
        gemfile_lock_path: Gemfile.lock
      YAML
      path = write_lockfile(body)

      result = described_class.discover(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      gem_names = result.map { |p| p.parent.basename.to_s }
      expect(gem_names).to eq(["rack"])
    end

    it "honors rubygems and local source types (only stdlib is excluded)" do
      make_collection(
        File.join(tmpdir, ".gem_rbs_collection"),
        ["pg", "1.5"],
        ["local_thing", "2.0"]
      )
      body = <<~YAML
        ---
        path: ".gem_rbs_collection"
        gems:
        - name: pg
          version: '1.5'
          source:
            type: rubygems
        - name: local_thing
          version: '2.0'
          source:
            type: local
            path: ./vendor/local_rbs
        gemfile_lock_path: Gemfile.lock
      YAML
      path = write_lockfile(body)

      result = described_class.discover(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      gem_names = result.map { |p| p.parent.basename.to_s }.sort
      expect(gem_names).to eq(%w[local_thing pg])
    end

    it "returns [] when the explicit lockfile_path doesn't exist" do
      result = described_class.discover(
        lockfile_path: "/does/not/exist.lock.yaml", project_root: tmpdir, auto_detect: false
      )
      expect(result).to eq([])
    end

    it "returns [] when the collection root referenced by the lockfile doesn't exist" do
      # Lockfile says `path: .gem_rbs_collection` but the dir
      # has never been created (e.g., committed lockfile, no
      # `rbs collection install` run yet).
      body = <<~YAML
        ---
        path: ".gem_rbs_collection"
        gems:
        - name: rack
          version: '3.0'
          source:
            type: git
        gemfile_lock_path: Gemfile.lock
      YAML
      path = write_lockfile(body)

      result = described_class.discover(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(result).to eq([])
    end
  end

  describe ".discover with auto_detect" do
    it "finds rbs_collection.lock.yaml next to the project root" do
      make_collection(File.join(tmpdir, ".gem_rbs_collection"), ["rack", "3.0"])
      write_lockfile(<<~YAML)
        ---
        path: ".gem_rbs_collection"
        gems:
        - name: rack
          version: '3.0'
          source:
            type: git
        gemfile_lock_path: Gemfile.lock
      YAML

      result = described_class.discover(lockfile_path: nil, project_root: tmpdir, auto_detect: true)
      expect(result.size).to eq(1)
    end

    it "returns [] when auto_detect is false and no explicit path" do
      result = described_class.discover(lockfile_path: nil, project_root: tmpdir, auto_detect: false)
      expect(result).to eq([])
    end

    it "returns [] when no rbs_collection.lock.yaml exists at the project root" do
      result = described_class.discover(lockfile_path: nil, project_root: tmpdir, auto_detect: true)
      expect(result).to eq([])
    end
  end

  describe ".discover with malformed lockfile" do
    it "returns [] when the YAML body is not a Hash" do
      path = write_lockfile("- just an array")
      result = described_class.discover(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(result).to eq([])
    end

    it "returns [] when the YAML is syntactically broken" do
      path = write_lockfile("this is: [unclosed")
      result = described_class.discover(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(result).to eq([])
    end
  end

  describe ".discover with non-default collection path" do
    it "resolves a custom `path:` field against the lockfile's directory" do
      # Lockfile lives in `<tmpdir>/config/` and points at
      # `<tmpdir>/config/../rbs/`.
      config_dir = File.join(tmpdir, "config")
      FileUtils.mkdir_p(config_dir)
      make_collection(File.join(tmpdir, "rbs"), ["rack", "3.0"])
      lockfile_path = File.join(config_dir, "rbs_collection.lock.yaml")
      File.write(lockfile_path, <<~YAML)
        ---
        path: "../rbs"
        gems:
        - name: rack
          version: '3.0'
          source:
            type: git
        gemfile_lock_path: ../Gemfile.lock
      YAML

      result = described_class.discover(
        lockfile_path: lockfile_path, project_root: tmpdir, auto_detect: false
      )
      expect(result.size).to eq(1)
      expect(result.first.parent.basename.to_s).to eq("rack")
    end
  end

  describe ".resolve_lockfile_path" do
    it "returns the explicit Pathname when it exists" do
      path = write_lockfile("---\npath: .gem_rbs_collection\n")
      resolved = described_class.resolve_lockfile_path(
        lockfile_path: path, project_root: tmpdir, auto_detect: false
      )
      expect(resolved).to be_a(Pathname)
      expect(resolved.to_s).to eq(File.expand_path(path))
    end

    it "returns nil when neither explicit nor auto-detect resolves" do
      resolved = described_class.resolve_lockfile_path(
        lockfile_path: nil, project_root: tmpdir, auto_detect: true
      )
      expect(resolved).to be_nil
    end
  end
end
