# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/analysis/incremental_session"

DEVISE_PLUGIN_LIB_FOR_INCREMENTAL = File.expand_path("../../plugins/rigor-devise/lib", __dir__)
$LOAD_PATH.unshift(DEVISE_PLUGIN_LIB_FOR_INCREMENTAL) unless $LOAD_PATH.include?(DEVISE_PLUGIN_LIB_FOR_INCREMENTAL)
require "rigor-devise"

# PR #2286 review M1 — the ADR-16 synthetic-method index is built from class-body DSL calls (`devise
# :database_authenticatable`), which no declaration signature records and no dependency edge names. Removing the
# `devise` call left `user.rb` declaration-stable, so `consumer.rb`, typed through the synthesised
# `valid_password?`, was served its cached diagnostic. The session now digests the index and re-analyses the
# project when it moves. Each "process" is a fresh session over the same snapshot, the way `rigor check
# --incremental` runs.
RSpec.describe "incremental recheck over a trait-registry edit" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:devise_rbs) do
    <<~RBS
      module ActiveRecord
        class Base
          def self.devise: (*Symbol) -> void
        end
      end

      module Devise
        module Models
          module Authenticatable
          end

          module DatabaseAuthenticatable
            def valid_password?: (String) -> bool
          end
        end
      end
    RBS
  end

  let(:with_devise) do
    "class ApplicationRecord < ActiveRecord::Base\nend\n\n" \
      "class User < ApplicationRecord\n  devise :database_authenticatable\nend\n"
  end
  let(:without_devise) { "class ApplicationRecord < ActiveRecord::Base\nend\n\nclass User < ApplicationRecord\nend\n" }

  def requirer
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::Devise) unless Rigor::Plugin.registered_for("devise")
      true
    end
  end

  def write_project(dir, model)
    FileUtils.mkdir_p(File.join(dir, "app"))
    FileUtils.mkdir_p(File.join(dir, "sig"))
    File.write(File.join(dir, "sig", "devise.rbs"), devise_rbs)
    File.write(File.join(dir, "app", "user.rb"), model)
    File.write(File.join(dir, "app", "consumer.rb"),
               "def check(pw)\n  User.new.valid_password?(pw).no_such_bool_method\nend\n")
  end

  def config(dir)
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => [File.join(dir, "app")], "signature_paths" => [File.join(dir, "sig")], "plugins" => ["rigor-devise"]
      )
    )
  end

  def incremental_run(dir, workers)
    Rigor::Plugin.unregister!
    snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".rigor", "cache"))
    fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config(dir),
                                                                roots: [File.join(
                                                                  dir, "app"
                                                                )])
    session = Rigor::Analysis::IncrementalSession.new(
      configuration: config(dir), paths: [File.join(dir, "app")], cache_store: nil, plugin_requirer: requirer,
      workers: workers
    )
    guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint).first
  end

  def cold_run(dir)
    Rigor::Plugin.unregister!
    runner = Rigor::Analysis::Runner.new(configuration: config(dir), cache_store: nil, plugin_requirer: requirer)
    guarded_run(runner).diagnostics
  end

  def rows(diagnostics)
    diagnostics.select { |d| d.path.to_s.end_with?(".rb") }
               .map { |d| [File.basename(d.path), d.line, d.rule.to_s] }.sort
  end

  [0, 2].each do |workers|
    it "serves no stale row after a `devise` call is removed and re-added (workers: #{workers})" do
      skip "fork is unavailable on this platform" if workers.positive? && !Process.respond_to?(:fork)
      Dir.mktmpdir do |dir|
        write_project(dir, with_devise)
        typed = [["consumer.rb", 2, "call.undefined-method"]]
        expect(rows(incremental_run(dir, workers))).to eq(typed)

        File.write(File.join(dir, "app", "user.rb"), without_devise)
        expect(rows(cold_run(dir))).to eq([])
        expect(rows(incremental_run(dir, workers))).to eq([])

        File.write(File.join(dir, "app", "user.rb"), with_devise)
        expect(rows(incremental_run(dir, workers))).to eq(typed)
      end
    end
  end

  it "keeps the warm path when an edit leaves the index unchanged" do
    Dir.mktmpdir do |dir|
      write_project(dir, with_devise)
      incremental_run(dir, 0)
      File.write(File.join(dir, "app", "user.rb"), "# a comment\n#{with_devise}")
      Rigor::Plugin.unregister!
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".rigor", "cache"))
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config(dir),
                                                                  roots: [File.join(dir, "app")])
      session = Rigor::Analysis::IncrementalSession.new(
        configuration: config(dir), paths: [File.join(dir, "app")], cache_store: nil, plugin_requirer: requirer
      )

      _diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)

      expect(warm).to be(true)
    end
  end
end
