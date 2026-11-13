# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #3156 — the override walk asks a body-less project ancestor (`class AMid` / `end`) from its RBS, so the
# override's answer depends on the declaration existing. A warm `IncrementalSession` must re-check the overriding
# file when that declaration vanishes or appears, and agree with a full `--no-cache` run of the same tree.
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

  def write_project(dir)
    app = File.join(dir, "app")
    sig = File.join(dir, "sig")
    FileUtils.mkdir_p([app, sig])
    File.write(File.join(sig, "a.rbs"), <<~RBS)
      class AMid
        def hook: () -> Integer
      end
      class ALeaf < AMid
        def hook: () -> String
      end
    RBS
    File.write(File.join(app, "leaf.rb"), "class ALeaf < AMid\n  def hook = \"s\"\nend\n")
    File.join(app, "mid.rb")
  end

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [File.join(dir, "app")])
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
