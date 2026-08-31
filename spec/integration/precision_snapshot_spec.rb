# frozen_string_literal: true

# Precision snapshot regression gate.
#
# For every fixture under `spec/integration/fixtures/` this spec:
#   1. Runs the engine end-to-end via `FixtureHarness`.
#   2. Captures the type string (`Type#describe(:short)`) of every top-level local variable in the evaluated scope.
#   3. Compares the result to a YAML golden file under `spec/integration/snapshots/`.
#
# A failed example means a type CHANGED — either it became more precise (good — update the snapshot) or it
# degraded (bad — investigate and fix). In both cases the developer consciously reviews the diff before accepting.
#
# Regenerating golden files:
#
#   UPDATE_SNAPSHOTS=1 bundle exec rspec spec/integration/precision_snapshot_spec.rb
#
# The spec never deletes stale snapshot files automatically; remove them by hand when a fixture is deleted.

require "spec_helper"
require "yaml"
require "fileutils"
require_relative "support/fixture_harness"

SNAPSHOTS_DIR = File.expand_path("snapshots", __dir__)
FIXTURE_DIR   = File.expand_path("fixtures",  __dir__)

UPDATE_SNAPSHOTS = ENV.fetch("UPDATE_SNAPSHOTS", "0") == "1"

# Enumerate fixture names: flat .rb files → name without extension, project fixtures → directory name.
#
# A directory qualifies only when it carries the harness entry file, because that is exactly what
# `FixtureHarness#load_project` requires. `fixtures/` is a shared fixture root, not this spec's private one:
# `fixtures/effects/` is a container of per-spec project trees (`effects/rails`, `effects/policy`, …) that the
# effects specs address by absolute path, and neither it nor its children is loadable here. Discriminating on
# the entry file keeps any future non-harness tree out of the gate without an exclusion list to maintain.
SNAPSHOT_FIXTURE_NAMES = (
  Dir.children(FIXTURE_DIR).sort.filter_map do |entry|
    path = File.join(FIXTURE_DIR, entry)
    if File.file?(path) && entry.end_with?(".rb")
      entry.delete_suffix(".rb")
    elsif File.directory?(path) &&
          File.file?(File.join(path, Rigor::IntegrationSupport::FixtureHarness::DEFAULT_ENTRY))
      entry
    end
  end
).freeze

def build_snapshot(harness)
  locals = harness.post_scope.locals.transform_keys(&:to_s).transform_values { |t| t.describe(:short) }
  { "locals" => locals.sort.to_h }
end

def snapshot_path(fixture_name)
  # Flatten directory separators so `foo/bar` → `foo__bar.yml`.
  safe = fixture_name.tr("/", "__")
  File.join(SNAPSHOTS_DIR, "#{safe}.yml")
end

RSpec.describe "Precision snapshots (inference regression gate)" do
  if UPDATE_SNAPSHOTS
    # One unloadable fixture MUST NOT cost the whole regeneration: every other snapshot is still written, and
    # the failures are reported together at the end. Aborting on the first one leaves the tree half-regenerated
    # and hides how many fixtures are actually broken.
    it "writes fresh snapshots for all fixtures" do
      FileUtils.mkdir_p(SNAPSHOTS_DIR)

      failures = SNAPSHOT_FIXTURE_NAMES.filter_map do |name|
        harness  = Rigor::IntegrationSupport::FixtureHarness.new(name)
        snapshot = build_snapshot(harness)
        File.write(snapshot_path(name), YAML.dump(snapshot))
        nil
      rescue StandardError => e
        "  #{name}: #{e.class}: #{e.message}"
      end

      expect(failures).to be_empty,
                          "#{failures.size} of #{SNAPSHOT_FIXTURE_NAMES.size} fixtures failed to regenerate " \
                          "(the rest were written):\n#{failures.join("\n")}"

      expected = SNAPSHOT_FIXTURE_NAMES.map { |name| File.basename(snapshot_path(name)) }
      stale    = Dir.children(SNAPSHOTS_DIR) - expected
      expect(stale).to be_empty,
                       "Snapshot files with no matching fixture (delete them by hand):\n  #{stale.sort.join("\n  ")}"
    end
  else
    SNAPSHOT_FIXTURE_NAMES.each do |fixture_name|
      describe "fixtures/#{fixture_name}" do
        let(:harness)  { Rigor::IntegrationSupport::FixtureHarness.new(fixture_name) }
        let(:actual)   { build_snapshot(harness) }
        let(:snap_path) { snapshot_path(fixture_name) }

        it "matches the golden snapshot (no precision regression)" do
          unless File.exist?(snap_path)
            skip "No golden snapshot yet. Run: UPDATE_SNAPSHOTS=1 bundle exec rspec #{__FILE__}"
          end

          golden = YAML.load_file(snap_path)

          # Build a human-readable diff before failing so the engineer immediately sees which locals changed and how.
          changed = []
          (golden["locals"] || {}).each do |var, expected_type|
            actual_type = actual.dig("locals", var)
            if actual_type != expected_type
              changed << "  #{var}: was #{expected_type.inspect}, now #{actual_type.inspect}"
            end
          end
          (actual["locals"] || {}).each_key do |var|
            changed << "  #{var}: new local not in snapshot" unless (golden["locals"] || {}).key?(var)
          end

          expect(changed).to be_empty,
                             "Precision changed for fixtures/#{fixture_name}.\n" \
                             "Diff (first 20 items):\n#{changed.first(20).join("\n")}\n\n" \
                             "If intentional: UPDATE_SNAPSHOTS=1 bundle exec rspec #{__FILE__}"
        end
      end
    end
  end
end
