# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# #1956 / #1959 — a directory joined into a `Dir.glob` pattern is read as glob syntax. RootedGlob reads it as a
# path.
RSpec.describe Rigor::RootedGlob do
  let(:parent) { File.realpath(Dir.mktmpdir("rigor-rooted-glob-")) }

  after { FileUtils.rm_rf(parent) }

  def write(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "")
  end

  def tree(root)
    %w[a.rb lib/b.rb lib/deep/c.rb].each { |relative| write(File.join(root, relative)) }
  end

  # What a walk that never reads a name as a pattern answers: `Dir.children`, recursively.
  def literal_walk(dir, &)
    Dir.children(dir).sort.flat_map do |child|
      path = File.join(dir, child)
      next literal_walk(path, &) if File.directory?(path) && !File.symlink?(path)

      yield(path) ? [path] : []
    end
  end

  it "matches under a root spelled with metacharacters what it matches under a plain root" do
    tree(File.join(parent, "plain"))
    expected = described_class.glob(File.join(parent, "plain"), "**/*.rb").map do |p|
      p.delete_prefix("#{parent}/plain/")
    end

    ["ds [x]", "ds{a}", "ds*", "ds?q"].each do |name|
      tree(File.join(parent, name))
      found = described_class.glob(File.join(parent, name), "**/*.rb")

      expect(found.map { |p| p.delete_prefix("#{parent}/#{name}/") }).to eq(expected), name
    end
  end

  it "does not match a sibling the root's characters would match as a pattern" do
    write(File.join(parent, "fx1", "sibling.rb"))
    write(File.join(parent, "fx[1]", "own.rb"))

    expect(described_class.glob(File.join(parent, "fx[1]"), "*.rb")).to eq([File.join(parent, "fx[1]", "own.rb")])
  end

  it "does not leave a root named `{..,zz}`" do
    root = File.join(parent, "proj", "{..,zz}")
    write(File.join(root, "in.rb"))
    write(File.join(root, "sub", "deep.rb"))
    write(File.join(parent, "outside.rb"))

    expect(described_class.glob(root, "**/*.rb")).to eq(literal_walk(root) { |path| path.end_with?(".rb") })
  end

  # The joined spelling read a leading `/` under the root, in a brace alternative too; `Dir.glob(pattern, base:)`
  # reads either outside it.
  it "globs a pattern with a leading slash under the root" do
    write(File.join(parent, "root", "etc", "hostname-fixture"))

    expect(described_class.glob(File.join(parent, "root"), "/etc/host*"))
      .to eq([File.join(parent, "root", "etc", "hostname-fixture")])
  end

  # The join keeps the alternative's `/`, so its match reads `root//etc/…`, the string the joined glob answered.
  it "globs an absolute brace alternative under the root" do
    root = File.join(parent, "root")
    write(File.join(root, "etc", "hostname-fixture"))
    write(File.join(root, "lib", "hostlib.rb"))

    expect(described_class.glob(root, "{/etc,lib}/host*"))
      .to eq(["#{root}//etc/hostname-fixture", "#{root}/lib/hostlib.rb"])
  end

  it "keeps the root's spelling, relative or with a trailing slash (guard)" do
    tree(File.join(parent, "plain"))

    Dir.chdir(parent) do
      expect(described_class.glob("plain", "lib/*.rb")).to eq(["plain/lib/b.rb"])
      expect(described_class.glob("plain/", "lib/*.rb")).to eq(Dir.glob("plain/lib/*.rb"))
    end
  end
end
