# frozen_string_literal: true

# Issue #2994 — the #618 top-level-`def` veto and a class-object read decline on a class that splats a module in
# (`include(*MODS)`). `--incremental` must serve what a cold run reports when the file of the splatted constant changes
# and when the class's own file switches between a literal include and the splat. `sig/` is empty. Each row's Ruby
# behaviour was witnessed on Ruby 4.0.5: a quiet call returns "X"; a reported one raises `NoMethodError`.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "incremental edges for a top-level def and a class-object read by `include(*MODS)` (#2994)",
               type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-unnamed-mixin-veto-edge-") { |dir| Dir.chdir(dir) { example.run } }
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

  let(:hooked) do
    "class Base\n  def self.bar = 1\nend\nmodule X\n  def bar = \"x\"\nend\n" \
      "module M1\n  def self.included(base) = base.extend(X)\nend\n"
  end

  it "keeps the veto when the file of the splatted constant changes" do
    files = { "lib/top.rb" => "def m1 = nil\n", "lib/mods.rb" => "module M1\n  def m1 = \"x\"\nend\nMODS = [M1]\n",
              "lib/k.rb" => "class K\n  include(*MODS)\n  def t = m1.upcase\nend\n" }
    expect_toggle(files, edited: "lib/mods.rb",
                         after: "module M1\n  def m1 = \"x\"\nend\nmodule M2\nend\nMODS = [M2, M1]\n",
                         first: [], second: [])
  end

  it "re-checks a subclass's call in another file when the class switches from no mixin to the splat" do
    files = { "lib/top.rb" => "def m1 = nil\n", "lib/mods.rb" => "module M1\n  def m1 = \"x\"\nend\nMODS = [M1]\n",
              "lib/k.rb" => "class K\nend\n", "lib/sub.rb" => "class Sub < K\n  def u = m1.upcase\nend\n" }
    expect_toggle(files, edited: "lib/k.rb", after: "class K\n  include(*MODS)\nend\n",
                         first: [["lib/sub.rb", 2, "undefined method `upcase' for nil"]], second: [])
  end

  it "keeps a class-object read declined when the file of the splatted constant changes" do
    files = { "lib/a.rb" => "#{hooked}MODS = [M1]\n", "lib/k.rb" => "class K < Base\n  include(*MODS)\nend\n",
              "lib/c.rb" => "K.bar.upcase\n" }
    expect_toggle(files, edited: "lib/a.rb", after: "#{hooked}module M2\nend\nMODS = [M2, M1]\n",
                         first: [], second: [])
  end

  it "re-checks a class-object read in another file when the class switches from no mixin to the splat" do
    files = { "lib/a.rb" => "#{hooked}MODS = [M1]\n", "lib/k.rb" => "class K < Base\nend\n",
              "lib/c.rb" => "K.bar.upcase\n" }
    expect_toggle(files, edited: "lib/k.rb", after: "class K < Base\n  include(*MODS)\nend\n",
                         first: [["lib/c.rb", 1, "undefined method `upcase' for 1"]], second: [])
  end
end
