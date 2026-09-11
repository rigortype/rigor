# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# Issue #979, acceptance — the defect was not "a row is missing from a descriptor", it was that a warm
# `rigor check` REPLAYS the pre-file diagnostics after a NEW `sig/*.rbs` is written. ADR-45 records a run's
# dependencies after it ran, so a file that did not exist during the run was in no row and the
# `analysis.run-diagnostics` slot validated fresh across exactly the edit that changes its answer.
#
# The arms below drive the real CLI over a real `.rigor/cache` and assert on the DIAGNOSTICS, following the
# #577 three-fixture shape: the appearance invalidates, the no-op run still hits, and the removal
# invalidates again. `conforms-to` is the probe because the whole diagnostic flips on whether one interface
# is loaded, so the row the run prints is a direct read of which signature files it actually saw.
RSpec.describe "run-result cache invalidation on a signature-root listing change" do
  def run_cli(*argv, cwd:)
    out = StringIO.new
    err = StringIO.new
    status = Dir.chdir(cwd) { Rigor::CLI.start(argv, out: out, err: err) }

    [status, out.string, err.string]
  end

  def check(dir, *extra)
    _status, out, _err = run_cli("check", "--workers=0", "--no-stats", *extra, ".", cwd: dir)
    out
  end

  def unresolved
    "dynamic.rbs-extended.unresolved"
  end

  def unsatisfied
    "rbs_extended.unsatisfied-conformance"
  end

  def roles_rbs
    "interface _Foo\n  def flush: () -> void\nend\n"
  end

  # A project whose only `.rbs` declares `conforms-to _Foo` without declaring `_Foo`, so a cold run reports
  # the unresolved row and any run that sees `sig/roles.rbs` reports the missing-member row instead.
  def with_project
    Dir.mktmpdir("rigor-979-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, ".rigor.yml"), "signature_paths:\n  - sig\n")
      File.write(File.join(dir, "sig", "widget.rbs"), <<~RBS)
        %a{rigor:v1:conforms-to _Foo}
        class Widget
          def name: () -> String
        end
      RBS
      File.write(File.join(dir, "widget.rb"), "class Widget\n  def name\n    \"widget\"\n  end\nend\n")
      yield dir
    end
  end

  it "reflects a signature file that APPEARS after the cold run" do
    with_project do |dir|
      cold = check(dir)
      File.write(File.join(dir, "sig", "roles.rbs"), roles_rbs)
      warm = check(dir)

      expect(cold).to include(unresolved)
      expect(warm).to include(unsatisfied)
      expect(warm).not_to include(unresolved)
    end
  end

  # The must-still-hit counterpart: a glob row re-globs and re-stats on every warm run, so an unchanged
  # signature tree must not thrash the slot it was added to protect.
  it "still serves the run from cache when nothing under the signature root changed" do
    with_project do |dir|
      check(dir)
      _status, out, _err = run_cli("check", "--workers=0", "--no-stats", "--cache-stats", ".", cwd: dir)

      expect(out).to include("analysis.run-diagnostics: 1 hit, 0 misses")
    end
  end

  it "reflects a signature file that is REMOVED after a warm hit" do
    with_project do |dir|
      File.write(File.join(dir, "sig", "roles.rbs"), roles_rbs)
      check(dir)
      warm_hit = check(dir)
      File.delete(File.join(dir, "sig", "roles.rbs"))
      after_removal = check(dir)

      expect(warm_hit).to include(unsatisfied)
      expect(after_removal).to include(unresolved)
      expect(after_removal).not_to include(unsatisfied)
    end
  end

  # The cost bound: the listing is recorded once per signature ROOT, not once per `.rbs` file under it, so
  # a project with a large `sig/` pays one `Dir.glob` + stat walk on validation rather than one row per file.
  it "records exactly one glob row per signature root, whatever the file count" do
    with_project do |dir|
      File.write(File.join(dir, "sig", "roles.rbs"), roles_rbs)
      FileUtils.mkdir_p(File.join(dir, "sig", "nested"))
      File.write(File.join(dir, "sig", "nested", "extra.rbs"), "class Extra\nend\n")
      check(dir)

      rows = Dir.chdir(dir) do
        loader = Rigor::Environment.for_project(root: dir, signature_paths: ["sig"]).rbs_loader
        Rigor::Cache::RbsDescriptor.glob_entries(loader)
      end
      project_rows = rows.select { |row| row.root.end_with?("sig") }

      expect(project_rows.size).to eq(1)
      expect(project_rows.first.pattern).to eq(File.join("**", "*.rbs"))
      expect(rows.map { |row| [row.root, row.pattern] }.uniq.size).to eq(rows.size)
    end
  end
end
