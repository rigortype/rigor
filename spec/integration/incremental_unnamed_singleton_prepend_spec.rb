# frozen_string_literal: true

# Issue #3020 — a class-side read declines past an unnamed singleton-side prepend (`class << self; prepend(*MODS)`).
# `--incremental` must serve what a cold run reports when a reopening in another file adds the prepend, and when the
# class's own file switches an `extend(*MODS)` to `singleton_class.prepend(*MODS)`, which list the same unnamed
# singleton edge. `sig/` is empty. Each row's Ruby behaviour was witnessed on Ruby 4.0.5: a quiet call raises nothing
# from Rigor's reading (`Kt.foo` is `:a`, which answers `to_proc`); a reported one raises `NoMethodError`.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "incremental edges for an unnamed singleton prepend (#3020)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-unnamed-singleton-prepend-edge-") { |dir| Dir.chdir(dir) { example.run } }
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
    write("sig/types.rbs", "")
    files.each { |path, source| write(path, source) }
    paths = files.keys.sort
    expect(incremental_rows(paths)).to eq([first, false])
    expect(cold_rows).to eq(first)

    write(edited, after)
    expect(incremental_rows(paths)).to eq([second, true])
    expect(cold_rows).to eq(second)
  end

  let(:modules) { "module Ya\n  def foo = :a\nend\nMODS = [Ya]\n" }
  let(:reported) { [["lib/c.rb", 1, "undefined method `to_proc' for 1"]] }

  it "re-checks a class-side read in another file when a reopening adds the unnamed prepend" do
    files = { "lib/a.rb" => modules, "lib/k.rb" => "class Kt\n  def self.foo = 1\nend\n",
              "lib/re.rb" => "class Kt\nend\n", "lib/c.rb" => "Kt.foo.to_proc\n" }
    expect_toggle(files, edited: "lib/re.rb", after: "class Kt\n  class << self\n    prepend(*MODS)\n  end\nend\n",
                         first: reported, second: [])
  end

  it "re-checks a class-side read when the class's unnamed extend becomes an unnamed prepend" do
    files = { "lib/a.rb" => modules, "lib/k.rb" => "class Kt\n  def self.foo = 1\n  extend(*MODS)\nend\n",
              "lib/c.rb" => "Kt.foo.to_proc\n" }
    expect_toggle(files, edited: "lib/k.rb",
                         after: "class Kt\n  def self.foo = 1\n  singleton_class.prepend(*MODS)\nend\n",
                         first: reported, second: [])
  end
end
