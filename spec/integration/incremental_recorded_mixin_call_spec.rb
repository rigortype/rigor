# frozen_string_literal: true

# Issue #2995 — `self.include M` and a receiverless `send(:include, M)` record `M` under the class as `include M`
# does, so a call the class makes, or a subclass in another file makes, depends on `M`'s file and on the class's
# file. Editing either must re-check the call: `--incremental` must serve what a cold run reports. `sig/` declares
# every class, empty, so RBS answers no call. Each row's Ruby behaviour was witnessed on Ruby 4.0.5: `m2` raises
# `NoMethodError` before the edit and returns 2 after it.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "incremental edges for a recorded `self.include` / `send(:include)` (#2995)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-recorded-mixin-call-edge-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.undefined-method" }.map { |d| [d.path, d.line, d.message] }
  end

  def cold_rows
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    rows(guarded_run(runner, %w[lib]).diagnostics).sort
  end

  def incremental_rows(paths)
    root = File.join(Dir.pwd, ".rigor", "cache")
    snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
    session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths,
                                                      cache_store: Rigor::Cache::Store.new(root: root))
    diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
    [rows(diagnostics).sort, warm]
  end

  # Writes `files`, runs once, rewrites `edited` to `after`, and expects the warm run to equal a cold one.
  def expect_toggle(files, edited:, after:, first:, second:)
    write("sig/types.rbs", "class K\nend\nclass Sub < K\nend\n")
    files.each { |path, source| write(path, source) }
    paths = files.keys.sort
    expect(incremental_rows(paths)).to eq([first, false])
    expect(cold_rows).to eq(first)

    write(edited, after)
    expect(incremental_rows(paths)).to eq([second, true])
    expect(cold_rows).to eq(second)
  end

  def mod(name, body) = "module #{name}\n#{body}end\n"

  {
    "self.include M1" => "  self.include M1\n",
    "send(:include, M1)" => "  send(:include, M1)\n",
    "self.public_send(:prepend, M1)" => "  self.public_send(:prepend, M1)\n"
  }.each do |label, call|
    it "re-checks the class's call when the module's file gains the method, for `#{label}`" do
      files = { "lib/m.rb" => mod("M1", "  def m1 = 1\n"), "lib/k.rb" => "class K\n#{call}  def w = self.m2\nend\n" }
      expect_toggle(files, edited: "lib/m.rb", after: mod("M1", "  def m1 = 1\n  def m2 = 2\n"),
                           first: [["lib/k.rb", 3, "undefined method `m2' for K"]], second: [])
    end

    it "re-checks a subclass's call in another file when the class switches module, for `#{label}`" do
      files = { "lib/m.rb" => mod("M1", "  def m1 = 1\n") + mod("M2", "  def m2 = 2\n"),
                "lib/k.rb" => "class K\n#{call}end\n", "lib/sub.rb" => "class Sub < K\n  def u = self.m2\nend\n" }
      expect_toggle(files, edited: "lib/k.rb", after: "class K\n#{call.sub('M1', 'M2')}end\n",
                           first: [["lib/sub.rb", 2, "undefined method `m2' for Sub"]], second: [])
    end
  end
end
