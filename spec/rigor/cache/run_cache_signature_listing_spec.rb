# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# Issue #979, acceptance — the defect was not "a row is missing from a descriptor", it was that a warm
# `rigor check` REPLAYS the pre-file diagnostics after a NEW `sig/*.rbs` is written. ADR-45 records a run's
# dependencies after it ran, so a file that did not exist during the run was in no row and the
# `analysis.run-diagnostics` slot validated fresh across exactly the edit that changes its answer.
#
# The arms below drive the real CLI over a real `.rigor/cache`: the appearance invalidates, and the edits
# that leave the set of signature files alone — a no-op run, a `touch`, an inode swap — still hit, because
# the row answers only which `.rbs` files exist and each file's own ADR-87 WD1 `:stat` row carries its
# content. `conforms-to` is the probe because the whole diagnostic flips on whether one interface is loaded,
# so the row the run prints is a direct read of which signature files it actually saw.
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

  def cache_stats(dir)
    _status, out, _err = run_cli("check", "--workers=0", "--no-stats", "--cache-stats", ".", cwd: dir)

    out[/analysis\.run-diagnostics: \d+ hits?, \d+ miss(?:es)?/] || out
  end

  # A project whose only `.rbs` declares `conforms-to _Foo` without declaring `_Foo`, so a cold run reports
  # the unresolved row and any run that sees `sig/roles.rbs` reports the missing-member row instead. Two
  # configured signature roots, so the per-root rows are plural and their deduplication is a real branch.
  def with_project
    Dir.mktmpdir("rigor-979-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "sig"))
      FileUtils.mkdir_p(File.join(dir, "vendor_sig"))
      File.write(File.join(dir, "vendor_sig", "helper.rbs"), "class Helper\nend\n")
      File.write(File.join(dir, ".rigor.yml"), "signature_paths:\n  - sig\n  - vendor_sig\n")
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

  # The freshness arms the High of the #981 review demanded: the row answers "which signature files exist",
  # so an edit that leaves the SET alone must not cost the hit. Both of these move the file's stat tuple
  # without changing a byte — which is what a `git checkout`, a `bundle install` or a CI run over a restored
  # cache does to a `.rbs` tree — and a stat-mode glob row would have made every one of them a full
  # re-analysis. The file's own ADR-87 WD1 `:stat` row still carries the edit itself.
  it "still serves the run from cache after a touch that leaves the bytes identical" do
    with_project do |dir|
      check(dir)
      path = File.join(dir, "sig", "widget.rbs")
      before = File.read(path)
      File.utime(Time.now + 3600, Time.now + 3600, path)

      expect(File.read(path)).to eq(before)
      expect(cache_stats(dir)).to eq("analysis.run-diagnostics: 1 hit, 0 misses")
    end
  end

  it "still serves the run from cache after a copy-and-rename that swaps the inode" do
    with_project do |dir|
      check(dir)
      path = File.join(dir, "sig", "widget.rbs")
      before = File.stat(path).ino
      FileUtils.cp(path, "#{path}.tmp")
      FileUtils.mv("#{path}.tmp", path)

      expect(File.stat(path).ino).not_to eq(before)
      expect(cache_stats(dir)).to eq("analysis.run-diagnostics: 1 hit, 0 misses")
    end
  end

  # A REGRESSION arm, not a demonstration of this change: master already caught a removal, through the
  # removed file's own `:stat` {FileEntry} row going stale. It is here so the listing row — which answers a
  # narrower question than that row does — cannot be made to mask it.
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

  # The cost bound: the listing is recorded once per signature ROOT, not once per `.rbs` file under it, so a
  # project with a large `sig/` pays one `Dir.glob` on validation rather than one row per file — and the two
  # configured roots make the plural case real.
  it "records exactly one names-mode glob row per signature root, whatever the file count" do
    with_project do |dir|
      File.write(File.join(dir, "sig", "roles.rbs"), roles_rbs)
      FileUtils.mkdir_p(File.join(dir, "sig", "nested"))
      File.write(File.join(dir, "sig", "nested", "extra.rbs"), "class Extra\nend\n")
      check(dir)

      rows = Dir.chdir(dir) do
        loader = Rigor::Environment.for_project(root: dir, signature_paths: %w[sig vendor_sig]).rbs_loader
        Rigor::Cache::RbsDescriptor.glob_entries(loader)
      end
      project_rows = rows.select { |row| row.root.end_with?("sig") }

      expect(project_rows.map { |row| File.basename(row.root) }).to contain_exactly("sig", "vendor_sig")
      expect(project_rows.map(&:pattern)).to all(eq(File.join("**", "*.rbs")))
      expect(rows.map(&:mode)).to all(eq(:names))
      expect(rows.map { |row| [row.root, row.pattern] }.uniq.size).to eq(rows.size)
    end
  end

  # The dedup branch itself ({RbsDescriptor.glob_entries}'s `uniq`), which needs a root reachable TWICE —
  # an explicit `signature_paths:` entry that is also a bundled plugin's `sig/` (#610). Two rows for one
  # root would be two contributions to the same composition slot. Deleting the `uniq` turns this red.
  it "contributes one row for a root the loader reaches twice" do
    with_project do |dir|
      root = Pathname.new(File.join(dir, "sig"))
      loader = instance_double(Rigor::Environment::RbsLoader, signature_paths: [root, root])

      rows = Rigor::Cache::RbsDescriptor.glob_entries(loader)

      expect(rows.size).to eq(1)
    end
  end
end
