# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/cache/store"
require "rigor/configuration"

# Issue #564, acceptance — the defect was not "a slot is missing from the key string", it was that a warm
# `rigor check` REPLAYS the pre-edit diagnostics after a `bundle add` / `bundle remove`. The locked gem set
# decides which bundle-shipped `sig/` dirs and `rbs_collection` dirs load, which ADR-72 gem overlays apply,
# and whether `rbs.coverage.missing-gem` fires — yet editing a lockfile touches no analyzed source and no
# `.rbs` file, so nothing the run-result cache read used to change.
#
# Every example therefore drives the real {Analysis::Runner} against a real on-disk {Cache::Store} and
# asserts on the DIAGNOSTICS, in both directions: a lockfile edit that licenses the ActiveSupport overlay
# must retract the `call.undefined-method` on `3.minutes`, and the edit that revokes it must restore it.
# A cache keyed without the lockfile serves a false positive one way and a false negative the other.
RSpec.describe "run-result cache invalidation on a lockfile edit" do
  def lockfile_body(gems)
    specs = gems.map { |name, version| "    #{name} (#{version})\n" }.join
    deps = gems.each_key.map { |name| "  #{name}\n" }.join
    "GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\nPLATFORMS\n  ruby\n\n" \
      "DEPENDENCIES\n#{deps}\nBUNDLED WITH\n   2.5.3\n"
  end

  # A FRESH Store every time, so a hit has to come off disk rather than out of the Store's in-process memo —
  # which is what the next `rigor check` process would face.
  def analyse(dir, cache_root, paths:)
    Dir.chdir(dir) do
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new(
          "paths" => paths, "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
        ),
        cache_store: Rigor::Cache::Store.new(root: cache_root), collect_stats: false
      )
      guarded_run(runner).diagnostics
    end
  end

  def rules(diagnostics, rule)
    diagnostics.select { |d| d.rule == rule }
  end

  # `3.minutes` resolves only through the ADR-72 `activesupport` overlay, which is licensed by the lockfile
  # alone — so the call site is a direct read of which lockfile the run actually observed.
  def overlay_arm(before_gems, after_gems)
    Dir.mktmpdir("rigor-lockfile-key-cache-") do |cache_root|
      Dir.mktmpdir("rigor-lockfile-key-project-") do |dir|
        File.write(File.join(dir, "code.rb"), "x = 3.minutes\n")
        File.write(File.join(dir, "Gemfile.lock"), lockfile_body(before_gems))
        before = analyse(dir, cache_root, paths: ["code.rb"])
        File.write(File.join(dir, "Gemfile.lock"), lockfile_body(after_gems))
        [before, analyse(dir, cache_root, paths: ["code.rb"])]
      end
    end
  end

  it "retracts the overlay-covered diagnostic when the gem is ADDED to the lockfile" do
    before, after = overlay_arm({ "rare_gem_a" => "1.0" }, { "activesupport" => "8.0.1" })

    expect(rules(before, "call.undefined-method").map(&:message)).to include(a_string_including("minutes"))
    expect(rules(after, "call.undefined-method")).to be_empty
  end

  it "restores the diagnostic when the gem is REMOVED from the lockfile" do
    before, after = overlay_arm({ "activesupport" => "8.0.1" }, { "rare_gem_a" => "1.0" })

    expect(rules(before, "call.undefined-method")).to be_empty
    expect(rules(after, "call.undefined-method").map(&:message)).to include(a_string_including("minutes"))
  end

  # The shape that surfaced the bug: two projects sharing one cache, alike in everything the key read
  # (empty path set, identical configuration) and differing only in their lockfile.
  it "does not serve one project's gem-coverage answer to a sibling with a different lockfile" do
    Dir.mktmpdir("rigor-lockfile-key-shared-") do |cache_root|
      uncovered, covered = [{ "rare_gem_a" => "1.0", "rare_gem_b" => "2.5" }, { "json" => "2.7.0" }].map do |gems|
        Dir.mktmpdir("rigor-lockfile-key-sibling-") do |dir|
          File.write(File.join(dir, "Gemfile.lock"), lockfile_body(gems))
          rules(analyse(dir, cache_root, paths: []), "rbs.coverage.missing-gem")
        end
      end

      expect(uncovered.length).to eq(1)
      expect(uncovered.first.message).to include("rare_gem_a")
      # `json` is a DEFAULT_LIBRARIES entry, so this project has full coverage and must stay silent.
      expect(covered).to be_empty
    end
  end
end
