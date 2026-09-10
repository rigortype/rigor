# frozen_string_literal: true

# Issue #959 — `TrustPolicy#allow_read?` stays `File.expand_path`-only (ADR-2's documented bound: no
# `File.realpath` / symlink resolution). `Dir.mktmpdir` hands back the unresolved `/tmp/...` alias on
# macOS while `Dir.pwd` (what `TrustPolicy#allowed_read_roots` defaults to) returns the OS-resolved
# `/private/tmp/...` path, so a plugin read expressed via the unresolved alias falls outside its own
# read root and used to be refused with nothing said about it. This spec pins the fix: the refusal now
# surfaces as one `plugin_trust.read-refused` `:info` diagnostic (naming the plugin and the refused
# path) instead of vanishing silently, gated through the real `Rigor::Analysis::Runner` — never a unit
# stub on `IoBoundary` / `TrustPolicy` alone, since the bug is in how the two are wired together across
# a `chdir`.

require "spec_helper"
require "tmpdir"

RSpec.describe "TrustPolicy refusal visibility (#959)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # A minimal plugin whose #prepare reads one project file through the IoBoundary — the same surface
  # `read_file` / `file?` / `directory?` / `list_directory` all funnel through `TrustPolicy#allow_read?`
  # on. `read_path` is injected per example so the same plugin drives all three fixture shapes below.
  def trust_probe_plugin(read_path)
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "trust-probe", version: "0.1.0")
      define_method(:prepare) do |_services|
        io_boundary.read_file(read_path)
      rescue Rigor::Plugin::AccessDeniedError
        nil
      end
    end
  end

  # Runs a one-file project rooted at `project_dir` (already `chdir`'d into) with the given plugin
  # class, and returns the run's diagnostics. `read_path` is what the plugin's `#prepare` passes to
  # `IoBoundary#read_file`.
  def run_with_trust_probe(project_dir, read_path)
    plugin_class = trust_probe_plugin(read_path)
    stub_const("FakeTrustProbePlugin", plugin_class)
    File.write(File.join(project_dir, "demo.rb"), "x = 1\n")

    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => ["demo.rb"], "plugins" => ["rigor-trust-probe"])
    )
    requirer = lambda do |_name|
      Rigor::Plugin.register(plugin_class)
      true
    end
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration, cache_store: nil, plugin_requirer: requirer
    )
    guarded_run(runner).diagnostics
  end

  def refusal_diagnostic(diagnostics)
    diagnostics.find { |d| d.rule == "plugin_trust.read-refused" }
  end

  # Case (b) / must-not-fire counterpart, run FIRST as the "today's code" baseline: with the tmpdir
  # realpath'd before the project root and every read path built from that same resolved root, the two
  # sides of `allow_read?`'s comparison already agree — no symlink alias in play — so the row must stay
  # silent both before and after this change. Establishes the fixture is not vacuously firing on
  # everything.
  it "stays silent when the project root and the read path agree (no symlink alias)" do
    Dir.mktmpdir do |raw_dir|
      dir = File.realpath(raw_dir)
      Dir.chdir(dir) do
        diagnostics = run_with_trust_probe(dir, File.join(dir, "demo.rb"))
        expect(refusal_diagnostic(diagnostics)).to be_nil
      end
    end
  end

  # Case (a) — the reported bug. `Dir.chdir(raw_dir)` then `Dir.pwd` returns the OS-RESOLVED path (macOS
  # resolves `/tmp` -> `/private/tmp` on `getcwd`), so `TrustPolicy#allowed_read_roots` (which defaults
  # to `[Dir.pwd]`) holds the resolved root while the plugin reads through `raw_dir` — the unresolved
  # alias `File.expand_path` never collapses. On a filesystem with no such alias (most CI Linux
  # runners), `raw_dir == File.realpath(raw_dir)` and this degenerates to the same non-firing shape as
  # the spec above; the assertion is skipped rather than false-failed in that case, since the platform
  # simply does not reproduce the bug's precondition.
  it "surfaces a plugin_trust.read-refused :info diagnostic for a project rooted under a symlink alias" do
    Dir.mktmpdir do |raw_dir|
      resolved_dir = File.realpath(raw_dir)
      skip "no symlink alias on this filesystem (raw tmpdir already resolved)" if raw_dir == resolved_dir

      Dir.chdir(raw_dir) do
        diagnostics = run_with_trust_probe(resolved_dir, File.join(raw_dir, "demo.rb"))
        diag = refusal_diagnostic(diagnostics)
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:info)
        expect(diag.message).to include('"trust-probe"')
        expect(diag.message).to include(File.join(raw_dir, "demo.rb"))
      end
    end
  end

  # Case (d) — a genuinely out-of-project read, proving the row is about refusals in general and not
  # specifically about symlink aliasing: no chdir trickery, just a path no read root could ever cover.
  it "surfaces the same diagnostic for a path genuinely outside every read root" do
    Dir.mktmpdir do |raw_dir|
      dir = File.realpath(raw_dir)
      Dir.chdir(dir) do
        diagnostics = run_with_trust_probe(dir, "/etc/hosts")
        diag = refusal_diagnostic(diagnostics)
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:info)
        expect(diag.message).to include('"trust-probe"')
        expect(diag.message).to include("/etc/hosts")
      end
    end
  end
end
