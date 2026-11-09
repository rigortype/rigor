# frozen_string_literal: true

# Issue #3006 — a class-body `send` whose computed name may be `include` lists the unnamed marker on the class's
# instance side, so a subclass in another file stops reporting a name the unnamed module may define. Editing the
# class's file between a name that is not a mixin's (`meth = :attr_reader`) and one that may be (`meth = :include`)
# must re-check the subclass: `--incremental` must serve what a cold run reports. `sig/` declares every class, empty,
# so RBS answers no call. Each row's Ruby behaviour was witnessed on Ruby 4.0.5: `m1` raises `NoMethodError` with
# `attr_reader` and returns 1 with `include`.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "incremental edges for a class-body computed-name `send` (#3006)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-computed-send-edge-") { |dir| Dir.chdir(dir) { example.run } }
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

  def klass(name) = "class K\n  meth = :#{name}\n  send(meth, #{name == 'include' ? 'M1' : ':x'})\nend\n"

  [%w[attr_reader include], %w[include attr_reader]].each do |before, after|
    it "re-checks a subclass in another file when the class's computed name moves from `#{before}` to `#{after}`" do
      write("sig/types.rbs", "class K\nend\nclass Sub < K\nend\n")
      files = { "lib/m.rb" => "module M1\n  def m1 = 1\nend\n", "lib/k.rb" => klass(before),
                "lib/sub.rb" => "class Sub < K\n  def u = self.m1\nend\n" }
      files.each { |path, source| write(path, source) }
      paths = files.keys.sort
      reported = [["lib/sub.rb", 2, "undefined method `m1' for Sub"]]
      first, second = before == "include" ? [[], reported] : [reported, []]
      expect(incremental_rows(paths)).to eq([first, false])
      expect(cold_rows).to eq(first)

      write("lib/k.rb", klass(after))
      expect(incremental_rows(paths)).to eq([second, true])
      expect(cold_rows).to eq(second)
    end
  end
end
