# frozen_string_literal: true

# Issue #610, reopened — #770's stand-down has to hold on the run a user actually gets.
#
# `rigor check` holds a cache store by default, and on a MISS the env-cache producer rebuilds the
# environment from the loader's readers. 0.3.8's producer did not pass the deferred (plugin-contributed)
# list, so `plugins/rigor-activerecord/sig`'s `Relation[Elem]` collided with a non-generic `Relation` on
# every cached run while #770's store-less gate stayed green — the #696 lesson in its other shape. And when
# the stand-down DID run (`--no-cache`), the stood-down file was misreported as a QUARANTINED one, with
# advice to remove a declaration the plugin owns.
#
# Every arm runs through `Analysis::Runner` over a REAL cold store and asserts on the type of a call INTO
# the relation. Never on the relation's own type: `dump_type(rel)` reads `ActiveRecord::Relation[Post]` in
# the collided arm too — the plugin's type-node resolver produces it whether or not the class's definition
# builds (the reporter measured exactly this) — so a receiver-type assertion passes on the state being fixed.
require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/cache/store"

# Shared with the plugin specs that also load the bundled activerecord plugin from source.
unless defined?(ACTIVERECORD_PLUGIN_LIB)
  ACTIVERECORD_PLUGIN_LIB = File.expand_path("../../plugins/rigor-activerecord/lib", __dir__)
end
$LOAD_PATH.unshift(ACTIVERECORD_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIVERECORD_PLUGIN_LIB)
require "rigor-activerecord"

RSpec.describe "issue #610 plugin signature arity stand-down through the run" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:stood_down_rule) { "rbs.coverage.plugin-signature-stood-down" }

  # A Rails-shaped project: an abstract base, one model over a one-table schema, and — in the collision
  # arms — a stand-in for `rbs collection install`'s NON-generic `ActiveRecord::Relation`, declaring one
  # method the plugin does not (`collection_only`), so the survivor can be told from a collapsed class.
  def project_files(collection:)
    files = {
      "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
      "app/models/post.rb" => <<~RUBY,
        class Post < ApplicationRecord
        end
        rel = Post.where(title: "x")
        Rigor.dump_type(rel.first)
        Rigor.dump_type(rel.collection_only)
      RUBY
      "db/schema.rb" => <<~RUBY
        ActiveRecord::Schema[8.0].define(version: 1) do
          create_table "posts", force: :cascade do |t|
            t.string "title"
          end
        end
      RUBY
    }
    if collection
      files["collection_sig/activerecord.rbs"] = <<~RBS
        module ActiveRecord
          class Relation
            def each: () { (untyped) -> void } -> self
            def collection_only: () -> String
          end
        end
      RBS
    end
    files
  end

  def write_project(dir, collection:)
    project_files(collection: collection).each do |relative, contents|
      full = File.join(dir, relative)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents)
    end
  end

  def configuration(collection:)
    settings = { "paths" => ["app"], "plugins" => ["rigor-activerecord"] }
    settings["signature_paths"] = ["collection_sig"] if collection
    Rigor::Configuration.new(settings)
  end

  def plugin_requirer
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::Activerecord)
      true
    end
  end

  def cold_store(dir)
    Rigor::Cache::Store.new(root: File.join(dir, ".rigor", "cache"))
  end

  def run(dir, store, collection:)
    Rigor::Plugin.unregister!
    Dir.chdir(dir) do
      runner = Rigor::Analysis::Runner.new(
        configuration: configuration(collection: collection), cache_store: store,
        collect_stats: false, plugin_requirer: plugin_requirer
      )
      guarded_run(runner)
    end
  end

  # The `dump.type` row at `app/models/post.rb:<line>`, as the type it printed.
  def dumped_type(result, line)
    row = result.diagnostics.find do |d|
      d.rule == "dump.type" && d.path.to_s.end_with?("app/models/post.rb") && d.line == line
    end
    row&.message&.delete_prefix("dump_type: ")
  end

  def rules(result)
    result.diagnostics.map(&:rule)
  end

  def stood_down_rows(result)
    result.diagnostics.select { |d| d.rule == stood_down_rule }
  end

  it "stands the plugin's Relation down on a cold CACHED run, and a call INTO the relation resolves" do
    Dir.mktmpdir do |dir|
      write_project(dir, collection: true)
      result = run(dir, cold_store(dir), collection: true)

      # On 0.3.8 this read `Dynamic[top]` behind a `definition-build-failed` warning; `--no-cache` read
      # `String` behind a `quarantined-signature` warning naming the plugin's file. Neither is acceptable.
      expect(dumped_type(result, 5)).to eq("String")
      expect(rules(result)).not_to include("rbs.coverage.definition-build-failed")
      expect(rules(result)).not_to include("rbs.coverage.quarantined-signature")

      rows = stood_down_rows(result)
      expect(rows.size).to eq(1)
      expect(rows.first.severity).to eq(:info)
      expect(rows.first.path).to eq(".rigor.yml")
      expect(rows.first.message).to include("rigor-activerecord/sig/active_record/relation.rbs")
      expect(rows.first.message).to include("`ActiveRecord::Relation` with 1 type parameter")
      expect(rows.first.message)
        .to include("`collection_sig/activerecord.rbs` already declares it with no type parameters")
    end
  end

  it "reports the same stand-down on the WARM run over the same store" do
    Dir.mktmpdir do |dir|
      write_project(dir, collection: true)
      store = cold_store(dir)
      run(dir, store, collection: true)

      warm = run(dir, store, collection: true)
      expect(dumped_type(warm, 5)).to eq("String")
      expect(rules(warm)).not_to include("rbs.coverage.definition-build-failed")
      expect(rules(warm)).not_to include("rbs.coverage.quarantined-signature")
      expect(stood_down_rows(warm).size).to eq(1)
    end
  end

  it "keeps the plugin's element typing on a cached run when nothing else declares the class" do
    Dir.mktmpdir do |dir|
      write_project(dir, collection: false)
      result = run(dir, cold_store(dir), collection: false)

      # The must-not-regress arm: a blanket stand-down would lose this.
      expect(dumped_type(result, 4)).to eq("Post?")
      expect(stood_down_rows(result)).to be_empty
      expect(rules(result)).not_to include("rbs.coverage.quarantined-signature")
    end
  end
end
