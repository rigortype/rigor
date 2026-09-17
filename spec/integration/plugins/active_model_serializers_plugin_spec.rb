# frozen_string_literal: true

require "spec_helper"

require "fileutils"
require "tmpdir"

AMS_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-active-model-serializers/lib", __dir__)
$LOAD_PATH.unshift(AMS_PLUGIN_LIB) unless $LOAD_PATH.include?(AMS_PLUGIN_LIB)
AMS_ACTIVERECORD_LIB = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
$LOAD_PATH.unshift(AMS_ACTIVERECORD_LIB) unless $LOAD_PATH.include?(AMS_ACTIVERECORD_LIB)

require "rigor-active-model-serializers"
require "rigor-activerecord"

# The whole plugin is one contributed return type, so every example here reads a `Rigor.dump_type`
# trace rather than a plugin diagnostic — the plugin emits none.
#
# `rigor-activerecord` runs alongside in every example because the `:model_index` fact is what
# corroborates the naming convention. The pair is the unit under test: the derivation is only ever as
# good as the model set some other plugin proved exists.
AMS_SCHEMA = <<~SCHEMA
  ActiveRecord::Schema[8.0].define(version: 1) do
    create_table "accounts", force: :cascade do |t|
      t.string "username", null: false
    end
  end
SCHEMA

AMS_ACCOUNT_MODEL = <<~MODEL
  class Account < ApplicationRecord
  end
MODEL

RSpec.describe "plugins/rigor-active-model-serializers" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::ActiveModelSerializers }

  # Runs both plugins over a project whose `app/serializers` holds `serializers`, and returns the
  # analysis result.
  def analyze(serializers:, config: nil, schema: AMS_SCHEMA)
    Dir.mktmpdir do |dir|
      files = serializers.merge(
        "app/models/account.rb" => AMS_ACCOUNT_MODEL,
        "db/schema.rb" => schema
      )
      files.each do |relative, contents|
        full = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      yield run_both_plugins(dir: dir, config: config)
    end
  end

  # The `dump_type` traces in source order.
  def dumped_types(**)
    analyze(**) do |result|
      result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
    end
  end

  def run_both_plugins(dir:, config:)
    ams_entry = if config.nil?
                  "rigor-active-model-serializers"
                else
                  { "gem" => "rigor-active-model-serializers", "config" => config }
                end
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => [File.join(dir, "app")],
        "plugins" => ["rigor-activerecord", ams_entry]
      )
    )
    Dir.chdir(dir) do
      runner = Rigor::Analysis::Runner.new(
        configuration: configuration, cache_store: nil,
        plugin_requirer: lambda { |name|
          case File.basename(name, ".rb")
          when "rigor-activerecord" then Rigor::Plugin.register(Rigor::Plugin::Activerecord)
          when "rigor-active-model-serializers" then Rigor::Plugin.register(plugin_class)
          end
          true
        }
      )
      guarded_run(runner)
    end
  end

  # The same probe with `rigor-activerecord` absent — the `run_plugin` helper registers `plugin_class`
  # and nothing else, which is exactly the one-plugin project this asserts about.
  def alone_dumped_types(source)
    result = run_plugin(
      source: source,
      files: { "app/models/account.rb" => AMS_ACCOUNT_MODEL, "db/schema.rb" => AMS_SCHEMA }
    )
    result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
  end

  def undefined_method_messages(result)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
  end

  describe "the derivable case" do
    it "types `object` as the model the serializer's name resolves to" do
      types = dumped_types(serializers: {
                             "app/serializers/rest/account_serializer.rb" => <<~SRC
                               class REST::AccountSerializer < ActiveModel::Serializer
                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "types the same serializer written as a nested `module REST`" do
      types = dumped_types(serializers: {
                             "app/serializers/rest/account_serializer.rb" => <<~SRC
                               module REST
                                 class AccountSerializer < ActiveModel::Serializer
                                   def probe
                                     Rigor.dump_type(object)
                                   end
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "carries the model's column types through a read on `object`" do
      types = dumped_types(serializers: {
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ActiveModel::Serializer
                                 def probe
                                   Rigor.dump_type(object.username)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: String"])
    end

    it "reaches a serializer that descends through a project base serializer" do
      types = dumped_types(serializers: {
                             "app/serializers/base.rb" => <<~BASE,
                               class ApplicationSerializer < ActiveModel::Serializer
                               end
                             BASE
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ApplicationSerializer
                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "honours a `model_overrides` entry for a serializer the convention cannot resolve" do
      types = dumped_types(
        serializers: {
          "app/serializers/profile_serializer.rb" => <<~SRC
            class ProfileSerializer < ActiveModel::Serializer
              def probe
                Rigor.dump_type(object)
              end
            end
          SRC
        },
        config: { "model_overrides" => { "ProfileSerializer" => "Account" } }
      )

      expect(types).to eq(["dump_type: Account"])
    end
  end

  describe "the underivable case" do
    it "leaves `object` Dynamic when no model matches the serializer's name" do
      types = dumped_types(serializers: {
                             "app/serializers/context_serializer.rb" => <<~SRC
                               class ContextSerializer < ActiveModel::Serializer
                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end

    it "emits no diagnostic of its own, on either arm" do
      analyze(serializers: {
                "app/serializers/context_serializer.rb" => <<~SRC
                  class ContextSerializer < ActiveModel::Serializer
                    def probe
                      object.anything_at_all
                    end
                  end
                SRC
              }) do |result|
        own = result.diagnostics.select { |d| d.source_family == "plugin.active-model-serializers" }
        expect(own).to be_empty
      end
    end

    it "leaves `object` Dynamic outside a serializer entirely" do
      types = dumped_types(serializers: {
                             "app/serializers/not_one.rb" => <<~SRC
                               class AccountPresenter
                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end

    it "declines with no `:model_index` fact, so the plugin alone changes nothing" do
      # The designed degradation: without `rigor-activerecord` nothing corroborates the naming
      # convention, so every non-overridden serializer keeps the answer it had.
      types = alone_dumped_types(<<~SRC)
        class AccountSerializer < ActiveModel::Serializer
          def probe
            Rigor.dump_type(object)
          end
        end
      SRC

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end

    it "does not answer for `something.object` or `object(arg)`" do
      types = dumped_types(serializers: {
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ActiveModel::Serializer
                                 def probe(other)
                                   Rigor.dump_type(other.object)
                                   Rigor.dump_type(object(1))
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]", "dump_type: Dynamic[top]"])
    end
  end

  describe "what the derived model is then held to" do
    it "still fires `call.undefined-method` on a bogus method of a derived column's type" do
      analyze(serializers: {
                "app/serializers/account_serializer.rb" => <<~SRC
                  class AccountSerializer < ActiveModel::Serializer
                    def probe
                      object.username.no_such_string_method
                    end
                  end
                SRC
              }) do |result|
        expect(undefined_method_messages(result)).to include(a_string_including("no_such_string_method"))
      end
    end
  end

  describe "the declared framework constants" do
    it "does not fire `call.undefined-method` on the AMS surface a serializer inherits" do
      analyze(serializers: {
                "app/serializers/account_serializer.rb" => <<~SRC
                  class AccountSerializer < ActiveModel::Serializer
                    attributes :id, :username

                    def probe
                      read_attribute_for_serialization(:username)
                      scope
                    end
                  end
                SRC
              }) do |result|
        expect(undefined_method_messages(result)).to be_empty
      end
    end
  end
end
