# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/environment/rbs_collection_discovery"

RSpec.describe Rigor::Environment::RbsCollectionDiscovery do
  let(:tmpdir) { Dir.mktmpdir("rigor-rbs-collection-discovery-spec-") }

  after { FileUtils.rm_rf(tmpdir) }

  # Builds a `.gem_rbs_collection/<gem>/<version>/<gem>.rbs` layout matching what `rbs collection install` produces.
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

  # Issue #2946 — stdlib entries install nothing under the collection root; their names load as RBS libraries.
  describe ".stdlib_library_names" do
    it "lists the stdlib entries in lockfile order, de-duplicated, with no collection directory" do
      body = <<~YAML
        ---
        path: ".gem_rbs_collection"
        gems:
        - { name: ripper, version: '0', source: { type: stdlib } }
        - { name: activerecord, version: '7.1', source: { type: git } }
        - { name: net-protocol, version: '0', source: { type: stdlib } }
        - { name: ripper, version: '0', source: { type: stdlib } }
        - { version: '0', source: { type: stdlib } }
      YAML
      path = write_lockfile(body)

      names = described_class.stdlib_library_names(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(names).to eq(%w[ripper net-protocol])
    end

    it "returns [] when no lockfile resolves" do
      expect(described_class.stdlib_library_names(lockfile_path: nil, project_root: tmpdir)).to eq([])
    end

    # ADR-5 — a malformed entry is skipped, never raised out of the run.
    it "skips an entry whose source: is a scalar, keeping the rest" do
      body = "gems:\n- { name: ripper, version: '0', source: stdlib }\n" \
             "- { name: net-protocol, version: '0', source: { type: stdlib } }\n"
      path = write_lockfile(body)

      names = described_class.stdlib_library_names(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(names).to eq(%w[net-protocol])
    end
  end

  describe ".discover with a malformed source:" do
    it "admits an entry whose source: is a scalar when its directory exists" do
      make_collection(File.join(tmpdir, ".gem_rbs_collection"), ["rack", "3.0"])
      path = write_lockfile("gems:\n- { name: rack, version: '3.0', source: git }\n")

      result = described_class.discover(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      expect(result.map { |p| p.parent.basename.to_s }).to eq(["rack"])
    end
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

    it "returns no directory for an entry with source type stdlib (it loads as a library)" do
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

    it "skips gems named in skip_gem_names regardless of source type" do # rubocop:disable RSpec/ExampleLength
      # `cgi` / `logger` are stdlib-extracted default gems that ruby/gem_rbs_collection ships under a `git` source, yet
      # rigor loads them from its bundled stdlib — admitting the collection copy double-declares and raises
      # RBS::DuplicatedDeclarationError.
      make_collection(
        File.join(tmpdir, ".gem_rbs_collection"),
        ["cgi", "0.5"], ["logger", "1.7"], ["activerecord", "7.1"]
      )
      body = <<~YAML
        ---
        path: ".gem_rbs_collection"
        gems:
        - name: cgi
          version: '0.5'
          source:
            type: git
        - name: logger
          version: '1.7'
          source:
            type: git
        - name: activerecord
          version: '7.1'
          source:
            type: git
        gemfile_lock_path: Gemfile.lock
      YAML
      path = write_lockfile(body)

      result = described_class.discover(
        lockfile_path: path, project_root: tmpdir, auto_detect: false,
        skip_gem_names: %w[cgi logger uri date base64]
      )
      gem_names = result.map { |p| p.parent.basename.to_s }
      expect(gem_names).to eq(["activerecord"])
    end

    it "admits all gems when skip_gem_names is empty (default)" do
      make_collection(File.join(tmpdir, ".gem_rbs_collection"), ["cgi", "0.5"], ["rack", "3.0"])
      body = <<~YAML
        ---
        path: ".gem_rbs_collection"
        gems:
        - name: cgi
          version: '0.5'
          source:
            type: git
        - name: rack
          version: '3.0'
          source:
            type: git
        gemfile_lock_path: Gemfile.lock
      YAML
      path = write_lockfile(body)

      result = described_class.discover(lockfile_path: path, project_root: tmpdir, auto_detect: false)
      gem_names = result.map { |p| p.parent.basename.to_s }.sort
      expect(gem_names).to eq(%w[cgi rack])
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
      # Lockfile says `path: .gem_rbs_collection` but the dir has never been created (e.g., committed lockfile, no `rbs
      # collection install` run yet).
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
      # Lockfile lives in `<tmpdir>/config/` and points at `<tmpdir>/config/../rbs/`.
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

  describe ".resolve_lockfile_path with a `~/` lockfile" do
    before { allow(Dir).to receive(:home).and_return(tmpdir) }

    def resolve
      described_class.resolve_lockfile_path(lockfile_path: "~/c.lock.yaml", project_root: tmpdir, auto_detect: false)
    end

    it "resolves under the home directory, and not at all while the file is absent" do
      expect(described_class.configured_lockfile_path("~/c.lock.yaml")).to eq(File.join(tmpdir, "c.lock.yaml"))
      expect(resolve).to be_nil

      File.write(File.join(tmpdir, "c.lock.yaml"), "x")
      expect(resolve.to_s).to eq(File.join(tmpdir, "c.lock.yaml"))
    end
  end

  # Issue #3030 — rbs's `RBS::FileFinder.each_file(skip_hidden: true)` rule for a collection gem directory.
  describe ".hidden_file?" do
    it "is true below a _-prefixed directory at any depth, and false for a _-prefixed file name" do
      root = "/c/gem/1.0"

      expect(described_class.hidden_file?(root, "/c/gem/1.0/_test/test.rbs")).to be(true)
      expect(described_class.hidden_file?(root, "/c/gem/1.0/lib/_scripts/x.rbs")).to be(true)
      expect(described_class.hidden_file?(root, "/c/gem/1.0/_private.rbs")).to be(false)
      expect(described_class.hidden_file?(root, "/c/gem/1.0/lib/gem.rbs")).to be(false)
    end

    # The gem directory is the boundary: a `_`-prefixed directory above it (the `_test/` holding the lockfile)
    # says nothing about the gem's own files.
    it "reads only the path below the gem directory" do
      root = "/repo/gems/a/1.0/_test/.gem_rbs_collection/b/1.0"

      expect(described_class.hidden_file?(root, "#{root}/b.rbs")).to be(false)
    end
  end

  # Issue #3030 — a `signature_paths:` root whose real path ends in a collection entry's `<name>/<version>`.
  describe ".without_signature_path_copies" do
    let(:collection) do
      %w[mygem other].map { |name| File.join(tmpdir, ".gem_rbs_collection", name, "1.0") }
    end

    it "drops the entry a root names by its real path, so `..` and a symlink count" do
      FileUtils.mkdir_p(File.join(tmpdir, "gems", "mygem", "1.0", "_test"))
      File.symlink(File.join(tmpdir, "gems", "mygem", "1.0"), File.join(tmpdir, "link"))
      dotted = File.join(tmpdir, "gems", "mygem", "1.0", "_test", "..")

      expect(described_class.without_signature_path_copies(collection, [dotted])).to eq([collection[1]])
      expect(described_class.without_signature_path_copies(collection, [File.join(tmpdir, "link")]))
        .to eq([collection[1]])
    end

    it "keeps every entry for a root that names another gem, another version, or nothing on disk" do
      FileUtils.mkdir_p(File.join(tmpdir, "gems", "mygem", "2.0"))
      FileUtils.mkdir_p(File.join(tmpdir, "sig"))
      roots = [File.join(tmpdir, "gems", "mygem", "2.0"), File.join(tmpdir, "sig"), File.join(tmpdir, "absent")]

      expect(described_class.without_signature_path_copies(collection, roots)).to eq(collection)
    end
  end

  # Issue #3030 — the hint for a directory set up for a collection lockfile that has none.
  describe ".missing_lockfile_hint" do
    def hint(root, lockfile_path: nil, auto_detect: true)
      described_class.missing_lockfile_hint(lockfile_path: lockfile_path, project_root: root, auto_detect: auto_detect)
    end

    let(:test_dir) { File.join(tmpdir, "gems", "mygem", "1.0", "_test").tap { |dir| FileUtils.mkdir_p(dir) } }

    it "names a gem_rbs_collection test directory without a lockfile" do
      expect(hint(test_dir)).to eq(:collection_test_dir)
    end

    it "names a directory with an rbs_collection.yaml and no lockfile" do
      File.write(File.join(tmpdir, "rbs_collection.yaml"), "sources: []\n")

      expect(hint(tmpdir)).to eq(:collection_config)
    end

    it "is nil once the lockfile is there, in an ordinary directory, or with the lookup off" do
      other = File.join(tmpdir, "other", "mygem", "1.0", "_test").tap { |dir| FileUtils.mkdir_p(dir) }

      expect(hint(other)).to be_nil
      expect(hint(test_dir, auto_detect: false)).to be_nil
      File.write(File.join(test_dir, "rbs_collection.lock.yaml"), "---\ngems: []\n")
      expect(hint(test_dir)).to be_nil
    end

    it "names the directory when a configured lockfile is absent, whatever auto_detect says" do
      expect(hint(test_dir, lockfile_path: "missing.lock.yaml", auto_detect: false)).to eq(:collection_test_dir)
    end
  end
end
