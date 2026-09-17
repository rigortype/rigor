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

# The whole plugin is one contributed return type, so most examples here read a `Rigor.dump_type`
# trace rather than a plugin diagnostic — the plugin emits none.
#
# `rigor-activerecord` runs alongside in every example because the `:model_index` fact is both what
# resolves the serializer's name and what the serializer is then CHECKED against. The pair is the
# unit under test.
AMS_SCHEMA = <<~SCHEMA
  ActiveRecord::Schema[8.0].define(version: 1) do
    create_table "accounts", force: :cascade do |t|
      t.string "username", null: false
    end

    create_table "conversations", force: :cascade do |t|
      t.string "uri"
    end
  end
SCHEMA

AMS_MODELS = {
  "app/models/account.rb" => "class Account < ApplicationRecord\nend\n",
  "app/models/conversation.rb" => "class Conversation < ApplicationRecord\nend\n"
}.freeze

RSpec.describe "plugins/rigor-active-model-serializers" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::ActiveModelSerializers }

  # Runs both plugins over a project whose `app/` holds `files`, and yields the analysis result.
  def analyze(files:, config: nil, schema: AMS_SCHEMA)
    Dir.mktmpdir do |dir|
      AMS_MODELS.merge(files).merge("db/schema.rb" => schema).each do |relative, contents|
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

  def undefined_method_messages(result)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
  end

  describe "the derivable case" do
    it "types `object` as the model whose name resolves AND whose surface answers the serializer" do
      types = dumped_types(files: {
                             "app/serializers/rest/account_serializer.rb" => <<~SRC
                               class REST::AccountSerializer < ActiveModel::Serializer
                                 attributes :username

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "types the same serializer written as a nested `module REST`" do
      types = dumped_types(files: {
                             "app/serializers/rest/account_serializer.rb" => <<~SRC
                               module REST
                                 class AccountSerializer < ActiveModel::Serializer
                                   attributes :username

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
      types = dumped_types(files: {
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

    it "accepts a name the model answers with a Ruby `def` rather than a column" do
      types = dumped_types(files: {
                             "app/models/account.rb" => <<~MODEL,
                               class Account < ApplicationRecord
                                 def acct
                                   username
                                 end
                               end
                             MODEL
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ActiveModel::Serializer
                                 attributes :acct

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "reaches a serializer that descends through a project base serializer" do
      types = dumped_types(files: {
                             "app/serializers/base.rb" => <<~BASE,
                               class ApplicationSerializer < ActiveModel::Serializer
                               end
                             BASE
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ApplicationSerializer
                                 attributes :username

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "honours a `model_overrides` entry, which the surface check does not re-examine" do
      types = dumped_types(
        files: {
          "app/serializers/profile_serializer.rb" => <<~SRC
            class ProfileSerializer < ActiveModel::Serializer
              attributes :nothing_account_has

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

  describe "a name that resolves to the wrong model" do
    # Mastodon's own `REST::ConversationSerializer`: the name resolves to the real `Conversation`
    # model, and the resource is an `AccountConversation`. `unread` and `last_status` are what say so.
    it "declines when the model does not answer a declared name" do
      types = dumped_types(files: {
                             "app/serializers/rest/conversation_serializer.rb" => <<~SRC
                               class REST::ConversationSerializer < ActiveModel::Serializer
                                 attributes :id, :unread

                                 has_one :last_status

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end

    it "declines when the model does not answer an `object.` read" do
      types = dumped_types(files: {
                             "app/serializers/conversation_serializer.rb" => <<~SRC
                               class ConversationSerializer < ActiveModel::Serializer
                                 def probe
                                   object.participant_accounts
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end

    it "does not count a name the serializer defines itself against the model" do
      types = dumped_types(files: {
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ActiveModel::Serializer
                                 attributes :username, :computed

                                 def computed
                                   "not read off the resource"
                                 end

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "declines when the serializer reads nothing off its resource, so nothing checks the name" do
      types = dumped_types(files: {
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ActiveModel::Serializer
                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end

    it "declines when two readings of the name both resolve to a real model" do
      types = dumped_types(files: {
                             "app/models/admin/account.rb" => <<~MODEL,
                               class Admin::Account < ApplicationRecord
                                 self.table_name = "accounts"
                               end
                             MODEL
                             "app/serializers/admin/account_serializer.rb" => <<~SRC
                               class Admin::AccountSerializer < ActiveModel::Serializer
                                 attributes :username

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end
  end

  describe "a class that is not an AMS serializer" do
    it "stays out of a `*Serializer` class with no serializer ancestry, keeping its true positive" do
      analyze(files: {
                "app/serializers/json/conversation_serializer.rb" => <<~SRC
                  module Json
                    class ConversationSerializer
                      def object = 42

                      def probe
                        Rigor.dump_type(object)
                        object.no_such_integer_method
                      end
                    end
                  end
                SRC
              }) do |result|
        types = result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
        expect(types).to eq(["dump_type: 42"])
        expect(undefined_method_messages(result)).to include(a_string_including("no_such_integer_method"))
      end
    end

    it "stays out of a `*Serializer` whose superclass is not a serializer" do
      types = dumped_types(files: {
                             "app/serializers/oj/account_serializer.rb" => <<~SRC
                               module Oj
                                 class AccountSerializer < SimpleDelegator
                                   attributes :username

                                   def probe
                                     Rigor.dump_type(object)
                                   end
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end

    it "leaves `object` alone outside a class named `*Serializer` entirely" do
      types = dumped_types(files: {
                             "app/serializers/presenter.rb" => <<~SRC
                               class AccountPresenter
                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end
  end

  describe "an explicit `def object`" do
    it "does not answer over a serializer's own definition, keeping its true positive" do
      analyze(files: {
                "app/serializers/account_serializer.rb" => <<~SRC
                  class AccountSerializer < ActiveModel::Serializer
                    attributes :username

                    def object
                      "overridden"
                    end

                    def probe
                      Rigor.dump_type(object)
                      object.no_such_string_method
                    end
                  end
                SRC
              }) do |result|
        types = result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
        expect(types).to eq(['dump_type: "overridden"'])
        expect(undefined_method_messages(result)).to include(a_string_including("no_such_string_method"))
      end
    end

    it "does not answer over a definition inherited from a project base serializer" do
      types = dumped_types(files: {
                             "app/serializers/base.rb" => <<~BASE,
                               class ApplicationSerializer < ActiveModel::Serializer
                                 def object
                                   "overridden"
                                 end
                               end
                             BASE
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ApplicationSerializer
                                 attributes :username

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(['dump_type: "overridden"'])
    end
  end

  describe "a class-level body" do
    it "does not treat a `class << self` `def object` as the reader it answers over" do
      types = dumped_types(files: {
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ActiveModel::Serializer
                                 attributes :username

                                 class << self
                                   def object = 2
                                 end

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "does not count an `object.` read inside `class << self` against the model" do
      types = dumped_types(files: {
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ActiveModel::Serializer
                                 attributes :username

                                 class << self
                                   def reader = object.nothing_account_has
                                 end

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end
  end

  describe "a declaration an ancestor serializer renders" do
    it "does not require the model to answer a name a base serializer defines" do
      types = dumped_types(files: {
                             "app/serializers/base.rb" => <<~BASE,
                               class BaseSerializer < ActiveModel::Serializer
                                 def formatted
                                   "rendered here, never read off the resource"
                                 end
                               end
                             BASE
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < BaseSerializer
                                 attributes :username, :formatted

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "still requires the model to answer an `object.` read a base serializer also defines" do
      types = dumped_types(files: {
                             "app/serializers/base.rb" => <<~BASE,
                               class BaseSerializer < ActiveModel::Serializer
                                 def formatted
                                   "rendered here"
                                 end
                               end
                             BASE
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < BaseSerializer
                                 def probe
                                   object.formatted
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end
  end

  describe "an `object` reader written as a macro" do
    it "does not answer over `attr_reader :object`" do
      types = dumped_types(files: {
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ActiveModel::Serializer
                                 attributes :username

                                 attr_reader :object

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end

    it "does not answer over `delegate :object, to: :wrapper`" do
      types = dumped_types(files: {
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ActiveModel::Serializer
                                 attributes :username

                                 delegate :object, to: :wrapper

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end
  end

  describe "the underivable case emits nothing" do
    it "emits no diagnostic of its own, on either arm" do
      analyze(files: {
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

    it "declines with no `:model_index` fact, so the plugin alone changes nothing" do
      # The designed degradation: without `rigor-activerecord` nothing resolves the name, so every
      # non-overridden serializer keeps the answer it had.
      result = run_plugin(
        source: "",
        paths: ["app"],
        files: {
          "app/models/account.rb" => AMS_MODELS.fetch("app/models/account.rb"),
          "db/schema.rb" => AMS_SCHEMA,
          "app/serializers/account_serializer.rb" => <<~SRC
            class AccountSerializer < ActiveModel::Serializer
              attributes :username

              def probe
                Rigor.dump_type(object)
              end
            end
          SRC
        }
      )
      types = result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end

    it "does not answer for `something.object` or `object(arg)`" do
      types = dumped_types(files: {
                             "app/serializers/account_serializer.rb" => <<~SRC
                               class AccountSerializer < ActiveModel::Serializer
                                 attributes :username

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
      analyze(files: {
                "app/serializers/account_serializer.rb" => <<~SRC
                  class AccountSerializer < ActiveModel::Serializer
                    attributes :username

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

  # #1049 — the three macro families the `:model_index` fact could not see. Each name below declined the
  # whole serializer before the fold, because `answers?` requires every name.
  describe "the macro families the model index folds (#1049)" do
    it "accepts a `delegate` name from the model body and from an included concern" do
      types = dumped_types(files: {
                             "app/models/account.rb" => <<~MODEL,
                               class Account < ApplicationRecord
                                 include Account::Counters

                                 delegate :can?, to: :user, prefix: true
                               end
                             MODEL
                             "app/models/concerns/account/counters.rb" => <<~MODEL,
                               module Account::Counters
                                 extend ActiveSupport::Concern

                                 delegate :followers_count, to: :account_stat
                               end
                             MODEL
                             "app/serializers/rest/account_serializer.rb" => <<~SRC
                               class REST::AccountSerializer < ActiveModel::Serializer
                                 attributes :followers_count

                                 def probe
                                   object.user_can?(:manage)
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "accepts an association declared in an included concern's `included do`" do
      types = dumped_types(files: {
                             "app/models/account.rb" => <<~MODEL,
                               class Account < ApplicationRecord
                                 include Account::Associations
                               end
                             MODEL
                             "app/models/concerns/account/associations.rb" => <<~MODEL,
                               module Account::Associations
                                 extend ActiveSupport::Concern

                                 included do
                                   has_one :moved_to_account, class_name: 'Account'
                                 end
                               end
                             MODEL
                             "app/serializers/rest/account_serializer.rb" => <<~SRC
                               class REST::AccountSerializer < ActiveModel::Serializer
                                 has_one :moved_to_account

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "accepts a Paperclip attachment reader and its predicate" do
      types = dumped_types(files: {
                             "app/models/account.rb" => <<~MODEL,
                               class Account < ApplicationRecord
                                 has_attached_file :avatar
                               end
                             MODEL
                             "app/serializers/rest/account_serializer.rb" => <<~SRC
                               class REST::AccountSerializer < ActiveModel::Serializer
                                 attributes :avatar

                                 def probe
                                   object.avatar?
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Account"])
    end

    it "still declines when the concern carrying the name is not included" do
      types = dumped_types(files: {
                             "app/models/account.rb" => "class Account < ApplicationRecord\nend\n",
                             "app/models/concerns/account/counters.rb" => <<~MODEL,
                               module Account::Counters
                                 extend ActiveSupport::Concern

                                 delegate :followers_count, to: :account_stat
                               end
                             MODEL
                             "app/serializers/rest/account_serializer.rb" => <<~SRC
                               class REST::AccountSerializer < ActiveModel::Serializer
                                 attributes :followers_count

                                 def probe
                                   Rigor.dump_type(object)
                                 end
                               end
                             SRC
                           })

      expect(types).to eq(["dump_type: Dynamic[top]"])
    end
  end

  describe "the declared framework constants" do
    it "does not fire `call.undefined-method` on the AMS surface a serializer inherits" do
      analyze(files: {
                "app/serializers/account_serializer.rb" => <<~SRC
                  class AccountSerializer < ActiveModel::Serializer
                    attributes :username

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

    it "does not fire `call.undefined-method` on the canonical AMS initializer" do
      analyze(files: {
                "app/initializers/active_model_serializers.rb" => <<~SRC
                  ActiveModelSerializers.config.adapter = :json_api
                  ActiveModelSerializers.config.key_transform = :unaltered
                  ActiveModelSerializers::Adapter.register(:custom, CustomAdapter)
                  ActiveModelSerializers::SerializableResource.new(Account.new)
                  ActiveModel::Serializer::CollectionSerializer.new([])
                SRC
              }) do |result|
        expect(undefined_method_messages(result)).to be_empty
      end
    end
  end
end
