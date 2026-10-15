# frozen_string_literal: true

# Self-check gate for issues #630 and #1803: plugin code that reads, lists or probes a project file with bare
# `File` / `Dir` / `Prism.parse_file` records no cache dependency, so the run-result caches (ADR-45) and
# `--incremental` (ADR-46) have no edge back to the file it derived its contribution from, and a warm run
# keeps serving the pre-edit answer until `--no-cache`. `Rigor::Plugin::IoBoundary` (`#read_file`, `#file?`,
# `#directory?`, `#list_directory`, `#glob`) records the row; a producer's `watch:` glob records it for the
# reads its block makes. This spec keeps the bypass from creeping back in.

require "spec_helper"

PLUGIN_LIB_GLOB = File.expand_path("../../plugins/*/lib/**/*.rb", __dir__)

# A call that touches the filesystem by itself, without a boundary row.
DIRECT_FILESYSTEM_CALL = /
  \b(?:
    File\.(?:read|binread|readlines|foreach|open|file\?|directory\?|exist\?|readable\?|stat|lstat|size|mtime)
    | Dir\.(?:glob|children|entries|each_child|exist\?|foreach)
    | Dir\[
    | IO\.(?:read|binread|readlines|foreach)
    | Prism\.parse_file
    | YAML\.(?:load_file|safe_load_file)
  )
/x

# Every remaining direct call in plugin code, counted per call per file, with the reason it is not a
# boundary bypass. A new entry is a deliberate decision, not a default: prefer converting the call.
WATCHED_PRODUCER_WALK = "the walk runs inside a producer whose `watch:` glob covers the tree it lists, " \
                        "and each file it uses is read through the boundary"
ALLOWED_PLUGIN_FILESYSTEM_CALLS = {
  # Re-reads the file the ENGINE is analysing, at the moment it analyses it: the synthesizer is offered the
  # project's analysed files only, which the run-result caches already carry as analysed-file rows.
  "plugins/rigor-rbs-inline/lib/rigor/plugin/rbs_inline.rb" =>
    [{ "File.file?" => 1, "File.read" => 1 }, "re-reads the file under analysis"],
  # The `io: nil` branch, and the fallback for a path outside the boundary's trust policy (the boundary
  # refuses the read and has noted the refusal).
  "plugins/rigor-ffi/lib/rigor/plugin/ffi/target_detector.rb" =>
    [{ "Dir.glob" => 1, "File.file?" => 1, "File.read" => 2 }, "boundary-less branch and out-of-policy fallback"],
  "plugins/rigor-ffi/lib/rigor/plugin/ffi/discoverer.rb" =>
    [{ "File.directory?" => 1, "Dir.glob" => 1, "Prism.parse_file" => 2 },
     "boundary-less branch and out-of-policy fallback"],
  # Each entry of a directory the boundary just listed (`#list_directory`), whose `:stat` row covers it.
  "plugins/rigor-actionpack/lib/rigor/plugin/actionpack/analyzer.rb" =>
    [{ "File.directory?" => 1 }, "classifies the entries of a boundary-listed directory"],
  # An in-process index fingerprint compared within one run; it reaches no cache. #1803 leaves the
  # membership of the walk, which builds the render-locals and view-assigns indexes, as a follow-up.
  "plugins/rigor-actionpack/lib/rigor/plugin/actionpack/render_locals.rb" =>
    [{ "File.stat" => 1, "Dir.glob" => 1 }, "in-run fingerprint; walk membership left to a follow-up"],
  "plugins/rigor-actionpack/lib/rigor/plugin/actionpack/view_assigns.rb" =>
    [{ "Dir.glob" => 1 }, "walk membership left to a follow-up"],
  # Shapes only `rigor effects` attributions and edges; its membership is left to a follow-up.
  "plugins/rigor-activejob/lib/rigor/plugin/activejob/effects.rb" =>
    [{ "Dir.glob" => 1 }, "effects-only adapter detection; left to a follow-up"],
  # Canonicalises a path to the form the trust policy sees; the answer reads no content.
  "plugins/rigor-sorbet/lib/rigor/plugin/sorbet.rb" =>
    [{ "Dir.glob" => 1, "File.exist?" => 1 }, "#{WATCHED_PRODUCER_WALK}; File.exist? only canonicalises"],
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
  "plugins/rigor-sidekiq/lib/rigor/plugin/sidekiq/worker_discoverer.rb" => [{ "Dir.glob" => 1 }, WATCHED_PRODUCER_WALK]
}.freeze

RSpec.describe "plugin project reads go through the IoBoundary" do
  let(:repo_root) { File.expand_path("../..", __dir__) }

  # `{ relative_path => { call => count } }` over every plugin lib file, comment lines skipped.
  def direct_calls
    Dir.glob(PLUGIN_LIB_GLOB).each_with_object({}) do |path, calls|
      counts = Hash.new(0)
      File.readlines(path).each do |line|
        next if line.lstrip.start_with?("#")

        line.scan(DIRECT_FILESYSTEM_CALL) { |call| counts[call.delete_suffix("[")] += 1 }
      end
      calls[path.delete_prefix("#{repo_root}/")] = counts unless counts.empty?
    end
  end

  it "has no direct filesystem call in plugins/*/lib beyond the listed ones" do
    unlisted = direct_calls.filter_map do |relative, counts|
      allowed = ALLOWED_PLUGIN_FILESYSTEM_CALLS.fetch(relative, [{}]).first
      extra = counts.select { |call, count| count > allowed.fetch(call, 0) }
      "#{relative}: #{extra}" unless extra.empty?
    end
    expect(unlisted).to be_empty
  end

  it "keeps every listed exception pointing at calls the file still makes" do
    calls = direct_calls
    stale = ALLOWED_PLUGIN_FILESYSTEM_CALLS.filter_map do |relative, (allowed, _reason)|
      counts = calls.fetch(relative, {})
      missing = allowed.reject { |call, count| counts.fetch(call, 0) == count }
      "#{relative}: #{missing}" unless missing.empty?
    end
    expect(stale).to be_empty
  end

  # The counterpart to the decline above: a scan that matched nothing at all would pass vacuously, so pin
  # that it really walks plugin source and really finds calls.
  it "actually scans plugin source" do
    expect(Dir.glob(PLUGIN_LIB_GLOB).size).to be > 50
    expect(direct_calls.size).to be > 20
  end
end
