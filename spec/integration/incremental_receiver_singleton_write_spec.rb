# frozen_string_literal: true

# Issue #1647 — a receiver-form write to a class's singleton side (`Base.extend(X)`,
# `Base.define_singleton_method`) in a file that does not declare `Base`. A reader's class edge named only the
# declaring files, so a warm `--incremental` run kept the `call.wrong-arity` a cold run declines. Each example runs
# cold, adds the writer file, then removes it, and expects the warm rows to equal a cold run's at both steps.
#
# These are labelled guards. Four mechanisms re-check the reader, and the examples fail only with all of them removed:
# - the writer file joins `Base`'s per-file class-declaration set (`ScopeIndexer#record_singleton_class_sources`,
#   #1752 and #1941), so the declaration diff fires `class:Base`;
# - the moved class mark or unpositioned mixin fires `mark:` / `mixin:` (`IncrementalSession#mark_affected`, #1833
#   and #1661);
# - the file starts or stops defining `bar`, firing `defines:bar` (`#defined_name_affected`, #1459);
# - for `Base.extend(X)` only, `X#bar`'s visibility slot moves (`#visibility_name_affected`, #2134).
# Any one of the first three alone keeps every example green.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "an incremental recheck after a receiver-form singleton write in a new file (#1647)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-incremental-receiver-singleton-write-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:paths) { %w[lib] }
  let(:fires) { [["lib/b.rb", 1]] }

  writers = {
    "Base.extend(X)" => "module X\n  def bar(a) = a\nend\n\nBase.extend(X)\n",
    "Base.define_singleton_method" => "Base.define_singleton_method(:bar) { |a| a }\n"
  }

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => workers))
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.wrong-arity" }.map { |d| [d.path, d.line] }.sort
  end

  def incremental_rows
    root = File.join(Dir.pwd, ".rigor", "cache")
    snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
    session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths,
                                                      cache_store: Rigor::Cache::Store.new(root: root))
    diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
    [rows(diagnostics), warm]
  end

  def cold_rows
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    rows(guarded_run(runner, paths).diagnostics)
  end

  [0, 2].each do |pool|
    context "with workers #{pool}" do
      let(:workers) { pool }

      writers.each do |label, writer|
        it "follows the cold run when #{label} is added and then removed" do
          FileUtils.mkdir_p("lib")
          File.write("lib/base.rb", "class Base\n  def self.bar = 1\nend\n")
          File.write("lib/b.rb", "Base.bar(1)\n")
          expect(incremental_rows).to eq([fires, false])

          File.write("lib/x.rb", writer)
          expect(incremental_rows).to eq([[], true])
          expect(cold_rows).to eq([])

          File.delete("lib/x.rb")
          expect(incremental_rows).to eq([fires, true])
          expect(cold_rows).to eq(fires)
        end
      end
    end
  end
end
