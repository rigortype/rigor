# frozen_string_literal: true

# Issue #1592 — a class's singleton resolution chain holds the modules its direct mixins' hooks extend it with, and
# those hooks live in the mixin's file, which a class-side call has no other edge to. Editing that file, or adding a
# file that reopens the mixin or declares the module its hook names, must re-check the call: `--incremental` must
# serve what a cold run reports. `sig/` declares every class and module, empty, so RBS answers no call.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "incremental edges for a hook-extended singleton module (#1592)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-singleton-hook-extend-edge-") { |dir| Dir.chdir(dir) { example.run } }
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

  # Writes `files`, runs once, rewrites `lib/near.rb` to `after`, and expects the warm run to equal a cold one.
  def expect_toggle(files, before:, after:, first:, second:)
    write("sig/types.rbs", sig_source)
    files.merge("lib/near.rb" => before).each { |path, source| write(path, source) }
    paths = (files.keys + ["lib/near.rb"]).sort
    expect(incremental_rows(paths)).to eq([first, false])
    expect(cold_rows).to eq(first)

    write("lib/near.rb", after)
    expect(incremental_rows(paths)).to eq([second, true])
    expect(cold_rows).to eq(second)
  end

  def sig_source = "module Ct\nend\nmodule X\nend\nclass Base\nend\nclass Kt < Base\nend\n"

  let(:files) do
    { "lib/base.rb" => "class Base\n  def self.bar = 1\nend\nmodule X\n  def bar = \"X\"\nend\n",
      "lib/kt.rb" => "class Kt < Base\n  include Ct\nend\n",
      "lib/use.rb" => "Kt.bar.zork\n" }
  end

  def reported(type) = [["lib/use.rb", 1, "undefined method `zork' for #{type}"]]

  def concern(body) = "module Ct\n  extend ActiveSupport::Concern\n  def own = 1\n#{body}end\n"

  it "re-checks the call when the concern's file gains a class_methods def" do
    expect_toggle(files, before: concern(""), after: concern("  class_methods do\n    def bar = :cm\n  end\n"),
                         first: reported(1), second: reported(":cm"))
  end

  it "re-checks the call when the concern's file loses its class_methods def" do
    expect_toggle(files, before: concern("  class_methods do\n    def bar = :cm\n  end\n"), after: concern(""),
                         first: reported(":cm"), second: reported(1))
  end

  it "re-checks the call when the concern's file gains an included block's extend" do
    expect_toggle(files, before: concern(""), after: concern("  included do\n    extend X\n  end\n"),
                         first: reported(1), second: reported('"X"'))
  end

  # The reopening repeats `extend ActiveSupport::Concern`: the walk reads a `class_methods` block only in a body that
  # runs it.
  it "re-checks the call when a file reopening the concern adds a class_methods def" do
    reopened = files.merge("lib/ct.rb" => concern(""))
    expect_toggle(reopened, before: "",
                            after: "module Ct\n  extend ActiveSupport::Concern\n  class_methods do\n    " \
                                   "def bar = :cm\n  end\nend\n",
                            first: reported(1), second: reported(":cm"))
  end

  # Until a file declares it, the hook's `ClassMethods` is a module the project does not know, which may define any
  # name, so the read declines.
  it "re-checks the call when a new file declares the module the hook names" do
    hook = { "lib/ct.rb" => "module Ct\n  def self.included(base) = base.extend(ClassMethods)\nend\n" }
    expect_toggle(files.merge(hook), before: "",
                                     after: "module Ct\n  module ClassMethods\n    def bar = :cm\n  end\nend\n",
                                     first: [], second: reported(":cm"))
  end
end
