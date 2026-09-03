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
# A fixture with NO golden FAILS. It used to report `pending`, which switched the gate off for exactly the
# fixtures a recent engine change had just added — the code paths this gate exists to watch
# (https://github.com/rigortype/rigor/issues/698). There is deliberately no opt-out list: regenerating one
# fixture is a single command now, so a missing golden records a step not taken rather than a decision made,
# and a list would be one more place for that step to hide. That failure has its own self-test — see
# "the missing-golden failure itself" below — because with every golden present it is otherwise unobservable.
#
# Regenerating golden files:
#
#   # ONE fixture — what you want after adding or changing a single fixture. Rewrites that file and no other.
#   UPDATE_SNAPSHOTS=my_fixture bundle exec rspec spec/integration/precision_snapshot_spec.rb
#
#   # Several, comma-separated.
#   UPDATE_SNAPSHOTS=my_fixture,other_fixture bundle exec rspec spec/integration/precision_snapshot_spec.rb
#
#   # The WHOLE corpus — only after an engine-wide change whose full diff you intend to review.
#   UPDATE_SNAPSHOTS=1 bundle exec rspec spec/integration/precision_snapshot_spec.rb
#
# Whatever the selection, READ the recorded types before committing them: a golden taken from a buggy run pins
# the bug, in the one artifact whose purpose is to notice it.
#
# The whole-corpus run additionally reports snapshot files with no matching fixture; the spec never deletes
# them, so remove them by hand when a fixture is deleted.

require "spec_helper"
require "yaml"
require "fileutils"
require "tmpdir"
require_relative "support/fixture_harness"

# The missing-golden self-test re-runs this file in a subprocess against a scratch directory, so the
# snapshot location is overridable. Nothing else sets it: an ordinary run reads the committed goldens.
SNAPSHOTS_DIR = File.expand_path(ENV.fetch("PRECISION_SNAPSHOTS_DIR", "snapshots"), __dir__)
FIXTURE_DIR   = File.expand_path("fixtures", __dir__)

UPDATE_SNAPSHOTS_ENV = ENV.fetch("UPDATE_SNAPSHOTS", "").strip.freeze

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

# Resolves an `UPDATE_SNAPSHOTS` value to the fixture names whose goldens this run rewrites.
#
#   ""  / "0"    → [], the verifying mode.
#   "1" / "all"  → every fixture.
#   anything else → the comma-separated names it spells, each of which MUST name a real fixture.
#
# An unknown name RAISES rather than selecting nothing. A typo that quietly regenerated zero files is
# indistinguishable from success at the shell and leaves the golden the author came to write still missing —
# which is the exact failure this gate is being repaired for.
def snapshot_update_targets(value, all_names)
  return [] if value.empty? || value == "0"
  return all_names.dup if %w[1 all].include?(value)

  names   = value.split(",").map(&:strip).reject(&:empty?)
  unknown = names - all_names
  return names if unknown.empty?

  raise ArgumentError,
        "UPDATE_SNAPSHOTS names #{unknown.size} value(s) that are not snapshot fixtures:\n" \
        "#{unknown.sort.map { |name| "  #{unknown_fixture_reason(name)}" }.join("\n")}\n" \
        "Use UPDATE_SNAPSHOTS=1 to regenerate every fixture."
end

# Says what is actually TRUE of a name that is not a snapshot fixture, because "does not exist" is wrong
# for the one shape a person is most likely to type. `fixtures/effects/` does exist — it is a container of
# per-spec project trees, carries no entry file, and is therefore not a fixture here — and telling its
# author it does not exist sends them looking in the wrong place.
def unknown_fixture_reason(name)
  entry = Rigor::IntegrationSupport::FixtureHarness::DEFAULT_ENTRY
  if File.directory?(File.join(FIXTURE_DIR, name))
    "#{name}: spec/integration/fixtures/#{name}/ exists but carries no #{entry}, so it is not a snapshot fixture"
  else
    "#{name}: no spec/integration/fixtures/#{name}.rb, and no spec/integration/fixtures/#{name}/ directory"
  end
end

UPDATE_TARGETS, UPDATE_TARGET_ERROR = begin
  [snapshot_update_targets(UPDATE_SNAPSHOTS_ENV, SNAPSHOT_FIXTURE_NAMES).freeze, nil]
rescue ArgumentError => e
  [[].freeze, e.message]
end

# The stale-snapshot sweep is meaningful only when the run wrote every fixture: against a single target,
# "every file that is not this one" is 100-odd false positives.
UPDATE_ALL = UPDATE_TARGETS.sort == SNAPSHOT_FIXTURE_NAMES.sort

def build_snapshot(harness)
  locals = harness.post_scope.locals.transform_keys(&:to_s).transform_values { |t| t.describe(:short) }
  { "locals" => locals.sort.to_h }
end

def snapshot_path(fixture_name)
  # Flatten directory separators so `foo/bar` → `foo__bar.yml`.
  safe = fixture_name.tr("/", "__")
  File.join(SNAPSHOTS_DIR, "#{safe}.yml")
end

# This gate captures TOP-LEVEL LOCALS only, so a fixture written entirely as class and method definitions
# records an EMPTY golden: committed, counted, and pinning nothing beyond "the fixture still evaluates without
# raising". That is not a reason to withhold the golden — the types in such a fixture are gated by its
# `assert_type` lines in `type_construction_spec` — but it IS a reason its author should be told, at the moment
# they generate it, that the precision gate is not the one watching their fixture.
def vacuous_snapshot_warning(names)
  "\n#{names.size} snapshot(s) pinned no type at all: #{names.sort.join(', ')}.\n" \
    "This gate captures top-level locals only, and those fixtures declare none, so their goldens are empty. " \
    "Assert the types they are about through `assert_type` in spec/integration/type_construction_spec.rb.\n"
end

# Re-runs THIS file in a subprocess, narrowed to one fixture's example, against a scratch snapshots
# directory that either holds that fixture's golden or is empty. Returns `[exit status, combined output]`.
#
# `PRECISION_SNAPSHOT_SELF_TEST` keeps the child from defining the self-test group at all, so the
# recursion is closed structurally rather than by relying on the `-e` filter to exclude it.
def run_against_scratch_snapshots(fixture, golden:)
  Dir.mktmpdir("precision-snapshot-selftest") do |dir|
    FileUtils.cp(snapshot_path(fixture), dir) if golden

    env = {
      "PRECISION_SNAPSHOTS_DIR" => dir,
      "PRECISION_SNAPSHOT_SELF_TEST" => "1",
      "UPDATE_SNAPSHOTS" => "0"
    }
    command = ["bundle", "exec", "rspec", __FILE__, "-e", "fixtures/#{fixture} matches the golden snapshot"]

    output = nil
    status = nil
    Bundler.with_unbundled_env do
      output = IO.popen(env, command, err: %i[child out], &:read)
      status = Process.last_status.exitstatus
    end
    [status, output]
  end
end

# Human-readable per-local diff, built before failing so the engineer immediately sees which locals moved.
def snapshot_diff(golden, actual)
  golden_locals = golden["locals"] || {}
  actual_locals = actual["locals"] || {}

  changed = golden_locals.filter_map do |var, expected_type|
    actual_type = actual_locals[var]
    "  #{var}: was #{expected_type.inspect}, now #{actual_type.inspect}" if actual_type != expected_type
  end
  changed + actual_locals.each_key.reject { |var| golden_locals.key?(var) }
                         .map { |var| "  #{var}: new local not in snapshot" }
end

RSpec.describe "Precision snapshots (inference regression gate)" do
  if UPDATE_TARGET_ERROR
    it "resolves the UPDATE_SNAPSHOTS selection to real fixtures" do
      expect(UPDATE_TARGET_ERROR).to be_nil, UPDATE_TARGET_ERROR
    end
  elsif UPDATE_TARGETS.any?
    # One unloadable fixture MUST NOT cost the whole regeneration: every other snapshot is still written, and
    # the failures are reported together at the end. Aborting on the first one leaves the tree half-regenerated
    # and hides how many fixtures are actually broken.
    it "writes fresh snapshots for the selected fixtures" do
      FileUtils.mkdir_p(SNAPSHOTS_DIR)

      vacuous  = []
      failures = UPDATE_TARGETS.filter_map do |name|
        snapshot = build_snapshot(Rigor::IntegrationSupport::FixtureHarness.new(name))
        File.write(snapshot_path(name), YAML.dump(snapshot))
        vacuous << name if snapshot["locals"].empty?
        nil
      rescue StandardError => e
        "  #{name}: #{e.class}: #{e.message}"
      end

      warn(vacuous_snapshot_warning(vacuous)) if vacuous.any?

      expect(failures).to be_empty,
                          "#{failures.size} of #{UPDATE_TARGETS.size} selected fixtures failed to regenerate " \
                          "(the rest were written):\n#{failures.join("\n")}"
    end

    if UPDATE_ALL
      it "reports snapshot files with no matching fixture" do
        expected = SNAPSHOT_FIXTURE_NAMES.map { |name| File.basename(snapshot_path(name)) }
        stale    = Dir.children(SNAPSHOTS_DIR) - expected
        expect(stale).to be_empty,
                         "Snapshot files with no matching fixture (delete them by hand):\n  #{stale.sort.join("\n  ")}"
      end
    end
  else
    # The selection is unit-tested in the VERIFYING mode so CI runs it — the regenerating modes are never
    # exercised on CI at all. Every decline is paired with the acceptance it must not swallow: a resolver that
    # rejected everything would satisfy the unknown-name example on its own.
    describe "the UPDATE_SNAPSHOTS selection" do
      let(:names) { %w[alpha beta gamma] }

      it "selects nothing in the verifying mode" do
        expect(snapshot_update_targets("", names)).to eq([])
        expect(snapshot_update_targets("0", names)).to eq([])
      end

      it "selects every fixture for the whole-corpus spellings" do
        expect(snapshot_update_targets("1", names)).to eq(names)
        expect(snapshot_update_targets("all", names)).to eq(names)
      end

      it "selects exactly one fixture, and so exactly one snapshot file, for a single name" do
        selected = snapshot_update_targets("beta", names)
        expect(selected).to eq(["beta"])
        expect(selected.map { |name| snapshot_path(name) }).to eq([File.join(SNAPSHOTS_DIR, "beta.yml")])
      end

      it "selects the named subset for a comma-separated list" do
        expect(snapshot_update_targets("gamma, alpha", names)).to eq(%w[gamma alpha])
      end

      it "rejects a name matching no fixture rather than quietly writing nothing" do
        expect { snapshot_update_targets("bta", names) }
          .to raise_error(ArgumentError, /are not snapshot fixtures.*bta/m)
        # Must still succeed: one bad name in a list does not condemn the list's spelling itself.
        expect { snapshot_update_targets("beta", names) }.not_to raise_error
      end

      # `effects` is the one directory under `fixtures/` that is deliberately not a fixture — it holds
      # per-spec project trees and carries no entry file. Telling someone who typed it that it "does not
      # exist" sends them to the wrong place, so the two shapes have to read differently.
      it "distinguishes a directory that is not a fixture from a name with nothing behind it" do
        expect(unknown_fixture_reason("effects"))
          .to match(%r{fixtures/effects/ exists but carries no #{Regexp.escape(
            Rigor::IntegrationSupport::FixtureHarness::DEFAULT_ENTRY
          )}})
        expect(unknown_fixture_reason("no_such_thing_at_all")).to match(/no spec.+\.rb, and no .+directory/)
      end

      it "resolves a real fixture name against the real corpus" do
        expect(snapshot_update_targets(SNAPSHOT_FIXTURE_NAMES.first, SNAPSHOT_FIXTURE_NAMES))
          .to eq([SNAPSHOT_FIXTURE_NAMES.first])
      end
    end

    # The hard failure has to be checked by RUNNING it. Every golden exists now, so reverting the
    # `expect(File.exist?(snap_path))` below to a `skip` leaves this whole file green — the gate that stops
    # the gate being switched off, itself switched off, which is #698 one level down. So: re-run this file
    # in a subprocess against a scratch snapshots directory, once with the golden absent and once with it
    # present. A source grep for the word `skip` would pass the moment someone wrote `pending` instead, and
    # would keep passing if the expectation were deleted outright; this cannot.
    unless ENV["PRECISION_SNAPSHOT_SELF_TEST"]
      describe "the missing-golden failure itself" do
        let(:fixture) { SNAPSHOT_FIXTURE_NAMES.first }

        it "goes red, names the single-fixture command, and does not pend" do
          status, output = run_against_scratch_snapshots(fixture, golden: false)
          expect(status).not_to eq(0), "expected a RED run with no golden:\n#{output}"
          expect(output).to include("UPDATE_SNAPSHOTS=#{fixture}")
          expect(output).not_to match(/\bpending\b/)
        end

        # Must-still-succeed: the same subprocess with the golden in place is green, so the arm above is
        # failing on the absent golden rather than on the scratch directory or the subprocess itself.
        it "goes green when the golden is there" do
          status, output = run_against_scratch_snapshots(fixture, golden: true)
          expect(status).to eq(0), "expected a GREEN run with the golden present:\n#{output}"
          expect(output).to include("1 example, 0 failures")
        end
      end
    end

    SNAPSHOT_FIXTURE_NAMES.each do |fixture_name|
      describe "fixtures/#{fixture_name}" do
        let(:harness)   { Rigor::IntegrationSupport::FixtureHarness.new(fixture_name) }
        let(:actual)    { build_snapshot(harness) }
        let(:snap_path) { snapshot_path(fixture_name) }

        it "matches the golden snapshot (no precision regression)" do
          expect(File.exist?(snap_path)).to be(true),
                                            "No golden snapshot for fixtures/#{fixture_name}: this regression " \
                                            "gate is switched off for that fixture until one is committed.\n" \
                                            "Generate it — then READ the recorded types before committing, " \
                                            "because a golden taken from a buggy run pins the bug:\n  " \
                                            "UPDATE_SNAPSHOTS=#{fixture_name} bundle exec rspec #{__FILE__}"

          changed = snapshot_diff(YAML.load_file(snap_path), actual)

          expect(changed).to be_empty,
                             "Precision changed for fixtures/#{fixture_name}.\n" \
                             "Diff (first 20 items):\n#{changed.first(20).join("\n")}\n\n" \
                             "If intentional: UPDATE_SNAPSHOTS=#{fixture_name} bundle exec rspec #{__FILE__}"
        end
      end
    end
  end
end
