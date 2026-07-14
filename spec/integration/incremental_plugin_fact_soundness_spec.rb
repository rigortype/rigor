# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/analysis/incremental_session"
require "rigor/analysis/plugin_fact_fingerprint"
require "rigor/plugin/sorbet"
require "rigor-dry-types"
require "rigor-activerecord"

# ADR-88 WD4a — end-to-end proof that the fact-surface fingerprint (WD1) closes the incremental soundness gap
# for real bundled plugins. All runs are inside `Dir.chdir(dir)` so a plugin's default scan roots
# (`rbi_paths: sorbet/rbi`, `db/schema.rb`) resolve under the project and its trust-policy read roots, matching
# how `rigor check` runs from the project root.
RSpec.describe "ADR-88 incremental plugin-fact soundness" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  # A Sorbet sig in an `.rbi` under `rbi_paths:` is a file Rigor does NOT analyze and that is NOT in
  # `signature_paths:`, so editing it moves the catalog (a plugin producer value) without touching any
  # analyzed file. On master a warm recheck served the stale cached diagnostic for the call site the sig typed;
  # WD1's fingerprint invalidates the snapshot. Red-before (WD1 disabled) / green-after in the PR body.
  describe "sorbet .rbi sig edit (end-to-end)" do
    # Registers the real Sorbet plugin without touching the gem load path. Idempotent across the multiple
    # in-process loads a single `run_incremental` performs (the WD4b loader fix makes this work).
    def sorbet_requirer
      lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::Sorbet) unless Rigor::Plugin.registered_for("sorbet")
        true
      end
    end

    def write_project(sig_return:)
      # `Foo` is a discovered project class (Nominal receiver) so Sorbet's instance-side catalog lookup applies.
      File.write("models.rb", "class Foo\n  def bar\n    raise \"stub\"\n  end\nend\n")
      # The sig lives in the Sorbet RBI tree (`rbi_paths:` default `sorbet/rbi`), NOT analyzed, NOT a sig path.
      FileUtils.mkdir_p(File.join("sorbet", "rbi"))
      File.write(
        File.join("sorbet", "rbi", "foo.rbi"),
        "# typed: strict\nclass Foo\n  sig { returns(#{sig_return}) }\n  def bar; end\nend\n"
      )
      # The consumer: `Foo.new.bar.upcase` — valid only when `bar` returns a String.
      File.write("app.rb", "Foo.new.bar.upcase\n")
    end

    def config
      Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => %w[models.rb app.rb], "plugins" => ["rigor-sorbet"])
      )
    end

    def session(store)
      Rigor::Analysis::IncrementalSession.new(
        configuration: config, paths: %w[models.rb app.rb], cache_store: store, plugin_requirer: sorbet_requirer
      )
    end

    def full_diagnostics
      Rigor::Analysis::Runner.new(
        configuration: config, cache_store: nil, plugin_requirer: sorbet_requirer
      ).run(%w[models.rb app.rb]).diagnostics
    end

    def undefined_on_app?(diagnostics)
      diagnostics.any? { |d| d.path == "app.rb" && d.rule == "call.undefined-method" }
    end

    def norm(diagnostics)
      diagnostics.map(&:to_h).sort_by { |h| [h["path"].to_s, h["line"].to_i, h["rule"].to_s] }
    end

    it "invalidates the snapshot and re-analyzes the consumer when an .rbi sig changes the call-site type" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          cache_root = File.join(dir, ".rigor", "cache")
          snapshot = Rigor::Cache::IncrementalSnapshot.new(root: cache_root)
          fp = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: %w[models.rb app.rb])

          # Process 1 — sig returns Integer, so `Foo.new.bar.upcase` is undefined-method on the consumer.
          write_project(sig_return: "Integer")
          store1 = Rigor::Cache::Store.new(root: cache_root)
          diags1, warm1 = session(store1).run_incremental(snapshot: snapshot, fingerprint: fp)
          expect(warm1).to be(false)
          expect(undefined_on_app?(diags1)).to be(true)

          # Edit ONLY the .rbi sig to String — no analyzed file changes, and the global fingerprint is unchanged.
          write_project(sig_return: "String")

          # Process 2 — the fact-surface fingerprint sees the catalog moved and invalidates the snapshot: a full
          # re-analysis (NOT warm) clears the consumer's diagnostic, matching a full run byte-for-byte.
          store2 = Rigor::Cache::Store.new(root: cache_root)
          sess2 = session(store2)
          diags2, warm2 = sess2.run_incremental(snapshot: snapshot, fingerprint: fp)

          expect(warm2).to be(false)
          expect(sess2.fact_surface_invalidated?).to be(true)
          expect(undefined_on_app?(diags2)).to be(false)
          expect(norm(diags2)).to eq(norm(full_diagnostics))
        end
      end
    end
  end

  # The fact-surface fingerprint moves when a real bundled plugin's underlying source changes, so a warm
  # incremental recheck invalidates the snapshot rather than serving stale plugin-typed diagnostics. These
  # assert the WD1 fingerprint (the invalidation authority) directly against the plugins' ADR-9 facts / ADR-60
  # producer values — the same mechanism the sorbet end-to-end spec exercises. `cache_store: nil` so a producer
  # recomputes and reflects the edit.
  describe "fact-surface fingerprint moves on a real plugin edit" do
    attr_accessor :registering_requirer

    def compute(config)
      Rigor::Analysis::PluginFactFingerprint.compute(
        configuration: config, cache_store: nil, plugin_requirer: registering_requirer
      )
    end

    def dry_types_config
      Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => ["types.rb"], "plugins" => ["rigor-dry-types"])
      )
    end

    def activerecord_config
      Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => ["app/models/user.rb"], "plugins" => ["rigor-activerecord"])
      )
    end

    def write_schema(columns)
      File.write("db/schema.rb", <<~RUBY)
        ActiveRecord::Schema.define(version: 1) do
          create_table "users" do |t|
        #{columns.map { |c| "    t.string \"#{c}\"" }.join("\n")}
          end
        end
      RUBY
    end

    it "moves when a dry-types alias-module declaration is added" do
      self.registering_requirer = lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::DryTypes) unless Rigor::Plugin.registered_for("dry-types")
        true
      end
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          File.write("types.rb", "module Types\n  include Dry.Types()\nend\n")
          first = compute(dry_types_config)
          expect(first.digest).not_to be_nil
          expect(first.opaque?).to be(false)

          # A second alias module grows the `:dry_type_aliases` fact/producer table (`Extra::String` etc.).
          File.write("types.rb", <<~RUBY)
            module Types
              include Dry.Types()
            end

            module Extra
              include Dry.Types()
            end
          RUBY
          Rigor::Plugin.unregister!
          expect(compute(dry_types_config).digest).not_to eq(first.digest)
        end
      end
    end

    it "moves when an ActiveRecord model's schema column set changes" do
      self.registering_requirer = lambda do |_name|
        Rigor::Plugin.register(Rigor::Plugin::Activerecord) unless Rigor::Plugin.registered_for("activerecord")
        true
      end
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p("db")
          FileUtils.mkdir_p("app/models")
          File.write("app/models/user.rb", "class User < ApplicationRecord\nend\n")
          write_schema(%w[name])
          first = compute(activerecord_config)
          expect(first.digest).not_to be_nil
          expect(first.opaque?).to be(false)

          write_schema(%w[name email]) # a new column moves `:schema_table` + `:model_index`
          Rigor::Plugin.unregister!
          expect(compute(activerecord_config).digest).not_to eq(first.digest)
        end
      end
    end
  end
end
