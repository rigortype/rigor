# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

FFI_CATALOG_WALK_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-ffi/lib", __dir__)
$LOAD_PATH.unshift(FFI_CATALOG_WALK_PLUGIN_LIB) unless $LOAD_PATH.include?(FFI_CATALOG_WALK_PLUGIN_LIB)
require "rigor-ffi"

# Issue #1803 — rigor-ffi's catalog walk lists the project through its IoBoundary one top-level entry at a time,
# so `vendor/` (whose files the walk always dropped) is never globbed: a warm run does not re-glob an installed
# bundle, and a `bundle install` does not invalidate the catalog. The walk must still answer exactly what
# `Dir.glob("<root>/**/*.rb")` minus the `/vendor/` and `/.git/` paths answered, in the same order.
RSpec.describe Rigor::Plugin::FFI::Discoverer do
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
    described_class.new(root: root, io: boundary).send(:ruby_files)
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

  context "with a primed walk" do
    before do
      write("lib/a.rb")
      write("vendor/bundle/gems/x/lib/x.rb")
      walk
      expect(boundary.cache_descriptor.fresh?).to be(true)
    end

    it "stays fresh when a file appears under vendor/" do
      write("vendor/bundle/gems/y/lib/y.rb")

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
