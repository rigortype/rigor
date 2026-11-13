# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #3156 — the override walk asks a body-less project ancestor (`class AMid` / `end`) from its RBS, so the
# override's answer depends on the declaration existing. A warm `IncrementalSession` must re-check the overriding
# file when that declaration vanishes or appears, and agree with a full `--no-cache` run of the same tree.
#
# Guard: `Entry#declared_name` files the entry's `class:` edge, but `def.override-visibility-reduced`'s walk, which
# runs on every `def` whatever the configuration disables, passes the same entry and files the same edge today, so
# removing that line alone does not fail this example.
RSpec.describe "def.override-return-widened through a body-less ancestor — incremental" do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [File.join(dir, "app")], "signature_paths" => [File.join(dir, "sig")])
  end

  def widened(diagnostics)
    diagnostics.select { |d| d.rule == "def.override-return-widened" }.map { |d| [File.basename(d.path), d.line] }
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil)
    widened(guarded_run(runner, [File.join(dir, "app")]).diagnostics)
  end

  def write_project(dir, mid_rbs: "class ALeaf < AMid\n  def hook: () -> String\nend\n")
    app = File.join(dir, "app")
    sig = File.join(dir, "sig")
    FileUtils.mkdir_p([app, sig])
    File.write(File.join(sig, "a.rbs"), "class AMid\n  def hook: () -> Integer\nend\n#{mid_rbs}")
    File.write(File.join(app, "leaf.rb"), "class ALeaf < AMid\n  def hook = \"s\"\nend\n")
    File.join(app, "mid.rb")
  end

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [File.join(dir, "app")])
  end

  # `Mid` holds a Ruby `def hook` but only inherits its RBS declaration, so `def.override-visibility-reduced`'s
  # walk stops at `Mid` and files nothing for `AMid`: the override walk's own `class:` edge is the only one.
  it "re-checks the override past a nearer Ruby def when the body-less declaration vanishes" do
    Dir.mktmpdir do |dir|
      mid = write_project(dir, mid_rbs: "class Mid < AMid\nend\nclass ALeaf < Mid\n  def hook: () -> String\nend\n")
      File.write(File.join(dir, "app", "leaf.rb"),
                 "class Mid < AMid\n  def hook = 1\nend\nclass ALeaf < Mid\n  def hook = \"s\"\nend\n")
      File.write(mid, "class AMid\nend\n")
      session = session_for(dir)
      expect(widened(guarded_baseline(session))).to eq([["leaf.rb", 5]])

      File.write(mid, "class Other\nend\n")
      expect(widened(guarded_recheck(session).diagnostics)).to eq(full_run(dir))
      expect(full_run(dir)).to eq([])
    end
  end

  # A constant write that binds `NS::AMid` ahead of the body-less `AMid` appears in a file the reader has no
  # other edge to; the override walk's `constant:` edge re-checks it.
  it "re-checks the override when a constant write shadows the body-less class" do
    Dir.mktmpdir do |dir|
      mid = write_project(dir, mid_rbs: "module NS\nend\nclass NS::ALeaf < AMid\n  def hook: () -> String\nend\n")
      File.write(File.join(dir, "app", "leaf.rb"), "module NS\n  class ALeaf < AMid\n    def hook = \"s\"\n  end\nend\n")
      File.write(mid, "class AMid\nend\n")
      session = session_for(dir)
      expect(widened(guarded_baseline(session))).to eq([["leaf.rb", 3]])

      File.write(File.join(dir, "app", "alias.rb"), "class Other\nend\nmodule NS\n  AMid = ::Other\nend\n")
      expect(widened(guarded_recheck(session).diagnostics)).to eq(full_run(dir))
      expect(full_run(dir)).to eq([])
    end
  end

  it "re-checks the override when the body-less declaration is removed, then restored" do
    Dir.mktmpdir do |dir|
      mid = write_project(dir)
      File.write(mid, "class AMid\nend\n")
      session = session_for(dir)
      expect(widened(guarded_baseline(session))).to eq([["leaf.rb", 2]])

      File.write(mid, "class Other\nend\n")
      recheck = guarded_recheck(session)
      expect(widened(recheck.diagnostics)).to eq([])
      expect(full_run(dir)).to eq([])

      File.write(mid, "class AMid\nend\n")
      recheck = guarded_recheck(session)
      expect(widened(recheck.diagnostics)).to eq([["leaf.rb", 2]])
      expect(full_run(dir)).to eq([["leaf.rb", 2]])
    end
  end
end
