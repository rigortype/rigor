# frozen_string_literal: true

# Issue #2439 end to end: `rigor-activerecord` enabled beside an `rbs collection install` of activerecord 7.1+,
# which declares `StatementInvalid < AdapterError` where the plugin's `framework.rbs` says `< ActiveRecordError`.
# Before the fix the two clauses raised `RBS::SuperclassMismatchError`, `rbs.coverage.definition-build-failed`
# fired, and the class and every descendant read `Dynamic[top]`. Each arm also asserts the control
# `call.possible-nil-receiver` still fires, since a collapsed universe reports nothing.
require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/cache/store"

unless defined?(ACTIVERECORD_PLUGIN_LIB)
  ACTIVERECORD_PLUGIN_LIB = File.expand_path("../../plugins/rigor-activerecord/lib", __dir__)
end
$LOAD_PATH.unshift(ACTIVERECORD_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIVERECORD_PLUGIN_LIB)
require "rigor-activerecord"

RSpec.describe "plugin superclass stand-down through the runner (#2439)" do
  before do
    Rigor::Plugin.unregister!
    allow_any_instance_of(Rigor::Environment::RbsLoader).to receive(:warn) # rubocop:disable RSpec/AnyInstance
  end

  after { Rigor::Plugin.unregister! }

  # The issue's reproduction, with the collection cut to the hierarchy that collides.
  def write_project(dir)
    files = {
      "collection_sig/activerecord.rbs" => <<~RBS,
        module ActiveRecord
          class ActiveRecordError < StandardError
          end
          class AdapterError < ActiveRecordError
          end
          class ConnectionNotEstablished < AdapterError
          end
          class StatementInvalid < AdapterError
          end
        end
      RBS
      "app/models/query.rb" => <<~RUBY
        class Query
          class StatementInvalid < ::ActiveRecord::StatementInvalid
          end
          def run
            yield
          rescue ::ActiveRecord::StatementInvalid => e
            raise StatementInvalid, e.message
          end
          def control
            m = Regexp.last_match
            m.begin(0)
          end
        end
      RUBY
    }
    files.each do |relative, contents|
      full = File.join(dir, relative)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents)
    end
  end

  def run(dir, store)
    Rigor::Plugin.unregister!
    configuration = Rigor::Configuration.new(
      "paths" => ["app"], "plugins" => ["rigor-activerecord"], "signature_paths" => ["collection_sig"]
    )
    requirer = lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::Activerecord)
      true
    end
    Dir.chdir(dir) do
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: store, collect_stats: false,
                                           plugin_requirer: requirer)
      guarded_run(runner).diagnostics.map { |d| [d.rule, d.line, d.message] }
    end
  end

  def assert_reopened(rows)
    expect(rows.map(&:first)).not_to include("rbs.coverage.definition-build-failed")
    expect(rows.select { |row| row[0] == "call.possible-nil-receiver" }.map { |row| row[1] }).to eq([11])
    notice = rows.find do |row|
      row[0] == "rbs.coverage.plugin-signature-stood-down" && row[2].include?("framework.rbs")
    end
    expect(notice[2].scan(/`(ActiveRecord::\w+ < \w+)`/).flatten).to eq(
      ["ActiveRecord::ConnectionNotEstablished < ActiveRecordError",
       "ActiveRecord::StatementInvalid < ActiveRecordError"]
    )
  end

  it "builds every class on a cold and a warm cached run, and the control still fires" do
    Dir.mktmpdir do |dir|
      write_project(dir)
      store = Rigor::Cache::Store.new(root: File.join(dir, ".rigor", "cache"))
      assert_reopened(run(dir, store))
      assert_reopened(run(dir, store))
    end
  end
end
