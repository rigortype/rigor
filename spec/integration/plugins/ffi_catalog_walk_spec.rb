# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

FFI_CATALOG_WALK_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-ffi/lib", __dir__)
$LOAD_PATH.unshift(FFI_CATALOG_WALK_PLUGIN_LIB) unless $LOAD_PATH.include?(FFI_CATALOG_WALK_PLUGIN_LIB)
require "rigor-ffi"

# Issue #1803 — rigor-ffi's catalog walk lists the project through its IoBoundary, as one recorded
# `**/*.rb` glob over the root. It must still answer exactly what `Dir.glob("<root>/**/*.rb")` minus the
# `/vendor/` and `/.git/` paths answered, in the same order.
RSpec.describe "rigor-ffi catalog walk (#1803)" do
  let(:root) { File.realpath(Dir.mktmpdir("rigor-ffi-walk-")) }
  let(:boundary) do
    Rigor::Plugin::IoBoundary.new(policy: Rigor::Plugin::TrustPolicy.new(allowed_read_roots: [root]), plugin_id: "ffi")
  end

  after { FileUtils.rm_rf(root) }

  def write(relative, source = "")
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  def walk
    Rigor::Plugin::FFI::Discoverer.new(root: root, io: boundary).send(:ruby_files)
  end

  # Sorts differently entry by entry than as whole strings (`lib` < `lib-x.rb`, but `lib-x.rb` < `lib/`), holds a
  # directory named `*.rb`, a symlinked directory `**` does not descend through, and nested `vendor/` paths.
  it "answers the paths and order Dir.glob answered" do
    %w[z.rb a.rb lib-x.rb lib/c.rb lib/sub/d.rb lib/b/e.rb dir.rb/f.rb app/vendor/g.rb vendor/bundle/h.rb
       real/r.rb .git/hooks/i.rb].each { |path| write(path) }
    File.symlink(File.join(root, "real"), File.join(root, "link"))
    expected = Dir.glob(File.join(root, "**/*.rb")).reject { |p| p.include?("/vendor/") || p.include?("/.git/") }

    expect(walk).to eq(expected)
    expect(walk).to include(File.join(root, "lib/sub/d.rb"), File.join(root, "dir.rb"))
  end

  # #1956 — the `vendor/` skip reads the path under the root: matching `/vendor/` in the absolute path emptied the
  # catalog of every project that lives under some `…/vendor/…` directory.
  context "with a project root under a `vendor` directory" do
    let(:project) { File.join(root, "vendor", "proj") }
    let(:declaration) { "module L\n  extend FFI::Library\n  attach_function :foo, [], :int\nend\n" }

    def catalog
      Rigor::Plugin::FFI::Discoverer.discover(root: project, io: boundary)
    end

    it "catalogs the project's own files" do
      write("vendor/proj/lib/a.rb", declaration)

      expect(catalog.functions.keys.map(&:to_s)).to eq(["foo"])
    end

    it "still skips the project's own vendor/ directory (guard)" do
      write("vendor/proj/vendor/bundle/a.rb", declaration)

      expect(catalog.functions).to be_empty
    end
  end

  # #1959 — the walk globs relative to the root, so a root spelled with glob metacharacters is read literally.
  it "walks a root named `fx[1]` and not its sibling `fx1`" do
    write("fx1/sibling.rb")
    write("fx[1]/own.rb")
    walk = Rigor::Plugin::FFI::Discoverer.new(root: File.join(root, "fx[1]"), io: boundary).send(:ruby_files)

    expect(walk).to eq([File.join(root, "fx[1]", "own.rb")])
  end

  context "with a primed walk" do
    before do
      write("lib/a.rb")
      write("vendor/bundle/gems/x/lib/x.rb")
      walk
    end

    it "is fresh while nothing changed" do
      expect(boundary.cache_descriptor.fresh?).to be(true)
    end

    it "reads stale when a file appears in a new subdirectory outside vendor/" do
      write("lib/deep/new.rb")

      expect(boundary.cache_descriptor.fresh?).to be(false)
    end

    it "reads stale when a top-level .rb file appears" do
      write("new.rb")

      expect(boundary.cache_descriptor.fresh?).to be(false)
    end
  end
end
