# frozen_string_literal: true

# Self-check gate for issues #630 and #1803: plugin code that reads, lists or probes a project file with bare
# `File` / `Dir` / `Prism.parse_file` records no cache dependency, so the run-result caches (ADR-45) and
# `--incremental` (ADR-46) have no edge back to the file it derived its contribution from, and a warm run
# keeps serving the pre-edit answer until `--no-cache`. `Rigor::Plugin::IoBoundary` (`#read_file`, `#file?`,
# `#directory?`, `#list_directory`, `#glob`) records the row; a producer's `watch:` glob records it for the
# reads its block makes.
#
# This is a lexical check of the common spellings, not a proof: it reads each non-comment line of
# `plugins/*/lib` for the calls {DIRECT_FILESYSTEM_CALL} spells, and does not see a receiver held in a
# variable, a `send`, an alias, or a read made by a library the plugin calls.

require "spec_helper"

PLUGIN_LIB_GLOB = File.expand_path("../../plugins/*/lib/**/*.rb", __dir__)

# The spellings of a call that touches the filesystem by itself, without a boundary row. Each alternative
# ends at a name boundary, so `File.readlines` counts as itself and not as `File.read`.
DIRECT_FILESYSTEM_CALL = /
  (?:
    \b(?:
      File(?:\.|::)(?:read|binread|readlines|foreach|open|new|realpath|file\?|directory\?|exist\?|readable\?
                     |symlink\?|stat|lstat|size|mtime)
      | Dir(?:\.|::)(?:glob|children|entries|each_child|exist\?|foreach|new|open)
      | IO(?:\.|::)(?:read|binread|readlines|foreach)
      | FileTest(?:\.|::)\w+[?!]?
      | Pathname(?:\.|::)glob
      | Pathname(?:\.new)?\([^)]*\)\.(?:read|binread|readlines|each_line|glob|children|entries)
      | Prism(?:\.|::)parse_file
      | (?:YAML|Psych|JSON)(?:\.|::)(?:load_file|safe_load_file|unsafe_load_file)
    )(?![\w?!])
    | \bDir\[
    | \bKernel(?:\.|::)open\(
    | (?<![\w.:])open\(
  )
/x

# One count key per spelling: `File::read` counts as `File.read`, and a `Pathname(...)` argument is dropped.
def direct_call_key(call)
  call.gsub("::", ".").sub(/\APathname(?:\.new)?\([^)]*\)/, "Pathname()").delete_suffix("[").delete_suffix("(")
end

# Every remaining direct call in plugin code that needs no row, counted per call per file, with the reason. A
# new entry is a deliberate decision, not a default: prefer converting the call.
WATCHED_PRODUCER_WALK = "the walk runs inside a producer whose `watch:` glob covers the tree it lists, " \
                        "and each file it uses is read through the boundary"
ALLOWED_PLUGIN_FILESYSTEM_CALLS = {
  # Re-reads the file the ENGINE is analysing, at the moment it analyses it: the synthesizer is offered the
  # project's analysed files only, which the run-result caches already carry as analysed-file rows.
  "plugins/rigor-rbs-inline/lib/rigor/plugin/rbs_inline.rb" =>
    [{ "File.file?" => 1, "File.read" => 1 }, "re-reads the file under analysis"],
  # The `io: nil` branch of target detection, and its fallback for a path outside the boundary's trust
  # policy (the boundary refuses the read and has noted the refusal).
  "plugins/rigor-ffi/lib/rigor/plugin/ffi/target_detector.rb" =>
    [{ "Dir.glob" => 1, "File.file?" => 1, "File.read" => 2 }, "boundary-less branch and out-of-policy fallback"],
  # Each entry of a directory the boundary just listed (`#list_directory`), whose `:stat` row covers it.
  "plugins/rigor-actionpack/lib/rigor/plugin/actionpack/analyzer.rb" =>
    [{ "File.directory?" => 1 }, "classifies the entries of a boundary-listed directory"],
  # An in-process index fingerprint compared within one run; it reaches no cache.
  "plugins/rigor-actionpack/lib/rigor/plugin/actionpack/render_locals.rb" =>
    [{ "File.stat" => 1 }, "in-run index fingerprint"],
  # Canonicalises a path to the form the trust policy sees; the answer reads no content.
  "plugins/rigor-sorbet/lib/rigor/plugin/sorbet.rb" =>
    [{ "Dir.glob" => 1, "File.exist?" => 1, "File.realpath" => 1 },
     "#{WATCHED_PRODUCER_WALK}; File.exist? and File.realpath only canonicalise"],
  # Canonicalises an analysed file's path to compare it with the mailer index; reads no content.
  "plugins/rigor-actionmailer/lib/rigor/plugin/actionmailer.rb" =>
    [{ "File.realpath" => 1 }, "canonicalises an analysed file's path"],
  "plugins/rigor-active-model-serializers/lib/rigor/plugin/active_model_serializers/serializer_discoverer.rb" =>
    [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-actioncable/lib/rigor/plugin/actioncable/channel_discoverer.rb" =>
    [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-activejob/lib/rigor/plugin/activejob/job_discoverer.rb" => [{ "Dir.glob" => 1 },
                                                                             WATCHED_PRODUCER_WALK],
  "plugins/rigor-actionmailer/lib/rigor/plugin/actionmailer/mailer_discoverer.rb" =>
    [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-activerecord/lib/rigor/plugin/activerecord/model_discoverer.rb" =>
    [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-activestorage/lib/rigor/plugin/activestorage/attachment_discoverer.rb" =>
    [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-actionpack/lib/rigor/plugin/actionpack/controller_discoverer.rb" =>
    [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-dry-types/lib/rigor/plugin/dry_types.rb" => [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-pundit/lib/rigor/plugin/pundit/policy_discoverer.rb" => [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-pundit/lib/rigor/plugin/pundit/authorization_scan.rb" => [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-factorybot/lib/rigor/plugin/factorybot/factory_discoverer.rb" =>
    [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-alba/lib/rigor/plugin/alba/resource_discoverer.rb" => [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-typelizer/lib/rigor/plugin/typelizer/serializer_discoverer.rb" =>
    [{ "Dir.glob" => 2 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-rails-i18n/lib/rigor/plugin/rails_i18n.rb" => [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-rails-i18n/lib/rigor/plugin/rails_i18n/locale_loader.rb" => [{ "Dir.glob" => 1 },
                                                                              WATCHED_PRODUCER_WALK],
  "plugins/rigor-rails-routes/lib/rigor/plugin/rails_routes.rb" => [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  "plugins/rigor-sidekiq/lib/rigor/plugin/sidekiq/worker_discoverer.rb" => [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK],
  # #1803 — the view-assigns walk lists `controller_search_paths`, the tree the `:controller_index` producer's
  # `watch:` glob covers on every run, whether or not the producer computed; each file it uses is read through
  # the boundary. `spec/integration/rails_plugin_input_cache_spec.rb` pins the row.
  "plugins/rigor-actionpack/lib/rigor/plugin/actionpack/view_assigns.rb" =>
    [{ "Dir.glob" => 1 }, "lists the tree the `:controller_index` watch glob records every run"],
  # #1803 — the `config/environments/*.rb` listing behind queue-adapter detection feeds the attributions and
  # edges `init` builds, so it reaches every cache through `Effects::PluginFacts#digest`, recomputed each run;
  # each listed file is read through the boundary. `spec/integration/rails_plugin_input_cache_spec.rb` pins it.
  "plugins/rigor-activejob/lib/rigor/plugin/activejob/effects.rb" =>
    [{ "Dir.glob" => 1 }, "the adapter it finds is part of the plugin-facts digest every run recomputes"]
}.freeze

# Known gaps: direct calls that DO need a row and do not have one yet, left to follow-up issues. Each shapes a
# plugin answer from a directory listing the boundary never saw, so a file appearing there is not seen by the
# run-result caches. Listed so the gate stays green until they are converted, not because they are sound.
KNOWN_PLUGIN_ROW_GAPS = {}.freeze

RSpec.describe "plugin project reads go through the IoBoundary" do
  let(:repo_root) { File.expand_path("../..", __dir__) }

  # `{ relative_path => { call => count } }` over every plugin lib file, comment lines skipped.
  def direct_calls
    Dir.glob(PLUGIN_LIB_GLOB).each_with_object({}) do |path, calls|
      counts = Hash.new(0)
      File.readlines(path).each do |line|
        next if line.lstrip.start_with?("#")

        line.scan(DIRECT_FILESYSTEM_CALL) { |call| counts[direct_call_key(call)] += 1 }
      end
      calls[path.delete_prefix("#{repo_root}/")] = counts unless counts.empty?
    end
  end

  # `{ relative_path => { call => count } }` over both lists, the counts of a file in both summed.
  def listed_calls
    allowed = ALLOWED_PLUGIN_FILESYSTEM_CALLS.transform_values(&:first)
    allowed.merge(KNOWN_PLUGIN_ROW_GAPS) { |_path, ok, gap| ok.merge(gap) { |_call, a, b| a + b } }
  end

  it "has no direct filesystem call in plugins/*/lib beyond the listed ones" do
    listed = listed_calls
    unlisted = direct_calls.filter_map do |relative, counts|
      allowed = listed.fetch(relative, {})
      extra = counts.select { |call, count| count > allowed.fetch(call, 0) }
      "#{relative}: #{extra}" unless extra.empty?
    end
    expect(unlisted).to be_empty
  end

  it "keeps every listed exception pointing at calls the file still makes" do
    calls = direct_calls
    stale = listed_calls.filter_map do |relative, allowed|
      counts = calls.fetch(relative, {})
      missing = allowed.reject { |call, count| counts.fetch(call, 0) == count }
      "#{relative}: #{missing}" unless missing.empty?
    end
    expect(stale).to be_empty
  end

  # The spellings the gate claims to read, each counted under its own key, and look-alikes it must not count.
  it "counts each common spelling under its own key" do
    samples = {
      "File.read(path)" => "File.read", "File::read(path)" => "File.read", "File.readlines(path)" => "File.readlines",
      "File.new(path)" => "File.new", "File.realpath(path)" => "File.realpath", "Dir.new(path)" => "Dir.new",
      "Dir[pattern]" => "Dir", "FileTest.exist?(path)" => "FileTest.exist?",
      "Pathname.glob(pattern)" => "Pathname.glob",
      "Pathname(path).read" => "Pathname().read", "Pathname.new(path).readlines" => "Pathname().readlines",
      "Psych.load_file(path)" => "Psych.load_file", "JSON.load_file(path)" => "JSON.load_file",
      "open(path)" => "open", "Kernel.open(path)" => "Kernel.open"
    }
    keys = samples.keys.map { |line| line.scan(DIRECT_FILESYSTEM_CALL).map { |call| direct_call_key(call) } }
    expect(keys).to eq(samples.values.map { |key| [key] })
    expect(["io_boundary.read_file(path)", "File.read_more(x)", "StringIO.read", "io.open(x)", "reopen(x)"]
             .flat_map { |line| line.scan(DIRECT_FILESYSTEM_CALL) }).to be_empty
  end

  # The counterpart to the decline above: a scan that matched nothing at all would pass vacuously, so pin
  # that it really walks plugin source and really finds calls.
  it "actually scans plugin source" do
    expect(Dir.glob(PLUGIN_LIB_GLOB).size).to be > 50
    expect(direct_calls.size).to be > 20
  end
end
