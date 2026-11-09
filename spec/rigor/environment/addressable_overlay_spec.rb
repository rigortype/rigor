# frozen_string_literal: true

# Issue #2857 — the `Addressable::URI.parse` correction overlay.
#
# gem_rbs_collection declares `self.parse: (String | URI uri) -> instance`, but `Addressable::URI.parse(nil)`
# returns nil, so `Addressable::URI.parse(a['href'])` on a `String?` drew a false `call.argument-type-mismatch`
# (mastodon `app/services/fetch_link_card_service.rb`). `data/gem_overlay/addressable/addressable.rbs` declares
# the nil arm; because the overlay exists to correct a signature `rbs collection` already supplies, it loads
# under `:rbs_collection` coverage — NOT the ADR-72 `:missing` gate every other overlay keeps — and the
# deferred-signature plan composes it over the collection's copy as an overload continuation.
#
# The assertions are positive for the reason `gem_overlay_stand_down_spec.rb` records: a collapsed or absent
# signature produces ZERO diagnostics, so each example pins the resolved TYPE next to the diagnostic that must
# (or must not) fire.
require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "issue #2857 addressable overlay" do
  def gemfile_lock
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          addressable (2.8.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        addressable

      BUNDLED WITH
         2.5.6
    LOCK
  end

  # The `gems/addressable/2.8/addressable.rbs` copy `rbs collection install` writes, trimmed to the members the
  # examples exercise: `self.parse` (the signature under correction) and two readers that prove the collection's
  # own surface still binds beside the overlay's.
  def collection_rbs
    <<~RBS
      module Addressable
        class URI
          def self.parse: (String | URI uri) -> instance

          attr_reader host: String
          attr_reader path: String
        end
      end
    RBS
  end

  def collection_lock
    <<~YAML
      ---
      path: ".gem_rbs_collection"
      gems:
      - name: addressable
        version: 2.8
        source:
          type: git
          name: ruby/gem_rbs_collection
          remote: https://github.com/ruby/gem_rbs_collection.git
          revision: abc
          repo_dir: gems
      gemfile_lock_path: Gemfile.lock
    YAML
  end

  # `collection:` false leaves addressable locked but sig-less (`:missing` coverage); true writes the
  # `rbs_collection.lock.yaml` + `.gem_rbs_collection/` pair `rbs collection install` produces.
  def write_project(dir, collection:)
    File.write(File.join(dir, "Gemfile.lock"), gemfile_lock)
    return unless collection

    FileUtils.mkdir_p(File.join(dir, ".gem_rbs_collection", "addressable", "2.8"))
    File.write(File.join(dir, ".gem_rbs_collection", "addressable", "2.8", "addressable.rbs"), collection_rbs)
    File.write(File.join(dir, "rbs_collection.lock.yaml"), collection_lock)
  end

  def run_source(source, collection: true)
    Dir.mktmpdir("rigor-addressable-overlay-") do |dir|
      write_project(dir, collection: collection)
      File.write(File.join(dir, "code.rb"), source)
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new(
          "paths" => [File.join(dir, "code.rb")],
          "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true },
          "rbs_collection" => { "auto_detect" => true }
        )
        guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
      end
    end
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map { |d| d.message.sub("dump_type: ", "") }
  end

  def call_rules(result)
    result.diagnostics.map(&:qualified_rule).grep(/\Acall\./)
  end

  def argument_mismatches(result)
    result.diagnostics.select { |d| d.rule == "call.argument-type-mismatch" }
  end

  it "binds nil to the nil arm and keeps the URI answer for String and URI arguments" do
    result = run_source(<<~RUBY)
      uri = Addressable::URI.parse("https://example.com")
      Rigor.dump_type(Addressable::URI.parse(nil))
      Rigor.dump_type(Addressable::URI.parse("https://example.com"))
      Rigor.dump_type(Addressable::URI.parse(uri))
      Rigor.dump_type(uri.host)
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(["nil", "Addressable::URI", "Addressable::URI", "String"])
  end

  # The issue's motivating shape: a `String?` argument mismatched the collection's `(String | URI)` parameter.
  # With the nil arm composed in, the multi-overload check defers the union argument instead of refuting it.
  it "does not report call.argument-type-mismatch for a String? argument" do
    result = run_source(<<~RUBY)
      def href(flag)
        flag ? "https://example.com" : nil
      end
      Addressable::URI.parse(href(true))
      Addressable::URI.parse(href(false))
    RUBY

    expect(argument_mismatches(result)).to be_empty
    expect(call_rules(result)).to be_empty
  end

  # Control: the correction must not open the parameter. An Integer argument is refuted by every overload.
  it "still reports call.argument-type-mismatch for an argument no overload admits" do
    result = run_source(<<~RUBY)
      Addressable::URI.parse(123)
    RUBY

    expect(argument_mismatches(result).size).to eq(1)
  end

  # The gate: with no `rbs collection` sigs the gem is `:missing` coverage and the overlay stays unloaded —
  # its partial `Addressable::URI` declaration would turn `uri.host` into a false `call.undefined-method`.
  # `Dynamic[top]` on every dump is the proof nothing loaded.
  it "does not load the overlay when addressable is locked without rbs collection sigs" do
    result = run_source(<<~RUBY, collection: false)
      uri = Addressable::URI.parse("https://example.com")
      Rigor.dump_type(Addressable::URI.parse(nil))
      Rigor.dump_type(uri.host)
    RUBY

    expect(dumps(result)).to eq(%w[Dynamic[top] Dynamic[top]])
    expect(call_rules(result)).to be_empty
  end

  # Loader-level half of the gate, so a future eligibility change that loads the directory without fixing the
  # partial-class hazard fails here rather than only in the diagnostics above.
  describe "overlay eligibility" do
    def overlay_loaded?(dir)
      Dir.chdir(dir) do
        env = Rigor::Environment.for_project(
          root: dir, bundler_auto_detect: true, rbs_collection_auto_detect: true, paths: [File.join(dir, "code.rb")]
        )
        env.rbs_loader.signature_paths.any? { |path| path.to_s.include?("gem_overlay/addressable") }
      end
    end

    it "is eligible under :rbs_collection coverage" do
      Dir.mktmpdir("rigor-addressable-eligibility-") do |dir|
        write_project(dir, collection: true)
        File.write(File.join(dir, "code.rb"), "")
        expect(overlay_loaded?(dir)).to be(true)
      end
    end

    it "is not eligible under :missing coverage" do
      Dir.mktmpdir("rigor-addressable-eligibility-") do |dir|
        write_project(dir, collection: false)
        File.write(File.join(dir, "code.rb"), "")
        expect(overlay_loaded?(dir)).to be(false)
      end
    end
  end
end
