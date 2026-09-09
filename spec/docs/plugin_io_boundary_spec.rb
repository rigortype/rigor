# frozen_string_literal: true

# Self-check gate for issue #630: plugin code that reads a project file with bare `File.read` records no
# cache dependency, so the run-result cache (ADR-45) and `--incremental` (ADR-46) have no edge back to the
# file it derived its contribution from — a warm run keeps serving the pre-edit answer until `--no-cache`.
# `Rigor::Plugin::IoBoundary#read_file` is the read that records; this spec keeps the bypass from creeping
# back in.

require "spec_helper"

PLUGIN_LIB_GLOB = File.expand_path("../../plugins/*/lib/**/*.rb", __dir__)

# Every remaining `File.read` in plugin code, with the reason it is not a boundary bypass. A new entry
# here is a deliberate decision, not a default: prefer converting the read.
ALLOWED_PLUGIN_FILE_READS = {
  # Re-reads the file the ENGINE is analysing, at the moment it analyses it. The run-result cache already
  # carries that file as an analyzed-file entry, so the read adds no dependency the run lacks; a boundary
  # row would only duplicate it.
  "plugins/rigor-rbs-inline/lib/rigor/plugin/rbs_inline.rb" => "re-reads the file under analysis",
  # Target detection answers ffx-vs-ffi from `ext/**/extconf.rb` before the plugin instance (and so its
  # boundary) is in scope for the detector module. A separate change from #630's four plugins.
  "plugins/rigor-ffi/lib/rigor/plugin/ffi/target_detector.rb" => "pre-boundary target detection"
}.freeze

RSpec.describe "plugin project reads go through the IoBoundary" do
  let(:repo_root) { File.expand_path("../..", __dir__) }

  # Every `File.read` call site in a plugin's own lib, as `path:line`, minus the listed exceptions.
  def offending_file_reads
    Dir.glob(PLUGIN_LIB_GLOB).flat_map do |path|
      relative = path.delete_prefix("#{repo_root}/")
      next [] if ALLOWED_PLUGIN_FILE_READS.key?(relative)

      File.readlines(path).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}" if line.match?(/\bFile\.read\b/)
      end
    end
  end

  it "has no `File.read` in plugins/*/lib outside the listed exceptions" do
    expect(offending_file_reads).to be_empty
  end

  it "keeps every listed exception pointing at a file that still reads that way" do
    stale = ALLOWED_PLUGIN_FILE_READS.keys.reject do |relative|
      absolute = File.join(repo_root, relative)
      File.file?(absolute) && File.read(absolute).match?(/\bFile\.read\b/)
    end
    expect(stale).to be_empty
  end

  # The counterpart to the decline above: a scan that matched nothing at all would pass vacuously, so pin
  # that it really walks plugin source.
  it "actually scans plugin source" do
    expect(Dir.glob(PLUGIN_LIB_GLOB).size).to be > 50
  end
end
